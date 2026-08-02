[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$ExistingBuildNumber = 0,
    [switch]$WaitForScheduled,
    [int]$TimeoutMinutes = 430
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$BaseUrl = $BaseUrl.TrimEnd('/')
$password = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$password"))
$headers = @{ Authorization = "Basic $pair" }
$jobUrl = "$BaseUrl/job/XHSMedium/job/Regression/job/scheduled"
$config = (Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/config.xml" -Headers $headers -TimeoutSec 20).Content
Assert-True ($config -match '0 \*/2 \* \* \*') 'Scheduled regression cron runs at each even-hour slot.'

$job = Invoke-RestMethod -Uri "$jobUrl/api/json?tree=nextBuildNumber,lastBuild[number]" -Headers $headers -TimeoutSec 20
if ($ExistingBuildNumber -gt 0) {
    $buildNumber = $ExistingBuildNumber
    Write-Host "INFO: Revalidating scheduled regression build $buildNumber."
}
elseif ($WaitForScheduled) {
    $buildNumber = [int]$job.nextBuildNumber
    Write-Host "INFO: Waiting for cron to create scheduled regression build $buildNumber."
}
else {
    throw 'Specify -ExistingBuildNumber or -WaitForScheduled. Manual non-slot runs are intentionally not acceptance evidence.'
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$build = $null
do {
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$jobUrl/$buildNumber/api/json?tree=number,building,result,duration,actions[causes[*]]" -Headers $headers -TimeoutSec 20
    if ([int]$response.StatusCode -eq 200) {
        $build = $response.Content | ConvertFrom-Json
        if (-not $build.building) { break }
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)

Assert-True ($null -ne $build -and -not $build.building) "Scheduled regression build $buildNumber completed within $TimeoutMinutes minutes."
Assert-True ($build.result -eq 'SUCCESS') "Scheduled regression build $buildNumber completed as SUCCESS."

$console = (Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$buildNumber/consoleText" -Headers $headers -TimeoutSec 30).Content
Assert-True ($console -match 'Running on regression-agent') 'Scheduled regression ran on the Regression Agent.'
Assert-True ($console -match 'OFFLINE_DEPENDENCY_CACHE role=runner') 'Runner image used the offline dependency cache.'
Assert-True ($console -match 'OFFLINE_DEPENDENCY_CACHE role=backend,frontend') 'Backend and frontend images used offline dependency caches.'
Assert-True ($console -match 'P4_SCHEDULED_REGRESSION_OK') 'Scheduled regression emitted its completion marker.'

$identity = [regex]::Match($console, 'P4_SCHEDULED_REGRESSION_OK runId=(scheduled-[0-9]{8}-[0-9]{4}-[0-9a-f]{8}) sha=([0-9a-f]{40})')
Assert-True ($identity.Success) 'Console records a unique scheduled runId and full SHA.'
$runId = $identity.Groups[1].Value
$sha = $identity.Groups[2].Value
$project = "xhsmedium-test-$runId"

$summaryUrl = "$jobUrl/$buildNumber/artifact/artifacts/test-runs/$runId/summary.json"
$summary = Invoke-RestMethod -Uri $summaryUrl -Headers $headers -TimeoutSec 30
Assert-True ($summary.runId -eq $runId) 'Archived summary matches the scheduled runId.'
Assert-True ($summary.testedSha -eq $sha) 'Archived summary matches the fixed tested SHA.'
Assert-True ($summary.executor -eq 'docker') 'Archived summary records the Docker executor.'
Assert-True ($summary.status -eq 'PASSED') 'Archived Requirement summary is PASSED.'
Assert-True ($summary.cleanup.attempted -and $summary.cleanup.succeeded) 'Archived summary records successful cleanup.'

Push-Location $repoRoot
try {
    $containers = docker compose exec --no-TTY regression-docker docker ps --all --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $containers) 'The exact regression Compose project has no residual containers.'
    $volumes = docker compose exec --no-TTY regression-docker docker volume ls --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $volumes) 'The exact regression Compose project has no residual volumes.'
    $networks = docker compose exec --no-TTY regression-docker docker network ls --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $networks) 'The exact regression Compose project has no residual networks.'
    $workspaceResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Regression/scheduled/*" -print -quit'
    Assert-True (-not $workspaceResidue) 'Scheduled regression Workspace was cleaned.'
    $cacheResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /tmp -maxdepth 1 -name "jenkins-XHSMedium-Regression-scheduled-*-npm-cache" -print -quit'
    Assert-True (-not $cacheResidue) 'Scheduled regression npm cache was cleaned.'
}
finally {
    Pop-Location
}

Write-Host "P4_REGRESSION_EVIDENCE: build=$buildNumber runId=$runId sha=$sha duration_ms=$($build.duration)"
$global:LASTEXITCODE = 0
