[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$helper = Join-Path $repoRoot 'shared-library\resources\xhsmedium\npm-ci-network-retry.sh'
$bashCandidates = @(
    'D:\Git\bin\bash.exe',
    'C:\Program Files\Git\bin\bash.exe',
    (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$bash = $bashCandidates | Select-Object -First 1
Assert-True ([bool]$bash) 'A Bash runtime is available for the npm retry contract test.'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ("jenkins-npm-retry-{0}" -f [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $tempRoot 'bin')) | Out-Null

try {
    $mockNpm = @'
#!/usr/bin/env sh
set -eu
test "${1:-}" = "ci"
count=0
if [ -f "$MOCK_COUNT_FILE" ]; then count=$(cat "$MOCK_COUNT_FILE"); fi
count=$((count + 1))
printf '%s' "$count" > "$MOCK_COUNT_FILE"
if [ "$MOCK_MODE" = transient ] && [ "$count" -eq 1 ]; then
    echo 'npm error code ECONNRESET' >&2
    exit 152
fi
if [ "$MOCK_MODE" = deterministic ]; then
    echo 'npm error code ERESOLVE' >&2
    exit 1
fi
echo 'mock npm ci succeeded'
'@
    $mockPath = Join-Path $tempRoot 'bin\npm'
    [IO.File]::WriteAllText($mockPath, ($mockNpm -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

    $bashTempRoot = ($tempRoot -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    $bashHelper = ($helper -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    & $bash -lc "chmod 700 '$bashTempRoot/bin/npm'; export PATH='$bashTempRoot/bin':`$PATH; export MOCK_COUNT_FILE='$bashTempRoot/count'; export MOCK_MODE=transient; '$bashHelper' --no-audit"
    Assert-True ($LASTEXITCODE -eq 0) 'A transient ECONNRESET is retried and then succeeds.'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $tempRoot 'count')) -eq '2') 'The transient case invokes npm exactly twice.'

    Remove-Item -LiteralPath (Join-Path $tempRoot 'count') -Force
    & $bash -lc "export PATH='$bashTempRoot/bin':`$PATH; export MOCK_COUNT_FILE='$bashTempRoot/count'; export MOCK_MODE=deterministic; '$bashHelper' --no-audit"
    Assert-True ($LASTEXITCODE -eq 1) 'A deterministic ERESOLVE preserves the original failure.'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $tempRoot 'count')) -eq '1') 'The deterministic case does not retry npm.'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unsafe test path: $resolvedTemp"
    }
    if (Test-Path -LiteralPath $resolvedTemp) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
