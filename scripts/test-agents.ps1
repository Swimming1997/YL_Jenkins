[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [switch]$SkipReconnect
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$BaseUrl = $BaseUrl.TrimEnd('/')
$adminPassword = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$pair = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$adminHeaders = @{ Authorization = "Basic $pair" }
$crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
$buildHeaders = @{} + $adminHeaders
$buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
$agentsStopped = $false

function Invoke-ValidationJob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedResult,
        [string]$Marker
    )
    $jobUrl = "$BaseUrl/job/Platform/job/Validation/job/$Name"
    $job = Invoke-RestMethod -Uri "$jobUrl/api/json" -Headers $adminHeaders -TimeoutSec 20
    $buildNumber = [int]$job.nextBuildNumber
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' -Uri "$jobUrl/build" -Headers $buildHeaders -WebSession $jenkinsSession -TimeoutSec 20
    if ([int]$response.StatusCode -notin @(200, 201, 202)) { throw "Could not trigger ${Name}: HTTP $($response.StatusCode)." }

    $deadline = (Get-Date).AddMinutes(8)
    $build = $null
    do {
        Start-Sleep -Seconds 2
        $result = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$jobUrl/$buildNumber/api/json" -Headers $adminHeaders -TimeoutSec 20
        if ([int]$result.StatusCode -eq 200) {
            $build = $result.Content | ConvertFrom-Json
            if (-not $build.building) { break }
        }
    } while ((Get-Date) -lt $deadline)

    if (-not $build -or $build.building) { throw "$Name build $buildNumber did not finish." }
    if ($build.result -ne $ExpectedResult) { throw "$Name build $buildNumber was $($build.result), expected $ExpectedResult." }
    if ($Marker) {
        $console = Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$buildNumber/consoleText" -Headers $adminHeaders -TimeoutSec 20
        if ($console.Content -notmatch [regex]::Escape($Marker)) { throw "$Name build $buildNumber did not emit marker $Marker." }
    }
    Write-Host "PASS: $Name build $buildNumber completed as $ExpectedResult."
    return $buildNumber
}

function Wait-AgentsOnline {
    $deadline = (Get-Date).AddMinutes(4)
    do {
        $nodes = Invoke-RestMethod -Uri "$BaseUrl/computer/api/json?tree=computer[displayName,offline]" -Headers $adminHeaders -TimeoutSec 20
        $buildNode = $nodes.computer | Where-Object displayName -eq 'build-agent'
        $regressionNode = $nodes.computer | Where-Object displayName -eq 'regression-agent'
        $releaseNode = $nodes.computer | Where-Object displayName -eq 'release-agent'
        if ($buildNode -and $regressionNode -and $releaseNode -and -not $buildNode.offline -and -not $regressionNode.offline -and -not $releaseNode.offline) {
            Write-Host 'PASS: Build, Regression, and Release Agents are online.'
            return
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw 'Agents did not become online within four minutes.'
}

function Wait-AgentsOffline {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        $nodes = Invoke-RestMethod -Uri "$BaseUrl/computer/api/json?tree=computer[displayName,offline]" -Headers $adminHeaders -TimeoutSec 20
        $buildNode = $nodes.computer | Where-Object displayName -eq 'build-agent'
        $regressionNode = $nodes.computer | Where-Object displayName -eq 'regression-agent'
        $releaseNode = $nodes.computer | Where-Object displayName -eq 'release-agent'
        if ($buildNode -and $regressionNode -and $releaseNode -and $buildNode.offline -and $regressionNode.offline -and $releaseNode.offline) {
            Write-Host 'PASS: Jenkins observed all three Agents offline.'
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw 'Jenkins did not observe both Agents offline within two minutes.'
}

Push-Location $repoRoot
try {
    Wait-AgentsOnline
    Invoke-ValidationJob -Name 'build-agent-smoke' -ExpectedResult 'SUCCESS' -Marker 'BUILD_AGENT_OK' | Out-Null
    Invoke-ValidationJob -Name 'regression-agent-smoke' -ExpectedResult 'SUCCESS' -Marker 'REGRESSION_AGENT_OK' | Out-Null
    Invoke-ValidationJob -Name 'release-agent-smoke' -ExpectedResult 'SUCCESS' -Marker 'RELEASE_AGENT_OK' | Out-Null
    Invoke-ValidationJob -Name 'workspace-cleanup' -ExpectedResult 'SUCCESS' -Marker 'WORKSPACE_MARKER_CREATED' | Out-Null

    $workspaceResidue = docker compose exec --no-TTY build-agent sh -lc 'find /home/jenkins/agent -name marker.txt -print'
    if ($workspaceResidue) { throw "Workspace marker remains: $workspaceResidue" }
    Write-Host 'PASS: Workspace marker was cleaned.'

    $timeoutBuild = Invoke-ValidationJob -Name 'timeout-cleanup' -ExpectedResult 'ABORTED'
    docker compose exec --no-TTY regression-agent docker network inspect "p2-timeout-$timeoutBuild" *> $null
    if ($LASTEXITCODE -eq 0) { throw "Timeout network still exists: p2-timeout-$timeoutBuild" }
    Write-Host 'PASS: Timeout Docker network was removed by exact name.'

    if (-not $SkipReconnect) {
        docker compose stop build-agent regression-agent release-agent
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop Agents for the offline drill.' }
        $agentsStopped = $true
        Wait-AgentsOffline
        docker compose start build-agent regression-agent release-agent
        if ($LASTEXITCODE -ne 0) { throw 'Could not start Agents after the offline drill.' }
        $agentsStopped = $false
        Wait-AgentsOnline
        Invoke-ValidationJob -Name 'agent-reconnect' -ExpectedResult 'SUCCESS' | Out-Null
    }

    $global:LASTEXITCODE = 0
}
finally {
    if ($agentsStopped) { docker compose start build-agent regression-agent release-agent | Out-Host }
    Pop-Location
}
