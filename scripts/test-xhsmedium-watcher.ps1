[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080'
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
    Assert-True ($console -match 'SCM_NO_CHANGE sha=[0-9a-f]{40}') "Watcher build $number detected no SHA change."
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

    $workspaceFiles = docker compose exec --no-TTY build-agent sh -lc "find /home/jenkins/agent/workspace -path '*XHSMedium_CI_watch-dev*' -type f -print 2>/dev/null || true"
    Assert-True (-not $workspaceFiles) 'Watcher Workspace contains no residual files.'
    $askpassFiles = docker compose exec --no-TTY build-agent sh -lc "find /tmp -maxdepth 1 -name 'jenkins-XHSMedium-CI-watch-dev-*-watch-git-askpass' -type f -print 2>/dev/null || true"
    Assert-True (-not $askpassFiles) 'Watcher AskPass wrappers were removed.'
    Write-Host "P3B_WATCHER_EVIDENCE: builds=$first,$second downstream_next=$after"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
