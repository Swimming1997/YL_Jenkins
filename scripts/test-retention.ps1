[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$RegressionBuild = 19
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

$retention = @(
    @{ Path = 'job/Platform/job/Validation/job/shared-library-smoke'; Count = 5 },
    @{ Path = 'job/Platform/job/Validation/job/build-agent-smoke'; Count = 10 },
    @{ Path = 'job/Platform/job/Validation/job/regression-agent-smoke'; Count = 10 },
    @{ Path = 'job/XHSMedium/job/CI/job/read-only'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/CI/job/watch-dev'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/Regression/job/scheduled'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/Release/job/candidate'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/Release/job/approve'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/Deploy/job/dev'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/XHSMedium/job/Deploy/job/test'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/Platform/job/Maintenance/job/dind-regression'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/Platform/job/Maintenance/job/dind-release'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/Platform/job/Maintenance/job/dind-deploy-dev'; Count = 20; Artifacts = 5 },
    @{ Path = 'job/Platform/job/Maintenance/job/dind-deploy-test'; Count = 20; Artifacts = 5 }
)

foreach ($job in $retention) {
    $config = (Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$($job.Path)/config.xml" -Headers $headers -TimeoutSec 20).Content
    Assert-True ($config -match "<numToKeep>$($job.Count)</numToKeep>") "$($job.Path) retains the configured $($job.Count) builds."
    if ($job.ContainsKey('Artifacts')) {
        Assert-True ($config -match "<artifactNumToKeep>$($job.Artifacts)</artifactNumToKeep>") "$($job.Path) retains the configured $($job.Artifacts) complete Artifact sets."
    }
}

$regressionUrl = "$BaseUrl/job/XHSMedium/job/Regression/job/scheduled/$RegressionBuild"
Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri "$regressionUrl/artifact/offline-dependency-cache.log" -Headers $headers -TimeoutSec 20).StatusCode -eq 200) 'Retained regression build includes offline cache evidence.'
$console = (Invoke-WebRequest -UseBasicParsing -Uri "$regressionUrl/consoleText" -Headers $headers -TimeoutSec 20).Content
$identity = [regex]::Match($console, 'P4_SCHEDULED_REGRESSION_OK runId=(scheduled-[0-9]{8}-[0-9]{6}-[0-9a-f]{8})')
Assert-True $identity.Success 'Retained regression build records its runId.'
$project = "xhsmedium-test-$($identity.Groups[1].Value)"
$summaryUrl = "$regressionUrl/artifact/artifacts/test-runs/$($identity.Groups[1].Value)/summary.json"
Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri $summaryUrl -Headers $headers -TimeoutSec 20).StatusCode -eq 200) 'Retained regression build includes Requirement summary evidence.'

Push-Location $repoRoot
try {
    $controllerUse = [int](docker compose exec --no-TTY controller sh -lc 'df -Pk /var/jenkins_home | tail -1 | tr -s " " | cut -d " " -f5 | tr -d "%"').Trim()
    $dindUse = [int](docker compose exec --no-TTY regression-docker sh -lc 'df -Pk /var/lib/docker | tail -1 | tr -s " " | cut -d " " -f5 | tr -d "%"').Trim()
    Assert-True ($controllerUse -lt 90) 'Jenkins Home filesystem remains below the 90% safety threshold.'
    Assert-True ($dindUse -lt 90) 'Isolated DIND filesystem remains below the 90% safety threshold.'

    $scheduledContainers = docker compose exec --no-TTY regression-docker docker ps --all --quiet --filter 'label=com.docker.compose.project' | ForEach-Object {
        docker compose exec --no-TTY regression-docker docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' $_
    } | Where-Object { $_ -match '^xhsmedium-test-scheduled-' }
    Assert-True (-not $scheduledContainers) 'No scheduled regression container remains after completed builds.'
    $runImageResidue = docker compose exec --no-TTY regression-docker docker image ls --format '{{.Repository}}:{{.Tag}}' | Where-Object {
        $_ -in @("${project}-backend:latest", "${project}-frontend:latest", "${project}-runner:latest")
    }
    Assert-True (-not $runImageResidue) "Build $RegressionBuild has no residual run images."
    $workspaceResidue = docker compose exec --no-TTY regression-agent sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Regression/scheduled/*" -print -quit'
    Assert-True (-not $workspaceResidue) 'Scheduled regression Workspace is clean.'

    $trackedPrune = git grep -n -E 'docker[[:space:]]+system[[:space:]]+prune|docker[[:space:]]+volume[[:space:]]+prune' -- . ':!docs/*'
    Assert-True (-not $trackedPrune) 'Platform automation contains no global Docker prune command.'
    Write-Host "P45_RETENTION_EVIDENCE: regression_build=$RegressionBuild controller_use_pct=$controllerUse dind_use_pct=$dindUse run_images=0 residue=0"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
