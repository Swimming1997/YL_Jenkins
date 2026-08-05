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
$helper = '/repo/shared-library/resources/xhsmedium/docker-run-image-cleanup.sh'
$containerImage = 'jenkins-platform/regression-agent:node20-playwright1.59.1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "rrm-d2-$([guid]::NewGuid().ToString('N'))"
$fakeDockerPath = Join-Path $tempRoot 'fake-docker'
$statePath = Join-Path $tempRoot 'images'

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Set-FakeImages {
    param([string[]]$Images)
    Write-Utf8NoBom -Path $statePath -Content (($Images -join "`n") + "`n")
    Remove-Item -LiteralPath (Join-Path $tempRoot 'removed') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $tempRoot 'fail-list') -Force -ErrorAction SilentlyContinue
}

function Invoke-Cleanup {
    param([string]$Project)
    $command = "chmod +x /test/fake-docker && bash $helper '$Project' /test/fake-docker"
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
removed=/test/removed
command=${1:-}
shift || true
case "$command" in
  run)
    if [[ -f $removed ]]; then printf '2000000\n'; else printf '1000000\n'; fi
    ;;
  image)
    subcommand=${1:-}
    shift || true
    case "$subcommand" in
      ls)
        if [[ -f /test/fail-list ]]; then exit 92; fi
        cat "$state"
        ;;
      inspect) printf '100\n' ;;
      rm)
        for image in "$@"; do
          grep -Fvx -- "$image" "$state" >"$state.next" || true
          mv "$state.next" "$state"
        done
        touch "$removed"
        ;;
      *) printf 'Unexpected fake image command: %s\n' "$subcommand" >&2; exit 90 ;;
    esac
    ;;
  *) printf 'Unexpected fake docker command: %s\n' "$command" >&2; exit 91 ;;
esac
'@

    $project = 'xhsmedium-test-scheduled-20260806-060000-deadbeef'
    $expected = @("${project}-backend:latest", "${project}-frontend:latest", "${project}-runner:latest")
    $preserved = @('xhsmedium-deps-deadbeef-backend:latest', 'unrelated-project:latest')

    Set-FakeImages -Images ($expected + $preserved)
    $unsafe = Invoke-Cleanup -Project 'unsafe-project'
    Assert-True ($unsafe.ExitCode -eq 64) 'Unsafe project names are rejected before deletion.'
    Assert-True ((Get-Content -LiteralPath $statePath).Count -eq 5) 'Unsafe cleanup preserves every image.'

    Set-FakeImages -Images ($expected + $preserved)
    New-Item -ItemType File -Path (Join-Path $tempRoot 'fail-list') | Out-Null
    $listFailure = Invoke-Cleanup -Project $project
    Assert-True ($listFailure.ExitCode -eq 92) 'Image enumeration failure is propagated.'
    Assert-True ((Get-Content -LiteralPath $statePath).Count -eq 5) 'Image enumeration failure performs no deletion.'

    Set-FakeImages -Images (@($expected[0], "${project}-metrics:latest") + $preserved)
    $unexpected = Invoke-Cleanup -Project $project
    Assert-True ($unexpected.ExitCode -eq 66) 'Unexpected images under the run prefix fail closed.'
    Assert-True ((Get-Content -LiteralPath $statePath) -contains "${project}-metrics:latest") 'Fail-closed cleanup preserves the unexpected image for inspection.'

    Set-FakeImages -Images ($expected + $preserved)
    $success = Invoke-Cleanup -Project $project
    Assert-True ($success.ExitCode -eq 0) 'Exact run images are removed successfully.'
    Assert-True ($success.Output -match 'RESIDUE_CLEANUP_EVIDENCE.*removed_images=3.*removed_logical_bytes=300.*reclaimed_bytes=1000000.*residue=0.*status=OK') 'Cleanup emits structured evidence with counts, bytes, and zero residue.'
    $remaining = @(Get-Content -LiteralPath $statePath | Where-Object { $_ })
    Assert-True (($remaining.Count -eq 2) -and ($remaining -contains $preserved[0]) -and ($remaining -contains $preserved[1])) 'Dependency caches and unrelated images are preserved.'

    Set-FakeImages -Images $preserved
    $empty = Invoke-Cleanup -Project $project
    Assert-True ($empty.ExitCode -eq 0) 'An early failure with no run images is a valid empty cleanup.'
    Assert-True ($empty.Output -match 'removed_images=0.*reclaimed_bytes=0.*residue=0.*status=OK') 'Empty cleanup still emits zero-residue evidence.'

    Write-Host 'RRM_D2_FOCUSED_EVIDENCE: unsafe=REJECTED enumeration_failure=REJECTED unexpected=REJECTED exact=REMOVED empty=OK preserved=YES'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
