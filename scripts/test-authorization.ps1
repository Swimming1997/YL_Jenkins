[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [switch]$RunLibrarySmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-BasicHeaders {
    param([string]$User, [string]$Password)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("${User}:$Password")
    return @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }
}

function Get-StatusCode {
    param([string]$Uri, [hashtable]$Headers = @{})
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri $Uri -Headers $Headers -TimeoutSec 20
    return [int]$response.StatusCode
}

function Assert-Status {
    param([int]$Actual, [int]$Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected HTTP $Expected, received $Actual." }
    Write-Host "PASS: $Message"
}

function Assert-StatusIn {
    param([int]$Actual, [int[]]$Expected, [string]$Message)
    if ($Actual -notin $Expected) { throw "$Message Expected HTTP $($Expected -join ' or '), received $Actual." }
    Write-Host "PASS: $Message"
}

$adminPassword = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$auditPassword = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_audit_password')).Trim()
$adminHeaders = Get-BasicHeaders -User 'admin' -Password $adminPassword
$auditHeaders = Get-BasicHeaders -User 'audit' -Password $auditPassword
$BaseUrl = $BaseUrl.TrimEnd('/')

Assert-Status (Get-StatusCode -Uri "$BaseUrl/api/json") 403 'Anonymous API access is denied.'
Assert-Status (Get-StatusCode -Uri "$BaseUrl/api/json" -Headers $auditHeaders) 200 'Audit account can read Jenkins.'
Assert-Status (Get-StatusCode -Uri "$BaseUrl/configure" -Headers $auditHeaders) 403 'Audit account cannot configure Jenkins.'
Assert-Status (Get-StatusCode -Uri "$BaseUrl/configure" -Headers $adminHeaders) 200 'Administrator can configure Jenkins.'
Assert-Status (Get-StatusCode -Uri "$BaseUrl/job/XHSMedium/job/CI/api/json" -Headers $auditHeaders) 200 'Audit account can read generated XHSMedium folders.'
Assert-Status (Get-StatusCode -Uri "$BaseUrl/script" -Headers $auditHeaders) 403 'Audit account cannot access the Script Console.'
Assert-StatusIn (Get-StatusCode -Uri "$BaseUrl/manage/credentials/store/system/domain/_/" -Headers $auditHeaders) @(403, 404) 'Audit account cannot browse system credentials.'
$auditCrumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $auditHeaders -SessionVariable auditSession -TimeoutSec 20
$auditBuildHeaders = @{} + $auditHeaders
$auditBuildHeaders[$auditCrumb.crumbRequestField] = $auditCrumb.crumb
$auditBuildResponse = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -Uri "$BaseUrl/job/XHSMedium/job/CI/job/read-only/build" -Headers $auditBuildHeaders -WebSession $auditSession -TimeoutSec 20
Assert-Status ([int]$auditBuildResponse.StatusCode) 403 'Audit account cannot trigger the CI job.'

$buildAgentId = (docker compose -f (Join-Path $repoRoot 'compose.yaml') ps --quiet build-agent).Trim()
$regressionAgentId = (docker compose -f (Join-Path $repoRoot 'compose.yaml') ps --quiet regression-agent).Trim()
if (-not $buildAgentId -or -not $regressionAgentId) { throw 'Both Agents must be running for credential-boundary validation.' }
$buildMounts = @((docker inspect $buildAgentId | ConvertFrom-Json)[0].Mounts)
$regressionMounts = @((docker inspect $regressionAgentId | ConvertFrom-Json)[0].Mounts)
if ($buildMounts.Source -match 'xhsmedium_scm_token|jenkins_admin_password|jenkins_audit_password') { throw 'Build Agent mounts a Controller credential source.' }
if ($regressionMounts.Source -match 'xhsmedium_scm_token|jenkins_admin_password|jenkins_audit_password') { throw 'Regression Agent mounts a Controller credential source.' }
Write-Host 'PASS: Agent containers mount no Controller password or SCM token source.'

docker exec $buildAgentId sh -lc 'test ! -e /var/run/docker.sock && ! command -v docker >/dev/null 2>&1'
if ($LASTEXITCODE -ne 0) { throw 'Build Agent unexpectedly exposes Docker capability.' }
Write-Host 'PASS: Untrusted Build Agent surface has no Docker CLI or host Docker Socket.'

docker exec $buildAgentId sh -lc 'getent hosts regression-docker >/dev/null 2>&1'
if ($LASTEXITCODE -eq 0) { throw 'Build Agent can resolve the isolated DIND endpoint.' }
Write-Host 'PASS: Build Agent cannot resolve the isolated DIND endpoint.'
$global:LASTEXITCODE = 0

if ($RunLibrarySmoke) {
    $jobUrl = "$BaseUrl/job/Platform/job/Validation/job/shared-library-smoke"
    $job = Invoke-RestMethod -Uri "$jobUrl/api/json" -Headers $adminHeaders -TimeoutSec 20
    $expectedBuild = [int]$job.nextBuildNumber
    $crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
    $buildHeaders = @{} + $adminHeaders
    $buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' -Uri "$jobUrl/build" -Headers $buildHeaders -WebSession $jenkinsSession -TimeoutSec 20
    if ([int]$response.StatusCode -notin @(200, 201, 202)) { throw "Could not trigger Shared Library smoke build: HTTP $($response.StatusCode)." }

    $deadline = (Get-Date).AddMinutes(3)
    $build = $null
    do {
        Start-Sleep -Seconds 2
        $result = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$jobUrl/$expectedBuild/api/json" -Headers $adminHeaders -TimeoutSec 20
        if ([int]$result.StatusCode -eq 200) {
            $build = $result.Content | ConvertFrom-Json
            if (-not $build.building) { break }
        }
    } while ((Get-Date) -lt $deadline)

    if (-not $build -or $build.building) { throw 'Shared Library smoke build did not finish within three minutes.' }
    if ($build.result -ne 'SUCCESS') { throw "Shared Library smoke build result was $($build.result)." }
    $console = Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$expectedBuild/consoleText" -Headers $adminHeaders -TimeoutSec 20
    if ($console.Content -notmatch 'SCM_LIBRARY_OK') { throw 'Shared Library smoke marker was not found in the build log.' }
    Write-Host "PASS: SCM Shared Library loaded from GitHub in build $expectedBuild."
}
