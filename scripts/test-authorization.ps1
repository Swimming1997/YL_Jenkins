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
