[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [string]$GitSha = 'b846dcd0771f3fdb81db9ae9c0e9f034d532d36e',
    [int]$CiBuildNumber = 18,
    [int]$RegressionBuildNumber = 19,
    [int]$RecoveryFromFailedBuild = 0,
    [int]$ExistingCandidateBuild = 0,
    [int]$ExistingDuplicateBuild = 0,
    [int]$ExistingApprovalBuild = 0,
    [int]$TimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

function Wait-Build {
    param([string]$JobUrl, [int]$Number, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $build = $null
    do {
        Start-Sleep -Seconds 5
        $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$JobUrl/$Number/api/json?tree=number,building,result,duration" -Headers $script:adminHeaders -TimeoutSec 20
        if ([int]$response.StatusCode -eq 200) {
            $build = $response.Content | ConvertFrom-Json
            if (-not $build.building) { return $build }
        }
    } while ((Get-Date) -lt $deadline)
    throw "Build $JobUrl/$Number did not finish within $Minutes minutes."
}

function Start-ParameterizedBuild {
    param([string]$JobUrl, [hashtable]$Parameters)
    $job = Invoke-RestMethod -Uri "$JobUrl/api/json?tree=nextBuildNumber" -Headers $script:adminHeaders -TimeoutSec 20
    $number = [int]$job.nextBuildNumber
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' -Uri "$JobUrl/buildWithParameters" -Headers $script:buildHeaders -WebSession $script:jenkinsSession -Body $Parameters -TimeoutSec 20
    Assert-True ([int]$response.StatusCode -in @(200, 201, 202)) "Build $JobUrl/$number was accepted."
    return $number
}

function Assert-RegistryDigest {
    param([string]$Repository, [string]$Digest)
    $uri = "http://127.0.0.1:5000/v2/$Repository/manifests/$Digest"
    $headers = @{
        Authorization = $script:registryAuthorization
        Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
    }
    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -TimeoutSec 30
    Assert-True ([int]$response.StatusCode -eq 200) "Registry serves $Repository by digest."
    $contentDigest = [string]($response.Headers['Docker-Content-Digest'] | Select-Object -First 1)
    Assert-True ($contentDigest -eq $Digest) "Registry content digest matches $Repository manifest."
}

Assert-True ($GitSha -match '^[0-9a-f]{40}$') 'Requested candidate SHA is a full lowercase Git SHA.'
$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BaseUrl = $BaseUrl.TrimEnd('/')
$adminPassword = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$adminPair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$script:adminHeaders = @{ Authorization = "Basic $adminPair" }
$crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $script:adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
$script:jenkinsSession = $jenkinsSession
$script:buildHeaders = @{} + $script:adminHeaders
$script:buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
$registryUser = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\registry_username')).Trim()
$registryPassword = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\registry_password')).Trim()
$registryPair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${registryUser}:$registryPassword"))
$script:registryAuthorization = "Basic $registryPair"
$candidateUrl = "$BaseUrl/job/XHSMedium/job/Release/job/candidate"
$approvalUrl = "$BaseUrl/job/XHSMedium/job/Release/job/approve"

Push-Location $repoRoot
try {
    if ($ExistingCandidateBuild -gt 0) {
        $candidateNumber = $ExistingCandidateBuild
    }
    else {
        $candidateNumber = Start-ParameterizedBuild -JobUrl $candidateUrl -Parameters @{
            BRANCH = 'dev'
            GIT_SHA = $GitSha
            CI_BUILD_NUMBER = "$CiBuildNumber"
            REGRESSION_BUILD_NUMBER = "$RegressionBuildNumber"
            RECOVER_FROM_FAILED_BUILD = $(if ($RecoveryFromFailedBuild -gt 0) { "$RecoveryFromFailedBuild" } else { '' })
        }
    }
    $candidate = Wait-Build -JobUrl $candidateUrl -Number $candidateNumber -Minutes $TimeoutMinutes
    $candidateConsole = (Invoke-WebRequest -UseBasicParsing -Uri "$candidateUrl/$candidateNumber/consoleText" -Headers $script:adminHeaders -TimeoutSec 30).Content
    Assert-True ($candidate.result -eq 'SUCCESS') "Candidate build $candidateNumber completed as SUCCESS."
    Assert-True ($candidateConsole -match "P5_CANDIDATE_OK releaseId=xhsmedium-$($GitSha.Substring(0,8)) sha=$GitSha") 'Candidate build emitted its fixed-SHA success marker.'
    if ($RecoveryFromFailedBuild -gt 0) {
        Assert-True ($candidateConsole -match "P5_CANDIDATE_RECOVERED failedBuild=$RecoveryFromFailedBuild sha=$GitSha") 'Candidate explicitly recorded no-rebuild recovery from the failed build.'
        Assert-True ($candidateConsole -notmatch '(?m)^\+ docker build(?:x)?\s+(?:build|--pull)') 'Recovered candidate did not rebuild source.'
        Assert-True ($candidateConsole -notmatch '(?m)^\+ docker(?: --config "?[^\r\n]+"?)? push\s') 'Recovered candidate did not push an image.'
    }
    Assert-True ($candidateConsole -notmatch [regex]::Escape($registryPassword)) 'Registry password is absent from candidate console output.'
    Assert-True ($candidateConsole -notmatch [regex]::Escape($adminPassword)) 'Jenkins administrator password is absent from candidate console output.'

    $manifest = Invoke-RestMethod -Uri "$candidateUrl/$candidateNumber/artifact/candidate-manifest.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($manifest.gitSha -eq $GitSha) 'Candidate manifest matches the fixed Git SHA.'
    Assert-True ([int]$manifest.gates.ciBuild -eq $CiBuildNumber -and [int]$manifest.gates.regressionBuild -eq $RegressionBuildNumber) 'Candidate manifest links the accepted CI and regression builds.'
    if ($RecoveryFromFailedBuild -gt 0) {
        Assert-True ([int]$manifest.recoveredFromFailedBuild -eq $RecoveryFromFailedBuild) 'Candidate manifest records the audited failed build used for recovery.'
    }
    foreach ($role in @('backend', 'frontend')) {
        $image = $manifest.images.$role
        Assert-True ($image.tag -eq "registry:5000/xhsmedium/${role}:git-$GitSha") "$role uses a full-SHA immutable tag."
        Assert-True ($image.digest -match '^sha256:[0-9a-f]{64}$') "$role manifest records a Registry digest."
        Assert-True ($image.reference -eq "registry:5000/xhsmedium/${role}@$($image.digest)") "$role deployable reference uses its digest."
        Assert-RegistryDigest -Repository "xhsmedium/$role" -Digest $image.digest
    }

    if ($ExistingDuplicateBuild -gt 0) {
        $duplicateNumber = $ExistingDuplicateBuild
    }
    else {
        $duplicateNumber = Start-ParameterizedBuild -JobUrl $candidateUrl -Parameters @{
            BRANCH = 'dev'
            GIT_SHA = $GitSha
            CI_BUILD_NUMBER = "$CiBuildNumber"
            REGRESSION_BUILD_NUMBER = "$RegressionBuildNumber"
        }
    }
    $duplicate = Wait-Build -JobUrl $candidateUrl -Number $duplicateNumber -Minutes 15
    $duplicateConsole = (Invoke-WebRequest -UseBasicParsing -Uri "$candidateUrl/$duplicateNumber/consoleText" -Headers $script:adminHeaders -TimeoutSec 30).Content
    Assert-True ($duplicate.result -eq 'FAILURE') "Duplicate candidate build $duplicateNumber was rejected."
    Assert-True ($duplicateConsole -match 'IMMUTABLE_TAG_EXISTS') 'Duplicate candidate failed on the immutable tag gate.'
    Assert-True ($duplicateConsole -notmatch 'P5_CANDIDATE_OK') 'Duplicate candidate did not emit a success marker.'

    if ($ExistingApprovalBuild -gt 0) {
        $approvalNumber = $ExistingApprovalBuild
    }
    else {
        $approvalNumber = Start-ParameterizedBuild -JobUrl $approvalUrl -Parameters @{ CANDIDATE_BUILD_NUMBER = "$candidateNumber" }
    }
    $approval = Wait-Build -JobUrl $approvalUrl -Number $approvalNumber -Minutes 15
    $approvalConsole = (Invoke-WebRequest -UseBasicParsing -Uri "$approvalUrl/$approvalNumber/consoleText" -Headers $script:adminHeaders -TimeoutSec 30).Content
    Assert-True ($approval.result -eq 'SUCCESS') "Release approval build $approvalNumber completed as SUCCESS."
    Assert-True ($approvalConsole -match "P5_RELEASE_APPROVED releaseId=xhsmedium-$($GitSha.Substring(0,8)) sha=$GitSha candidate=$candidateNumber") 'Release approval emitted its fixed-SHA marker.'
    Assert-True ($approvalConsole -notmatch '(?m)^\+ docker build(?:x)?\s+(?:build|--pull)') 'Release approval did not rebuild source.'
    $approved = Invoke-RestMethod -Uri "$approvalUrl/$approvalNumber/artifact/approved-release-manifest.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($approved.gitSha -eq $GitSha -and [int]$approved.candidateBuild -eq $candidateNumber) 'Approved manifest points to the accepted candidate and SHA.'
    Assert-True ($approved.images.backend -eq $manifest.images.backend.reference -and $approved.images.frontend -eq $manifest.images.frontend.reference) 'Approval preserves the exact candidate image digests.'

    $releaseImages = docker compose exec --no-TTY release-docker docker images --format '{{.Repository}}:{{.Tag}}' | Where-Object { $_ -match '^registry:5000/xhsmedium/' }
    Assert-True (-not $releaseImages) 'Release DIND removed mutable local candidate tags after Push.'
    $workspaceResidue = docker compose exec --no-TTY release-agent sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Release/*" ! -type d -print -quit'
    Assert-True (-not $workspaceResidue) 'Release Agent Workspace contains no residual files (empty Jenkins @tmp directories are allowed).'
    $queue = Invoke-RestMethod -Uri "$BaseUrl/queue/api/json?tree=items[id]" -Headers $script:adminHeaders -TimeoutSec 20
    Assert-True (@($queue.items).Count -eq 0) 'Jenkins queue is empty after Release validation.'
    Write-Host "P5_RELEASE_EVIDENCE: candidate=$candidateNumber duplicate=$duplicateNumber approval=$approvalNumber sha=$GitSha backend=$($manifest.images.backend.digest) frontend=$($manifest.images.frontend.digest) cleanup=true"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
