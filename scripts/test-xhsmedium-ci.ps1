[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [string]$Branch = 'dev',
    [string]$GitSha = '',
    [int]$TimeoutMinutes = 45
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
$adminPassword = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
$pair = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
$adminHeaders = @{ Authorization = "Basic $pair" }
$crumb = Invoke-RestMethod -Uri "$BaseUrl/crumbIssuer/api/json" -Headers $adminHeaders -SessionVariable jenkinsSession -TimeoutSec 20
$buildHeaders = @{} + $adminHeaders
$buildHeaders[$crumb.crumbRequestField] = $crumb.crumb
$jobUrl = "$BaseUrl/job/XHSMedium/job/CI/job/read-only"

Push-Location $repoRoot
try {
    $job = Invoke-RestMethod -Uri "$jobUrl/api/json" -Headers $adminHeaders -TimeoutSec 20
    $buildNumber = [int]$job.nextBuildNumber
    $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -ContentType 'application/x-www-form-urlencoded' `
        -Uri "$jobUrl/buildWithParameters" -Headers $buildHeaders -WebSession $jenkinsSession `
        -Body @{ BRANCH = $Branch; GIT_SHA = $GitSha } -TimeoutSec 20
    Assert-True ([int]$response.StatusCode -in @(200, 201, 202)) 'The read-only CI build was accepted.'

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $build = $null
    do {
        Start-Sleep -Seconds 3
        $result = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$jobUrl/$buildNumber/api/json" -Headers $adminHeaders -TimeoutSec 20
        if ([int]$result.StatusCode -eq 200) {
            $build = $result.Content | ConvertFrom-Json
            if (-not $build.building) { break }
        }
    } while ((Get-Date) -lt $deadline)

    Assert-True ($null -ne $build -and -not $build.building) "Build $buildNumber completed within $TimeoutMinutes minutes."
    $console = (Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$buildNumber/consoleText" -Headers $adminHeaders -TimeoutSec 20).Content
    if ($build.result -ne 'SUCCESS') {
        $firstFailure = ($console -split "`r?`n" | Where-Object { $_ -match '(?i)(npm ERR!|FAIL|ERROR|Exception|script returned exit code)' } | Select-Object -First 1)
        if (-not $firstFailure) { $firstFailure = 'No concise failure line was found; inspect the Jenkins console.' }
        throw "XHSMedium CI build $buildNumber was $($build.result). First failure: $firstFailure Build: $jobUrl/$buildNumber/"
    }
    Write-Host "PASS: XHSMedium CI build $buildNumber completed as SUCCESS."

    Assert-True ($build.builtOn -eq 'build-agent') 'The project build ran on build-agent.'
    Assert-True ($console -match 'RESOLVED_SHA=([0-9a-f]{40})') 'The build logged a full resolved SHA.'
    $resolvedSha = $Matches[1]
    if ($GitSha) {
        Assert-True ($resolvedSha -eq $GitSha.ToLowerInvariant()) 'The requested fixed SHA was built exactly.'
    }
    Assert-True ($console -match 'READ_ONLY_CI_OK') 'Tracked source files remained unchanged.'
    Assert-True ($console -match 'QUALITY_GAP: backend npm run lint is omitted') 'The mutating backend lint gap was reported.'

    $metadata = (Invoke-WebRequest -UseBasicParsing -Uri "$jobUrl/$buildNumber/artifact/ci-evidence/build-metadata.txt" -Headers $adminHeaders -TimeoutSec 20).Content
    Assert-True ($metadata -match "(?m)^repository=https://github.com/MuFannnn/xhsmedium.git$") 'Metadata records the fixed repository.'
    Assert-True ($metadata -match "(?m)^branch=$([regex]::Escape($Branch))$") 'Metadata records the requested branch.'
    Assert-True ($metadata -match "(?m)^sha=$resolvedSha$") 'Metadata records the checked-out SHA.'
    Assert-True ($metadata -match '(?m)^release_eligible=false$') 'Metadata marks outputs as non-release evidence.'
    Assert-True ($metadata -match '(?m)^backend_lint=omitted_mutating_command$') 'Metadata records the backend lint quality gap.'

    foreach ($artifact in @('backend.log', 'backend-tests.json', 'frontend.log', 'automation.log', 'regression.log')) {
        $artifactResponse = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck `
            -Uri "$jobUrl/$buildNumber/artifact/ci-evidence/$artifact" -Headers $adminHeaders -TimeoutSec 20
        Assert-True ([int]$artifactResponse.StatusCode -eq 200) "Artifact '$artifact' was archived."
    }

    $controller = Invoke-RestMethod -Uri "$BaseUrl/computer/(built-in)/api/json" -Headers $adminHeaders -TimeoutSec 20
    Assert-True ([int]$controller.numExecutors -eq 0) 'Controller executor count remains zero.'

    $workspaceFiles = docker compose exec --no-TTY build-agent sh -lc "find /home/jenkins/agent/workspace -path '*XHSMedium_CI_read-only*' -type f -print 2>/dev/null || true"
    Assert-True (-not $workspaceFiles) 'The read-only CI Workspace contains no residual files.'
    Write-Host "P3A_EVIDENCE: build=$buildNumber sha=$resolvedSha duration_ms=$($build.duration)"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
