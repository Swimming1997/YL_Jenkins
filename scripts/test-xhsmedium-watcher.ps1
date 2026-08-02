[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [switch]$TestChangeTrigger
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$BaseUrl = $BaseUrl.TrimEnd('/')
$adminPassword = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$headers = @{ Authorization = "Basic $pair" }
$crumb = Invoke-RestMethod "$BaseUrl/crumbIssuer/api/json" -Headers $headers -SessionVariable session -TimeoutSec 20
$postHeaders = @{} + $headers
$postHeaders[$crumb.crumbRequestField] = $crumb.crumb
$watcherUrl = "$BaseUrl/job/XHSMedium/job/CI/job/watch-dev"
$ciUrl = "$BaseUrl/job/XHSMedium/job/CI/job/read-only"

function Invoke-WatcherBuild {
    param([string]$ExpectedMarker = 'SCM_NO_CHANGE')
    $job = Invoke-RestMethod "$watcherUrl/api/json?tree=nextBuildNumber" -Headers $headers -TimeoutSec 20
    $number = [int]$job.nextBuildNumber
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -Uri "$watcherUrl/build" -Headers $postHeaders -WebSession $session -TimeoutSec 20
    Assert-True ([int]$response.StatusCode -in @(200, 201, 202)) "Watcher build $number was accepted."
    $deadline = (Get-Date).AddMinutes(3)
    $build = $null
    do {
        Start-Sleep -Seconds 2
        $result = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$watcherUrl/$number/api/json" -Headers $headers -TimeoutSec 20
        if ([int]$result.StatusCode -eq 200) {
            $build = $result.Content | ConvertFrom-Json
            if (-not $build.building) { break }
        }
    } while ((Get-Date) -lt $deadline)
    Assert-True ($null -ne $build -and -not $build.building -and $build.result -eq 'SUCCESS') "Watcher build $number completed successfully."
    $console = (Invoke-WebRequest -UseBasicParsing "$watcherUrl/$number/consoleText" -Headers $headers -TimeoutSec 20).Content
    Assert-True ($console -match "$ExpectedMarker.*[0-9a-f]{40}") "Watcher build $number emitted $ExpectedMarker."
    return $number
}

Push-Location $repoRoot
try {
    $config = (Invoke-WebRequest -UseBasicParsing "$watcherUrl/config.xml" -Headers $headers -TimeoutSec 20).Content
    Assert-True ($config -match 'H \* \* \* \*') 'Watcher cron runs once per hour.'
    $before = [int](Invoke-RestMethod "$ciUrl/api/json?tree=nextBuildNumber" -Headers $headers -TimeoutSec 20).nextBuildNumber
    $first = Invoke-WatcherBuild
    $second = Invoke-WatcherBuild
    $after = [int](Invoke-RestMethod "$ciUrl/api/json?tree=nextBuildNumber" -Headers $headers -TimeoutSec 20).nextBuildNumber
    Assert-True ($before -eq $after) 'Unchanged dev SHA did not trigger a full CI build.'

    $triggeredBuild = 0
    if ($TestChangeTrigger) {
        $secondState = Invoke-RestMethod "$watcherUrl/$second/api/json?tree=description" -Headers $headers -TimeoutSec 20
        $originalDescription = $secondState.description
        Assert-True ($originalDescription -match '^SHA=[0-9a-f]{40}$') 'Watcher state contains a restorable observed SHA.'
        try {
            $syntheticOldSha = '0000000000000000000000000000000000000000'
            $update = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' `
                -Uri "$watcherUrl/$second/submitDescription" -Headers $postHeaders -WebSession $session `
                -Body @{ description = "SHA=$syntheticOldSha" } -TimeoutSec 20
            Assert-True ([int]$update.StatusCode -in @(200, 201, 302)) 'Synthetic previous SHA was installed for isolated trigger validation.'
            $triggeredBuild = [int](Invoke-RestMethod "$ciUrl/api/json?tree=nextBuildNumber" -Headers $headers -TimeoutSec 20).nextBuildNumber
            $third = Invoke-WatcherBuild -ExpectedMarker 'SCM_CHANGE_TRIGGERED'
            $nextAfterTrigger = [int](Invoke-RestMethod "$ciUrl/api/json?tree=nextBuildNumber" -Headers $headers -TimeoutSec 20).nextBuildNumber
            Assert-True ($nextAfterTrigger -eq ($triggeredBuild + 1)) "Changed SHA triggered full CI build $triggeredBuild exactly once."
        }
        finally {
            $restore = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' `
                -Uri "$watcherUrl/$second/submitDescription" -Headers $postHeaders -WebSession $session `
                -Body @{ description = $originalDescription } -TimeoutSec 20
            Assert-True ([int]$restore.StatusCode -in @(200, 201, 302)) 'Synthetic watcher history was restored.'
        }
    }

    $workspaceFiles = docker compose exec --no-TTY build-agent sh -lc "find /home/jenkins/agent/workspace -path '*XHSMedium_CI_watch-dev*' -type f -print 2>/dev/null || true"
    Assert-True (-not $workspaceFiles) 'Watcher Workspace contains no residual files.'
    $askpassFiles = docker compose exec --no-TTY build-agent sh -lc "find /tmp -maxdepth 1 -name 'jenkins-XHSMedium-CI-watch-dev-*-watch-git-askpass' -type f -print 2>/dev/null || true"
    Assert-True (-not $askpassFiles) 'Watcher AskPass wrappers were removed.'
    Write-Host "P3B_WATCHER_EVIDENCE: unchanged_builds=$first,$second triggered_ci=$triggeredBuild downstream_next=$after"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
