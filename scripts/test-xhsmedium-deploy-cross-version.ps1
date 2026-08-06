[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$BaselineApprovedReleaseBuild,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$CandidateApprovedReleaseBuild,
    [ValidateSet('all', 'dev', 'test')][string]$Environment = 'all',
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingDevBaselineBuild = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingDevRollbackBuild = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingDevCandidateBuild = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingTestBaselineBuild = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingTestRollbackBuild = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ExistingTestCandidateBuild = 0,
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 25
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

function Start-DeployBuild {
    param(
        [Parameter(Mandatory)][string]$JobUrl,
        [Parameter(Mandatory)][int]$ApprovalBuild,
        [Parameter(Mandatory)][bool]$SimulateFailure
    )
    $job = Invoke-RestMethod -Uri "$JobUrl/api/json?tree=nextBuildNumber" -Headers $script:adminHeaders -TimeoutSec 20
    $number = [int]$job.nextBuildNumber
    $body = @{
        APPROVED_RELEASE_BUILD_NUMBER = "$ApprovalBuild"
        CONFIRM_DEPLOY = 'true'
        SIMULATE_HEALTH_FAILURE = $SimulateFailure.ToString().ToLowerInvariant()
    }
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' -Uri "$JobUrl/buildWithParameters" -Headers $script:buildHeaders -WebSession $script:jenkinsSession -Body $body -TimeoutSec 20
    Assert-True ([int]$response.StatusCode -in @(200, 201, 202)) "Deploy build $JobUrl/$number was accepted."
    return $number
}

function Get-Console {
    param([string]$JobUrl, [int]$Number)
    return (Invoke-WebRequest -UseBasicParsing -Uri "$JobUrl/$Number/consoleText" -Headers $script:adminHeaders -TimeoutSec 30).Content
}

function Assert-NoSecret {
    param([string]$Console, [string]$Context)
    foreach ($secret in $script:secretValues) {
        Assert-True ($Console -notmatch [regex]::Escape($secret)) "$Context contains no local Secret value."
    }
}

function Get-ApprovedManifest {
    param([int]$BuildNumber, [string]$Role)
    $url = "$script:approvalUrl/$BuildNumber"
    $build = Invoke-RestMethod -Uri "$url/api/json?tree=result" -Headers $script:adminHeaders -TimeoutSec 20
    Assert-True ($build.result -eq 'SUCCESS') "$Role Release approval build $BuildNumber is SUCCESS."
    $manifest = Invoke-RestMethod -Uri "$url/artifact/approved-release-manifest.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($manifest.schemaVersion -eq '1.0') "$Role approved manifest has schema 1.0."
    Assert-True ($manifest.gitSha -match '^[0-9a-f]{40}$') "$Role approved manifest has a full lowercase Git SHA."
    Assert-True ([int]$manifest.candidateBuild -gt 0) "$Role approved manifest links a positive candidate build."
    foreach ($imageRole in @('backend', 'frontend')) {
        $reference = [string]$manifest.images.$imageRole
        Assert-True ($reference -match "^registry:5000/xhsmedium/${imageRole}@sha256:[0-9a-f]{64}$") "$Role $imageRole uses an exact Registry digest."
    }
    return $manifest
}

function Invoke-TargetDocker {
    param([string]$TargetEnvironment, [string[]]$Arguments)
    $service = "deploy-$TargetEnvironment-docker"
    $output = & docker compose exec --no-TTY $service docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed in ${service}: docker $($Arguments -join ' ')" }
    return $output
}

function Get-ServiceId {
    param([string]$TargetEnvironment, [string]$Service)
    $project = "xhsmedium-$TargetEnvironment"
    return (Invoke-TargetDocker -TargetEnvironment $TargetEnvironment -Arguments @('ps', '-q', '--filter', "label=com.docker.compose.project=$project", '--filter', "label=com.docker.compose.service=$Service") | Select-Object -First 1).Trim()
}

function Assert-EnvironmentHealthy {
    param([string]$TargetEnvironment, [object]$Manifest, [string]$ExpectedRole)
    foreach ($service in @('mysql', 'backend', 'frontend')) {
        $id = Get-ServiceId -TargetEnvironment $TargetEnvironment -Service $service
        Assert-True ([bool]$id) "$TargetEnvironment $service container exists for $ExpectedRole."
        $health = (Invoke-TargetDocker -TargetEnvironment $TargetEnvironment -Arguments @('inspect', '--format', '{{.State.Health.Status}}', $id)).Trim()
        Assert-True ($health -eq 'healthy') "$TargetEnvironment $service is healthy for $ExpectedRole."
    }
    foreach ($service in @('backend', 'frontend')) {
        $id = Get-ServiceId -TargetEnvironment $TargetEnvironment -Service $service
        $image = (Invoke-TargetDocker -TargetEnvironment $TargetEnvironment -Arguments @('inspect', '--format', '{{.Config.Image}}', $id)).Trim()
        Assert-True ($image -eq $Manifest.images.$service) "$TargetEnvironment $service runs the $ExpectedRole digest."
    }
}

function Test-CrossVersionEnvironment {
    param(
        [ValidateSet('dev', 'test')][string]$TargetEnvironment,
        [int]$ExistingBaseline,
        [int]$ExistingRollback,
        [int]$ExistingCandidate,
        [object]$BaselineManifest,
        [object]$CandidateManifest
    )
    $jobUrl = "$BaseUrl/job/XHSMedium/job/Deploy/job/$TargetEnvironment"

    $baselineNumber = if ($ExistingBaseline -gt 0) { $ExistingBaseline } else { Start-DeployBuild -JobUrl $jobUrl -ApprovalBuild $BaselineApprovedReleaseBuild -SimulateFailure $false }
    $baselineBuild = Wait-Build -JobUrl $jobUrl -Number $baselineNumber -Minutes $TimeoutMinutes
    $baselineConsole = Get-Console -JobUrl $jobUrl -Number $baselineNumber
    Assert-True ($baselineBuild.result -eq 'SUCCESS') "$TargetEnvironment baseline deploy build $baselineNumber is SUCCESS."
    Assert-True ($baselineConsole -match "P6_DEPLOY_OK environment=$TargetEnvironment action=(?:DEPLOYED|NOOP) approval=$BaselineApprovedReleaseBuild sha=$($BaselineManifest.gitSha)") "$TargetEnvironment baseline deployment records Approval A."
    Assert-NoSecret -Console $baselineConsole -Context "$TargetEnvironment baseline deployment console"
    $baselineEvidence = Invoke-RestMethod -Uri "$jobUrl/$baselineNumber/artifact/deployment-evidence.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ([int]$baselineEvidence.approvalBuild -eq $BaselineApprovedReleaseBuild -and $baselineEvidence.gitSha -eq $BaselineManifest.gitSha) "$TargetEnvironment baseline evidence links Approval A and its SHA."
    Assert-True ($baselineEvidence.images.backend -eq $BaselineManifest.images.backend -and $baselineEvidence.images.frontend -eq $BaselineManifest.images.frontend) "$TargetEnvironment baseline evidence preserves both A digests."
    if ($ExistingBaseline -eq 0) {
        Assert-EnvironmentHealthy -TargetEnvironment $TargetEnvironment -Manifest $BaselineManifest -ExpectedRole 'baseline A'
    }

    $rollbackNumber = if ($ExistingRollback -gt 0) { $ExistingRollback } else { Start-DeployBuild -JobUrl $jobUrl -ApprovalBuild $CandidateApprovedReleaseBuild -SimulateFailure $true }
    $rollbackBuild = Wait-Build -JobUrl $jobUrl -Number $rollbackNumber -Minutes $TimeoutMinutes
    $rollbackConsole = Get-Console -JobUrl $jobUrl -Number $rollbackNumber
    Assert-True ($rollbackBuild.result -eq 'FAILURE') "$TargetEnvironment candidate B injected failure build $rollbackNumber remains FAILURE."
    Assert-True ($rollbackConsole -match "P6_DEPLOY_ROLLED_BACK environment=$TargetEnvironment approval=$CandidateApprovedReleaseBuild") "$TargetEnvironment candidate B failure emits rollback evidence."
    Assert-True ($rollbackConsole -notmatch 'P6_DEPLOY_OK') "$TargetEnvironment candidate B failure emits no deployment success marker."
    Assert-NoSecret -Console $rollbackConsole -Context "$TargetEnvironment candidate B rollback console"
    $rollbackEvidence = Invoke-RestMethod -Uri "$jobUrl/$rollbackNumber/artifact/rollback-evidence.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($rollbackEvidence.schemaVersion -eq '1.0' -and $rollbackEvidence.healthy -and $rollbackEvidence.environment -eq $TargetEnvironment) "$TargetEnvironment rollback evidence records a healthy restored environment."
    Assert-True ([int]$rollbackEvidence.failedApprovalBuild -eq $CandidateApprovedReleaseBuild -and [int]$rollbackEvidence.restoredApprovalBuild -eq $BaselineApprovedReleaseBuild) "$TargetEnvironment rollback evidence records failed B and restored A approvals."
    Assert-True ($rollbackEvidence.gitSha -eq $BaselineManifest.gitSha) "$TargetEnvironment rollback evidence restores the A Git SHA."
    Assert-True ($rollbackEvidence.images.backend -eq $BaselineManifest.images.backend -and $rollbackEvidence.images.frontend -eq $BaselineManifest.images.frontend) "$TargetEnvironment rollback evidence restores both A digests."
    if ($ExistingRollback -eq 0) {
        Assert-EnvironmentHealthy -TargetEnvironment $TargetEnvironment -Manifest $BaselineManifest -ExpectedRole 'restored A'
    }

    $candidateNumber = if ($ExistingCandidate -gt 0) { $ExistingCandidate } else { Start-DeployBuild -JobUrl $jobUrl -ApprovalBuild $CandidateApprovedReleaseBuild -SimulateFailure $false }
    $candidateBuild = Wait-Build -JobUrl $jobUrl -Number $candidateNumber -Minutes $TimeoutMinutes
    $candidateConsole = Get-Console -JobUrl $jobUrl -Number $candidateNumber
    Assert-True ($candidateBuild.result -eq 'SUCCESS') "$TargetEnvironment candidate B deploy build $candidateNumber is SUCCESS."
    Assert-True ($candidateConsole -match "P6_DEPLOY_OK environment=$TargetEnvironment action=DEPLOYED approval=$CandidateApprovedReleaseBuild sha=$($CandidateManifest.gitSha)") "$TargetEnvironment final deployment upgrades to Approval B."
    Assert-NoSecret -Console $candidateConsole -Context "$TargetEnvironment candidate B deployment console"
    $candidateEvidence = Invoke-RestMethod -Uri "$jobUrl/$candidateNumber/artifact/deployment-evidence.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ([int]$candidateEvidence.approvalBuild -eq $CandidateApprovedReleaseBuild -and $candidateEvidence.gitSha -eq $CandidateManifest.gitSha) "$TargetEnvironment final evidence links Approval B and its SHA."
    Assert-True ($candidateEvidence.images.backend -eq $CandidateManifest.images.backend -and $candidateEvidence.images.frontend -eq $CandidateManifest.images.frontend) "$TargetEnvironment final evidence preserves both B digests."
    Assert-EnvironmentHealthy -TargetEnvironment $TargetEnvironment -Manifest $CandidateManifest -ExpectedRole 'candidate B'

    return [pscustomobject]@{ Baseline = $baselineNumber; Rollback = $rollbackNumber; Candidate = $candidateNumber }
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BaseUrl = $BaseUrl.TrimEnd('/')
Assert-True ($BaselineApprovedReleaseBuild -ne $CandidateApprovedReleaseBuild) 'Baseline and candidate Approval build numbers are distinct.'
foreach ($existingSet in @(
    @($ExistingDevBaselineBuild, $ExistingDevRollbackBuild, $ExistingDevCandidateBuild),
    @($ExistingTestBaselineBuild, $ExistingTestRollbackBuild, $ExistingTestCandidateBuild)
)) {
    $supplied = @($existingSet | Where-Object { $_ -gt 0 }).Count
    Assert-True ($supplied -in @(0, 3)) 'Existing cross-version build numbers must be supplied as a complete environment triple or all left at zero.'
    if ($supplied -eq 3) {
        Assert-True ($existingSet[0] -lt $existingSet[1] -and $existingSet[1] -lt $existingSet[2]) 'Existing cross-version build numbers must preserve baseline, rollback, candidate execution order.'
    }
}
$adminPassword = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$adminPair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$script:adminHeaders = @{ Authorization = "Basic $adminPair" }
$crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $script:adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
$script:jenkinsSession = $jenkinsSession
$script:buildHeaders = @{} + $script:adminHeaders
$script:buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
$script:approvalUrl = "$BaseUrl/job/XHSMedium/job/Release/job/approve"
$script:secretValues = @($adminPassword)
foreach ($name in @('registry_password', 'deploy_dev_mysql_password', 'deploy_dev_jwt_secret', 'deploy_dev_draft_key', 'deploy_test_mysql_password', 'deploy_test_jwt_secret', 'deploy_test_draft_key')) {
    $script:secretValues += [IO.File]::ReadAllText((Join-Path $repoRoot ".secrets\$name")).Trim()
}

$baselineManifest = Get-ApprovedManifest -BuildNumber $BaselineApprovedReleaseBuild -Role 'Baseline A'
$candidateManifest = Get-ApprovedManifest -BuildNumber $CandidateApprovedReleaseBuild -Role 'Candidate B'
Assert-True ($baselineManifest.gitSha -ne $candidateManifest.gitSha) 'Baseline A and candidate B use different Git SHAs.'
Assert-True ($baselineManifest.images.backend -ne $candidateManifest.images.backend) 'Baseline A and candidate B use different backend digests.'
Assert-True ($baselineManifest.images.frontend -ne $candidateManifest.images.frontend) 'Baseline A and candidate B use different frontend digests.'

$targets = if ($Environment -eq 'all') { @('dev', 'test') } else { @($Environment) }
$results = @{}
Push-Location $repoRoot
try {
    foreach ($target in $targets) {
        if ($target -eq 'dev') {
            $results.dev = Test-CrossVersionEnvironment -TargetEnvironment dev -ExistingBaseline $ExistingDevBaselineBuild -ExistingRollback $ExistingDevRollbackBuild -ExistingCandidate $ExistingDevCandidateBuild -BaselineManifest $baselineManifest -CandidateManifest $candidateManifest
        }
        else {
            $results.test = Test-CrossVersionEnvironment -TargetEnvironment test -ExistingBaseline $ExistingTestBaselineBuild -ExistingRollback $ExistingTestRollbackBuild -ExistingCandidate $ExistingTestCandidateBuild -BaselineManifest $baselineManifest -CandidateManifest $candidateManifest
        }
    }

    foreach ($target in $targets) {
        $other = if ($target -eq 'dev') { 'test' } else { 'dev' }
        $projects = Invoke-TargetDocker -TargetEnvironment $target -Arguments @('ps', '-a', '--format', '{{.Label "com.docker.compose.project"}}')
        Assert-True (-not @($projects | Where-Object { $_ -eq "xhsmedium-$other" }).Count) "$target target contains no $other deployment containers."
        $workspaceResidue = docker compose exec --no-TTY "deploy-$target-agent" sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Deploy/*" ! -type d -print -quit'
        Assert-True (-not $workspaceResidue) "$target Deploy Agent Workspace contains no residual files."
    }
    $queue = Invoke-RestMethod -Uri "$BaseUrl/queue/api/json?tree=items[id]" -Headers $script:adminHeaders -TimeoutSec 20
    Assert-True (@($queue.items).Count -eq 0) 'Jenkins queue is empty after cross-version validation.'
    $computers = Invoke-RestMethod -Uri "$BaseUrl/computer/api/json?tree=computer[executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]]" -Headers $script:adminHeaders -TimeoutSec 20
    $activeExecutors = @($computers.computer | ForEach-Object { @($_.executors) + @($_.oneOffExecutors) } | Where-Object currentExecutable).Count
    Assert-True ($activeExecutors -eq 0) 'Jenkins has zero active executors after cross-version validation.'

    $devEvidence = if ($results.ContainsKey('dev')) { "$($results.dev.Baseline)/$($results.dev.Rollback)/$($results.dev.Candidate)" } else { 'skipped' }
    $testEvidence = if ($results.ContainsKey('test')) { "$($results.test.Baseline)/$($results.test.Rollback)/$($results.test.Candidate)" } else { 'skipped' }
    Write-Host "P6_CROSS_VERSION_ROLLBACK_EVIDENCE baseline_approval=$BaselineApprovedReleaseBuild candidate_approval=$CandidateApprovedReleaseBuild baseline_sha=$($baselineManifest.gitSha) candidate_sha=$($candidateManifest.gitSha) dev=$devEvidence test=$testEvidence final=candidate isolated=true cleanup=true status=OK"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
