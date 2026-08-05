[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][int]$FailureBuildNumber,
    [Parameter(Mandatory)][int]$TimeoutBuildNumber,
    [Parameter(Mandatory)][int]$InterruptionBuildNumber
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

function Get-BuildEvidence {
    param([int]$Number)
    $build = Invoke-RestMethod -Uri "$jobUrl/$Number/api/json?tree=number,building,result,duration,description" -Headers $headers -TimeoutSec 20
    $console = (Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$Number/consoleText" -Headers $headers -TimeoutSec 30).Content
    $identity = [regex]::Match([string]$build.description, 'SHA=([0-9a-f]{8}) RUN=(scheduled-[0-9]{8}-[0-9]{6}-[0-9a-f]{8})')
    Assert-True (-not $build.building) "Build $Number is complete."
    Assert-True $identity.Success "Build $Number description records its fixed SHA and runId."
    [pscustomobject]@{ Build = $build; Console = $console; RunId = $identity.Groups[2].Value }
}

function Assert-ExactProjectClean {
    param([string]$RunId)
    $project = "xhsmedium-test-$RunId"
    $containers = docker compose exec --no-TTY regression-docker docker ps --all --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $containers) "Project $project has no residual containers."
    $volumes = docker compose exec --no-TTY regression-docker docker volume ls --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $volumes) "Project $project has no residual volumes."
    $networks = docker compose exec --no-TTY regression-docker docker network ls --quiet --filter "label=com.docker.compose.project=$project"
    Assert-True (-not $networks) "Project $project has no residual networks."
}

function Assert-ExactRunImagesClean {
    param([string]$RunId, [string]$Console)
    $project = "xhsmedium-test-$RunId"
    $expected = @(
        "${project}-backend:latest"
        "${project}-frontend:latest"
        "${project}-runner:latest"
    )
    $images = docker compose exec --no-TTY regression-docker docker image ls --format '{{.Repository}}:{{.Tag}}'
    $residue = @($images | Where-Object { $_ -in $expected })
    Assert-True (-not $residue) "Project $project has no residual run images."
    Assert-True ($Console -match "RESIDUE_CLEANUP_EVIDENCE scope=$([regex]::Escape($project)).*residue=0 status=OK") "Project $project records zero-residue run image cleanup evidence."
}

Push-Location $repoRoot
try {
$failure = Get-BuildEvidence $FailureBuildNumber
Assert-True ($failure.Build.result -eq 'FAILURE') "Failure build $FailureBuildNumber is FAILURE."
Assert-True ($failure.Console -notmatch 'P4_SCHEDULED_REGRESSION_OK') 'Failure build did not emit the success marker.'
$failureSummary = Invoke-RestMethod -Uri "$jobUrl/$FailureBuildNumber/artifact/artifacts/test-runs/$($failure.RunId)/summary.json" -Headers $headers -TimeoutSec 30
Assert-True ($failureSummary.status -eq 'FAILED') 'Failure summary records FAILED.'
Assert-True ([bool]$failureSummary.firstFailure.stageId -and [bool]$failureSummary.firstFailure.classification) 'Failure summary preserves the first useful failure.'
Assert-True ($failureSummary.cleanup.attempted -and $failureSummary.cleanup.succeeded) 'Failure summary records successful automation cleanup.'
Assert-ExactProjectClean $failure.RunId
Assert-ExactRunImagesClean $failure.RunId $failure.Console

$timeout = Get-BuildEvidence $TimeoutBuildNumber
Assert-True ($timeout.Build.result -eq 'ABORTED') "Timeout build $TimeoutBuildNumber is ABORTED."
Assert-True ($timeout.Console -match 'Timeout has been exceeded') 'Timeout build records the Jenkins timeout cause.'
Assert-True ($timeout.Console -notmatch 'P4_SCHEDULED_REGRESSION_OK') 'Timeout build did not emit the success marker.'
Assert-ExactProjectClean $timeout.RunId
Assert-ExactRunImagesClean $timeout.RunId $timeout.Console

$interruption = Get-BuildEvidence $InterruptionBuildNumber
Assert-True ($interruption.Build.result -eq 'ABORTED') "Interruption build $InterruptionBuildNumber is ABORTED."
Assert-True ($interruption.Console -match 'Aborted by Local Platform Administrator') 'Interruption build records the administrator actor.'
Assert-True ($interruption.Console -match "P4_EXACT_PROJECT_CLEANUP_OK project=xhsmedium-test-$([regex]::Escape($interruption.RunId))") 'Interruption build records converged exact project cleanup.'
Assert-True ($interruption.Console -notmatch 'P4_SCHEDULED_REGRESSION_OK') 'Interruption build did not emit the success marker.'
Assert-ExactProjectClean $interruption.RunId
Assert-ExactRunImagesClean $interruption.RunId $interruption.Console

    $workspaceResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Regression/scheduled/*" -print -quit'
    Assert-True (-not $workspaceResidue) 'Scheduled regression Workspace is clean after resilience builds.'
    $cacheResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /tmp -maxdepth 1 -name "jenkins-XHSMedium-Regression-scheduled-*-npm-cache" -print -quit'
    Assert-True (-not $cacheResidue) 'Scheduled regression npm caches are clean after resilience builds.'
    $compatResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /home/jenkins/agent/.platform-compat -maxdepth 1 -type f -name "jenkins-XHSMedium-Regression-scheduled-*" -print -quit 2>/dev/null || true'
    Assert-True (-not $compatResidue) 'Scheduled regression compatibility files are clean after resilience builds.'
}
finally {
    Pop-Location
}

Write-Host "P4_RESILIENCE_EVIDENCE: failure=$FailureBuildNumber timeout=$TimeoutBuildNumber interruption=$InterruptionBuildNumber run_images=0 cleanup=true"
$global:LASTEXITCODE = 0
