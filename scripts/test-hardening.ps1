[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$Cycles = 3,
    [int]$RegressionBuild = 19,
    [int]$FailureBuild = 9,
    [int]$TimeoutBuild = 10,
    [int]$InterruptionBuild = 12
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$runId = "p45-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$evidenceRoot = Join-Path $repoRoot "artifacts\platform-hardening\$runId"
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
$startedAt = (Get-Date).ToUniversalTime()
$steps = [Collections.Generic.List[object]]::new()
$firstFailure = $null
$status = 'FAILED'

function Invoke-HardeningStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $stepStarted = (Get-Date).ToUniversalTime()
    $logPath = Join-Path $evidenceRoot "$Name.log"
    try {
        Write-Host "P45_STEP_START: $Name"
        $global:LASTEXITCODE = 0
        & $Action *>&1 | Tee-Object -FilePath $logPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Step $Name returned native exit code $LASTEXITCODE." }
        $steps.Add([ordered]@{ name = $Name; status = 'PASSED'; durationMs = [math]::Round(((Get-Date).ToUniversalTime() - $stepStarted).TotalMilliseconds); log = "$Name.log" })
        Write-Host "P45_STEP_PASS: $Name"
    }
    catch {
        $message = $_.Exception.Message
        $steps.Add([ordered]@{ name = $Name; status = 'FAILED'; durationMs = [math]::Round(((Get-Date).ToUniversalTime() - $stepStarted).TotalMilliseconds); log = "$Name.log"; error = $message })
        if (-not $script:firstFailure) { $script:firstFailure = [ordered]@{ step = $Name; message = $message } }
        throw
    }
}

Push-Location $repoRoot
try {
    Invoke-HardeningStep 'baseline-runtime' { .\scripts\validate.ps1 -Runtime }
    Invoke-HardeningStep 'authorization-and-library' { .\scripts\test-authorization.ps1 -RunLibrarySmoke }
    Invoke-HardeningStep 'shared-library-tests' { .\scripts\test-shared-library.ps1 }
    Invoke-HardeningStep 'agent-offline-recovery' { .\scripts\test-agents.ps1 }
    Invoke-HardeningStep 'controller-restart-persistence' { .\scripts\test-persistence.ps1 }
    Invoke-HardeningStep 'isolated-disk-pressure' { .\scripts\test-disk-pressure.ps1 }
    Invoke-HardeningStep 'isolated-backup-restore' { .\scripts\test-backup-restore.ps1 -ExpectedRegressionBuild $RegressionBuild }
    Invoke-HardeningStep 'regression-success-evidence' { .\scripts\test-xhsmedium-regression.ps1 -ExistingBuildNumber $RegressionBuild -TimeoutMinutes 20 }
    Invoke-HardeningStep 'regression-resilience-evidence' { .\scripts\test-xhsmedium-regression-resilience.ps1 -FailureBuildNumber $FailureBuild -TimeoutBuildNumber $TimeoutBuild -InterruptionBuildNumber $InterruptionBuild }
    Invoke-HardeningStep 'retention-and-cleanup' { .\scripts\test-retention.ps1 -RegressionBuild $RegressionBuild }

    foreach ($cycle in 1..$Cycles) {
        Invoke-HardeningStep "cycle-$cycle-runtime" { .\scripts\validate.ps1 -Runtime }
        Invoke-HardeningStep "cycle-$cycle-authorization" { .\scripts\test-authorization.ps1 }
        Invoke-HardeningStep "cycle-$cycle-agents" { .\scripts\test-agents.ps1 -SkipReconnect }
        Invoke-HardeningStep "cycle-$cycle-watcher" { .\scripts\test-xhsmedium-watcher.ps1 }
        Invoke-HardeningStep "cycle-$cycle-cleanup" { .\scripts\test-retention.ps1 -RegressionBuild $RegressionBuild }
    }
    $status = 'PASSED'
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    $summary = [ordered]@{
        schemaVersion = '1.0'
        runId = $runId
        mode = 'accelerated-simulation'
        simulatedCycles = $Cycles
        limitation = 'This evidence is an accelerated fault-and-recovery simulation, not one to two weeks of elapsed production observation.'
        status = $status
        startedAt = $startedAt.ToString('o')
        finishedAt = $finishedAt.ToString('o')
        durationMs = [math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
        firstFailure = $firstFailure
        steps = $steps
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'summary.json') -Encoding utf8NoBOM
    Write-Host "P45_HARDENING_EVIDENCE: runId=$runId status=$status cycles=$Cycles evidence=$evidenceRoot"
    Pop-Location
}
