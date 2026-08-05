[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$helper = '/repo/shared-library/resources/xhsmedium/docker-dind-maintenance.sh'
$containerImage = 'jenkins-platform/regression-agent:node20-playwright1.59.1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "rrm-d31-$([guid]::NewGuid().ToString('N'))"
$fakeDockerPath = Join-Path $tempRoot 'fake-docker'
$statePath = Join-Path $tempRoot 'images'

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Set-FakeState {
    param([string[]]$Images, [string]$Cache = '6GB', [string]$Reclaimable = '4GB')
    Write-Utf8NoBom -Path $statePath -Content (($Images -join "`n") + "`n")
    Write-Utf8NoBom -Path (Join-Path $tempRoot 'cache') -Content "$Cache`t$Reclaimable`n"
    foreach ($marker in @('removed', 'pruned', 'running', 'fail-list', 'stubborn-cache')) {
        Remove-Item -LiteralPath (Join-Path $tempRoot $marker) -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Maintenance {
    param(
        [string]$Target,
        [string]$Mode = 'AUDIT',
        [string]$CurrentSha = '',
        [string]$PreviousSha = '',
        [string]$Confirmation = ''
    )
    $command = "chmod +x /test/fake-docker && bash $helper '$Target' '$Mode' '$CurrentSha' '$PreviousSha' '$Confirmation' /test/fake-docker"
    $output = & docker run --rm --network none --entrypoint bash `
        --mount "type=bind,source=$repoRoot,target=/repo,readonly" `
        --mount "type=bind,source=$tempRoot,target=/test" `
        $containerImage -lc $command 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    Write-Utf8NoBom -Path $fakeDockerPath -Content @'
#!/usr/bin/env bash
set -euo pipefail
state=/test/images
command=${1:-}
shift || true
case "$command" in
  ps)
    [[ -f /test/running ]] && printf 'container-id\n'
    true
    ;;
  image)
    subcommand=${1:-}
    shift || true
    case "$subcommand" in
      ls)
        [[ ! -f /test/fail-list ]] || exit 92
        cat "$state"
        ;;
      inspect) printf '100\n' ;;
      rm)
        for image in "$@"; do
          grep -Fvx -- "$image" "$state" >"$state.next" || true
          mv "$state.next" "$state"
        done
        touch /test/removed
        ;;
      *) exit 90 ;;
    esac
    ;;
  system)
    [[ ${1:-} == df ]] || exit 90
    IFS=$'\t' read -r cache reclaimable </test/cache
    printf 'Images\t1GB\t0B\nBuild Cache\t%s\t%s\n' "$cache" "$reclaimable"
    ;;
  builder)
    [[ ${1:-} == prune ]] || exit 90
    touch /test/pruned
    [[ -f /test/stubborn-cache ]] || printf '3GB\t500MB\n' >/test/cache
    ;;
  *) exit 91 ;;
esac
'@

    $current = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $previous = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $old = 'cccccccccccccccccccccccccccccccccccccccc'
    $currentImages = @('backend', 'frontend', 'runner') | ForEach-Object { "xhsmedium-deps-$($current.Substring(0, 8))-$_`:latest" }
    $previousImages = @('backend', 'frontend', 'runner') | ForEach-Object { "xhsmedium-deps-$($previous.Substring(0, 8))-$_`:latest" }
    $oldImages = @('backend', 'frontend', 'runner') | ForEach-Object { "xhsmedium-deps-$($old.Substring(0, 8))-$_`:latest" }
    $protected = @('docker.m.daocloud.io/library/node:20-bookworm-slim', 'unrelated/image:latest')
    $allImages = $currentImages + $previousImages + $oldImages + $protected

    Set-FakeState -Images $allImages
    $unsafe = Invoke-Maintenance -Target 'host'
    Assert-True ($unsafe.ExitCode -eq 64) 'Unsafe maintenance targets are rejected.'
    Assert-True (-not (Test-Path (Join-Path $tempRoot 'removed'))) 'Unsafe targets perform no image deletion.'

    Set-FakeState -Images $allImages
    $audit = Invoke-Maintenance -Target 'regression' -CurrentSha $current -PreviousSha $previous
    if ($audit.ExitCode -ne 0) { Write-Host $audit.Output }
    Assert-True ($audit.ExitCode -eq 0) 'Regression AUDIT succeeds without mutation.'
    Assert-True ($audit.Output -match 'mode=AUDIT running_containers=0 candidate_images=3 removed_images=0.*cache_before_bytes=6000000000.*cache_after_bytes=6000000000.*residue=0 status=OK') 'AUDIT reports exact image and BuildKit cache evidence.'
    Assert-True (-not (Test-Path (Join-Path $tempRoot 'removed')) -and -not (Test-Path (Join-Path $tempRoot 'pruned'))) 'AUDIT performs neither image deletion nor BuildKit prune.'

    Set-FakeState -Images ($allImages + 'xhsmedium-deps-deadbeef-metrics:latest')
    $malformed = Invoke-Maintenance -Target 'regression' -Mode 'APPLY' -CurrentSha $current -PreviousSha $previous -Confirmation 'APPLY_DEDICATED_DIND_MAINTENANCE'
    Assert-True ($malformed.ExitCode -eq 72) 'Malformed dependency cache names fail closed.'
    Assert-True (-not (Test-Path (Join-Path $tempRoot 'removed')) -and -not (Test-Path (Join-Path $tempRoot 'pruned'))) 'Malformed candidates fail before any mutation.'

    Set-FakeState -Images $allImages
    $unconfirmed = Invoke-Maintenance -Target 'regression' -Mode 'APPLY' -CurrentSha $current -PreviousSha $previous
    Assert-True ($unconfirmed.ExitCode -eq 66) 'APPLY without exact confirmation is rejected.'

    Set-FakeState -Images $allImages
    New-Item -ItemType File -Path (Join-Path $tempRoot 'running') | Out-Null
    $busyAudit = Invoke-Maintenance -Target 'regression' -CurrentSha $current -PreviousSha $previous
    Assert-True ($busyAudit.ExitCode -eq 0 -and $busyAudit.Output -match 'mode=AUDIT running_containers=1') 'AUDIT remains read-only and reports a busy target DIND.'
    $busy = Invoke-Maintenance -Target 'regression' -Mode 'APPLY' -CurrentSha $current -PreviousSha $previous -Confirmation 'APPLY_DEDICATED_DIND_MAINTENANCE'
    Assert-True ($busy.ExitCode -eq 71) 'A target DIND with running containers is rejected.'
    Assert-True (-not (Test-Path (Join-Path $tempRoot 'removed'))) 'Busy-target rejection performs no deletion.'

    Set-FakeState -Images $allImages
    New-Item -ItemType File -Path (Join-Path $tempRoot 'fail-list') | Out-Null
    $enumerationFailure = Invoke-Maintenance -Target 'regression' -CurrentSha $current -PreviousSha $previous
    Assert-True ($enumerationFailure.ExitCode -eq 92) 'Image enumeration failure is propagated before mutation.'

    Set-FakeState -Images $allImages
    $apply = Invoke-Maintenance -Target 'regression' -Mode 'APPLY' -CurrentSha $current -PreviousSha $previous -Confirmation 'APPLY_DEDICATED_DIND_MAINTENANCE'
    Assert-True ($apply.ExitCode -eq 0) 'Confirmed Regression APPLY succeeds.'
    Assert-True ($apply.Output -match 'mode=APPLY running_containers=0 candidate_images=3 removed_images=3 removed_logical_bytes=300.*cache_before_bytes=6000000000.*cache_after_bytes=3000000000.*cache_reclaimed_bytes=3000000000.*reclaimed_bytes=[0-9]+.*residue=0 status=OK') 'APPLY emits bounded cleanup evidence.'
    $remaining = @(Get-Content -LiteralPath $statePath | Where-Object { $_ })
    Assert-True (-not ($remaining | Where-Object { $_ -in $oldImages })) 'Only expired SHA dependency caches are removed.'
    Assert-True (-not ($currentImages + $previousImages + $protected | Where-Object { $_ -notin $remaining })) 'Current SHA, previous SHA, and fixed inputs are preserved.'
    Assert-True ((Test-Path (Join-Path $tempRoot 'pruned'))) 'BuildKit maintenance runs only when cache exceeds the limit.'

    Set-FakeState -Images $allImages
    $release = Invoke-Maintenance -Target 'release' -Mode 'APPLY' -Confirmation 'APPLY_DEDICATED_DIND_MAINTENANCE'
    Assert-True ($release.ExitCode -eq 0) 'Non-Regression dedicated DIND APPLY succeeds without SHA parameters.'
    Assert-True ($release.Output -match 'target=release mode=APPLY running_containers=0 candidate_images=0 removed_images=0') 'Non-Regression maintenance never selects dependency images.'
    Assert-True (-not (Test-Path (Join-Path $tempRoot 'removed'))) 'Non-Regression maintenance preserves every image.'

    Set-FakeState -Images $allImages
    New-Item -ItemType File -Path (Join-Path $tempRoot 'stubborn-cache') | Out-Null
    $overLimit = Invoke-Maintenance -Target 'regression' -Mode 'APPLY' -CurrentSha $current -PreviousSha $previous -Confirmation 'APPLY_DEDICATED_DIND_MAINTENANCE'
    Assert-True ($overLimit.ExitCode -eq 76) 'APPLY fails when dedicated BuildKit cache remains above the limit.'

    Write-Host 'RRM_D31_FOCUSED_EVIDENCE: audit=READ_ONLY confirmation=ENFORCED busy=REJECTED malformed=REJECTED expired=REMOVED protected=PRESERVED cache=BOUNDED'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
