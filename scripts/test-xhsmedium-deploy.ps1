[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$ApprovedReleaseBuild = 2,
    [int]$ExistingDevDeployBuild = 0,
    [int]$ExistingDevNoopBuild = 0,
    [int]$ExistingDevRollbackBuild = 0,
    [int]$ExistingTestDeployBuild = 0,
    [int]$ExistingTestNoopBuild = 0,
    [int]$ExistingTestRollbackBuild = 0,
    [int]$TimeoutMinutes = 25
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
    param([string]$JobUrl, [bool]$SimulateFailure)
    $job = Invoke-RestMethod -Uri "$JobUrl/api/json?tree=nextBuildNumber" -Headers $script:adminHeaders -TimeoutSec 20
    $number = [int]$job.nextBuildNumber
    $body = @{
        APPROVED_RELEASE_BUILD_NUMBER = "$ApprovedReleaseBuild"
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

function Invoke-TargetDocker {
    param([string]$Environment, [string[]]$Arguments)
    $service = "deploy-$Environment-docker"
    $output = & docker compose exec --no-TTY $service docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed in ${service}: docker $($Arguments -join ' ')" }
    return $output
}

function Get-ServiceId {
    param([string]$Environment, [string]$Service)
    $project = "xhsmedium-$Environment"
    return (Invoke-TargetDocker -Environment $Environment -Arguments @('ps', '-q', '--filter', "label=com.docker.compose.project=$project", '--filter', "label=com.docker.compose.service=$Service") | Select-Object -First 1).Trim()
}

function Assert-EnvironmentHealthy {
    param([string]$Environment, [object]$Manifest)
    foreach ($service in @('mysql', 'backend', 'frontend')) {
        $id = Get-ServiceId -Environment $Environment -Service $service
        Assert-True ([bool]$id) "$Environment $service container exists."
        $health = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.State.Health.Status}}', $id)).Trim()
        Assert-True ($health -eq 'healthy') "$Environment $service container is healthy."
    }
    $backendId = Get-ServiceId -Environment $Environment -Service 'backend'
    $frontendId = Get-ServiceId -Environment $Environment -Service 'frontend'
    $backendImage = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.Config.Image}}', $backendId)).Trim()
    $frontendImage = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.Config.Image}}', $frontendId)).Trim()
    Assert-True ($backendImage -eq $Manifest.images.backend) "$Environment backend runs the approved digest."
    Assert-True ($frontendImage -eq $Manifest.images.frontend) "$Environment frontend runs the approved digest."
}

function Test-Environment {
    param(
        [ValidateSet('dev', 'test')][string]$Environment,
        [int]$ExistingDeploy,
        [int]$ExistingNoop,
        [int]$ExistingRollback,
        [object]$ApprovedManifest
    )
    $jobUrl = "$BaseUrl/job/XHSMedium/job/Deploy/job/$Environment"
    $deployNumber = if ($ExistingDeploy -gt 0) { $ExistingDeploy } else { Start-DeployBuild -JobUrl $jobUrl -SimulateFailure $false }
    $deploy = Wait-Build -JobUrl $jobUrl -Number $deployNumber -Minutes $TimeoutMinutes
    $deployConsole = Get-Console -JobUrl $jobUrl -Number $deployNumber
    Assert-True ($deploy.result -eq 'SUCCESS') "$Environment initial deploy build $deployNumber completed as SUCCESS."
    Assert-True ($deployConsole -match "P6_DEPLOY_OK environment=$Environment action=DEPLOYED approval=$ApprovedReleaseBuild") "$Environment initial deployment emitted its digest deployment marker."
    foreach ($secret in $script:secretValues) { Assert-True ($deployConsole -notmatch [regex]::Escape($secret)) "$Environment initial deployment console contains no local Secret value." }
    $evidence = Invoke-RestMethod -Uri "$jobUrl/$deployNumber/artifact/deployment-evidence.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($evidence.environment -eq $Environment -and $evidence.action -eq 'DEPLOYED') "$Environment initial deployment evidence records DEPLOYED."
    Assert-True ($evidence.images.backend -eq $ApprovedManifest.images.backend -and $evidence.images.frontend -eq $ApprovedManifest.images.frontend) "$Environment deployment evidence preserves the approved digests."
    Assert-EnvironmentHealthy -Environment $Environment -Manifest $ApprovedManifest

    $backendIdBefore = Get-ServiceId -Environment $Environment -Service 'backend'
    $frontendIdBefore = Get-ServiceId -Environment $Environment -Service 'frontend'
    $backendStartedBefore = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.State.StartedAt}}', $backendIdBefore)).Trim()
    $frontendStartedBefore = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.State.StartedAt}}', $frontendIdBefore)).Trim()

    $noopNumber = if ($ExistingNoop -gt 0) { $ExistingNoop } else { Start-DeployBuild -JobUrl $jobUrl -SimulateFailure $false }
    $noop = Wait-Build -JobUrl $jobUrl -Number $noopNumber -Minutes $TimeoutMinutes
    $noopConsole = Get-Console -JobUrl $jobUrl -Number $noopNumber
    Assert-True ($noop.result -eq 'SUCCESS') "$Environment idempotent build $noopNumber completed as SUCCESS."
    Assert-True ($noopConsole -match "P6_DEPLOY_OK environment=$Environment action=NOOP approval=$ApprovedReleaseBuild") "$Environment repeated digest became an explicit NOOP."
    $backendStartedAfter = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.State.StartedAt}}', (Get-ServiceId -Environment $Environment -Service 'backend'))).Trim()
    $frontendStartedAfter = (Invoke-TargetDocker -Environment $Environment -Arguments @('inspect', '--format', '{{.State.StartedAt}}', (Get-ServiceId -Environment $Environment -Service 'frontend'))).Trim()
    Assert-True ($backendStartedAfter -eq $backendStartedBefore -and $frontendStartedAfter -eq $frontendStartedBefore) "$Environment NOOP did not recreate application containers."

    $rollbackNumber = if ($ExistingRollback -gt 0) { $ExistingRollback } else { Start-DeployBuild -JobUrl $jobUrl -SimulateFailure $true }
    $rollback = Wait-Build -JobUrl $jobUrl -Number $rollbackNumber -Minutes $TimeoutMinutes
    $rollbackConsole = Get-Console -JobUrl $jobUrl -Number $rollbackNumber
    Assert-True ($rollback.result -eq 'FAILURE') "$Environment injected health failure build $rollbackNumber remained FAILURE."
    Assert-True ($rollbackConsole -match "P6_DEPLOY_ROLLED_BACK environment=$Environment approval=$ApprovedReleaseBuild") "$Environment failed rollout restored the prior successful state."
    Assert-True ($rollbackConsole -notmatch 'P6_DEPLOY_OK') "$Environment failed rollout was not reported as a successful deployment."
    $rollbackEvidence = Invoke-RestMethod -Uri "$jobUrl/$rollbackNumber/artifact/rollback-evidence.json" -Headers $script:adminHeaders -TimeoutSec 30
    Assert-True ($rollbackEvidence.healthy -and $rollbackEvidence.environment -eq $Environment) "$Environment rollback evidence records a healthy restored state."
    Assert-EnvironmentHealthy -Environment $Environment -Manifest $ApprovedManifest
    foreach ($secret in $script:secretValues) { Assert-True ($rollbackConsole -notmatch [regex]::Escape($secret)) "$Environment rollback console contains no local Secret value." }

    return [pscustomobject]@{ Deploy = $deployNumber; Noop = $noopNumber; Rollback = $rollbackNumber }
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BaseUrl = $BaseUrl.TrimEnd('/')
$adminPassword = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$adminPair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$script:adminHeaders = @{ Authorization = "Basic $adminPair" }
$crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $script:adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
$script:jenkinsSession = $jenkinsSession
$script:buildHeaders = @{} + $script:adminHeaders
$script:buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
$script:secretValues = @($adminPassword)
foreach ($name in @('registry_password', 'deploy_dev_mysql_password', 'deploy_dev_jwt_secret', 'deploy_dev_draft_key', 'deploy_test_mysql_password', 'deploy_test_jwt_secret', 'deploy_test_draft_key')) {
    $script:secretValues += [IO.File]::ReadAllText((Join-Path $repoRoot ".secrets\$name")).Trim()
}
$approvalUrl = "$BaseUrl/job/XHSMedium/job/Release/job/approve/$ApprovedReleaseBuild"
$approval = Invoke-RestMethod -Uri "$approvalUrl/api/json?tree=result" -Headers $script:adminHeaders -TimeoutSec 20
Assert-True ($approval.result -eq 'SUCCESS') "Approved Release build $ApprovedReleaseBuild is SUCCESS."
$approvedManifest = Invoke-RestMethod -Uri "$approvalUrl/artifact/approved-release-manifest.json" -Headers $script:adminHeaders -TimeoutSec 30

Push-Location $repoRoot
try {
    $dev = Test-Environment -Environment dev -ExistingDeploy $ExistingDevDeployBuild -ExistingNoop $ExistingDevNoopBuild -ExistingRollback $ExistingDevRollbackBuild -ApprovedManifest $approvedManifest
    $test = Test-Environment -Environment test -ExistingDeploy $ExistingTestDeployBuild -ExistingNoop $ExistingTestNoopBuild -ExistingRollback $ExistingTestRollbackBuild -ApprovedManifest $approvedManifest

    $devProjects = Invoke-TargetDocker -Environment dev -Arguments @('ps', '-a', '--format', '{{.Label "com.docker.compose.project"}}')
    $testProjects = Invoke-TargetDocker -Environment test -Arguments @('ps', '-a', '--format', '{{.Label "com.docker.compose.project"}}')
    Assert-True (-not @($devProjects | Where-Object { $_ -eq 'xhsmedium-test' }).Count) 'Dev target contains no test deployment containers.'
    Assert-True (-not @($testProjects | Where-Object { $_ -eq 'xhsmedium-dev' }).Count) 'Test target contains no dev deployment containers.'
    foreach ($environment in @('dev', 'test')) {
        $workspaceResidue = docker compose exec --no-TTY "deploy-$environment-agent" sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Deploy/*" ! -type d -print -quit'
        Assert-True (-not $workspaceResidue) "$environment Deploy Agent Workspace contains no residual files."
    }
    $queue = Invoke-RestMethod -Uri "$BaseUrl/queue/api/json?tree=items[id]" -Headers $script:adminHeaders -TimeoutSec 20
    Assert-True (@($queue.items).Count -eq 0) 'Jenkins queue is empty after P6 validation.'
    Write-Host "P6_DEPLOY_EVIDENCE: approval=$ApprovedReleaseBuild dev=$($dev.Deploy)/$($dev.Noop)/$($dev.Rollback) test=$($test.Deploy)/$($test.Noop)/$($test.Rollback) isolated=true cleanup=true"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
