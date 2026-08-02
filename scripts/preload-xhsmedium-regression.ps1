[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'xhsmedium-reference'),
    [string]$Sha = '',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$sourceRoot = (Resolve-Path $SourcePath).Path
$sourceGitRoot = (& git -C $sourceRoot rev-parse --show-toplevel).Trim() -replace '/', '\'
if ($LASTEXITCODE -ne 0 -or $sourceGitRoot -ne $sourceRoot) { throw 'SourcePath must be the XHSMedium Git root.' }
if ((& git -C $sourceRoot status --short)) { throw 'XHSMedium source worktree must be clean before preloading.' }
if (-not $Sha) { $Sha = (& git -C $sourceRoot rev-parse HEAD).Trim() }
if ($Sha -notmatch '^[0-9a-f]{40}$') { throw 'Sha must be a full 40-character commit SHA.' }
Invoke-Native git @('-C', $sourceRoot, 'cat-file', '-e', "$Sha`^{commit}")

$shortSha = $Sha.Substring(0, 8)
$cachePrefix = "xhsmedium-deps-$shortSha"
$roles = @(
    @{ Name = 'backend'; Dockerfile = 'deploy/docker/backend.Dockerfile' },
    @{ Name = 'frontend'; Dockerfile = 'deploy/docker/frontend.Dockerfile' },
    @{ Name = 'runner'; Dockerfile = 'automation/docker/runner.Dockerfile' }
)

Push-Location $repoRoot
try {
    $dindId = (docker compose ps --quiet regression-docker).Trim()
    if (-not $dindId) { throw 'regression-docker is not running.' }

    if (-not $VerifyOnly) {
        $pinnedInputs = @(
            @{ Reference = 'docker.m.daocloud.io/library/mysql:8.4'; Id = 'sha256:8dbcf531a03aade657e181b9cf2f1d1803ce621a1d55610cb44cb531ab7d7db6' },
            @{ Reference = 'docker.m.daocloud.io/library/node:20-bookworm-slim'; Id = 'sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0' },
            @{ Reference = 'mcr.microsoft.com/playwright:v1.59.1-noble'; Id = 'sha256:b0ab6f3cb99aa7803adbc14d9027ec1785fc6e433b97e134e0f8fe61683b6b53' },
            @{ Reference = 'mcr.microsoft.com/playwright:v1.60.0-noble'; Id = 'sha256:9bd26ad900bb5e0f4dee75839e957a89ae89c2b7ab1e76050e559790e946b948' }
        )
        foreach ($inputImage in $pinnedInputs) {
            $actualId = (docker image inspect --format '{{.Id}}' $inputImage.Reference).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualId -ne $inputImage.Id) {
                throw "Pinned preload input is missing or has changed: $($inputImage.Reference)"
            }
        }

        $snapshot = Join-Path $repoRoot ".secrets\p4-preload-source-$shortSha"
        $sourceArchive = Join-Path $repoRoot ".secrets\p4-preload-source-$shortSha.tar"
        $imageArchive = Join-Path $repoRoot ".secrets\p4-preload-images-$shortSha.tar"
        if ((Test-Path -LiteralPath $snapshot) -or (Test-Path -LiteralPath $sourceArchive) -or (Test-Path -LiteralPath $imageArchive)) {
            throw 'A preload temporary path already exists; refusing to overwrite it.'
        }
        try {
            [IO.Directory]::CreateDirectory($snapshot) | Out-Null
            Invoke-Native git @('-C', $sourceRoot, 'archive', '--format=tar', "--output=$sourceArchive", $Sha)
            Invoke-Native tar @('-xf', $sourceArchive, '-C', $snapshot)

            foreach ($role in $roles) {
                $image = "$cachePrefix-$($role.Name):latest"
                Invoke-Native docker @(
                    'build', '--target', 'dependencies',
                    '--label', "xhsmedium.preload.sha=$Sha",
                    '--label', "xhsmedium.preload.role=$($role.Name)",
                    '--tag', $image,
                    '--file', (Join-Path $snapshot $role.Dockerfile),
                    $snapshot
                )
            }

            $transferImages = @(
                'docker.m.daocloud.io/library/mysql:8.4',
                'mcr.microsoft.com/playwright:v1.59.1-noble'
            ) + @($roles | ForEach-Object { "$cachePrefix-$($_.Name):latest" })
            Invoke-Native docker (@('save', '--output', $imageArchive) + $transferImages)
            Invoke-Native docker @('cp', $imageArchive, "${dindId}:/certs/client/xhsmedium-p4-preload.tar")
            Invoke-Native docker @('exec', $dindId, 'docker', 'load', '--input', '/certs/client/xhsmedium-p4-preload.tar')
        }
        finally {
            if ($dindId) { & docker exec $dindId rm -f /certs/client/xhsmedium-p4-preload.tar | Out-Null }
            if ($snapshot -and [IO.Directory]::Exists($snapshot)) { [IO.Directory]::Delete($snapshot, $true) }
            if ($sourceArchive -and [IO.File]::Exists($sourceArchive)) { [IO.File]::Delete($sourceArchive) }
            if ($imageArchive -and [IO.File]::Exists($imageArchive)) { [IO.File]::Delete($imageArchive) }
        }
    }

    foreach ($role in $roles) {
        $image = "$cachePrefix-$($role.Name):latest"
        $actualSha = (docker exec $dindId docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.sha"}}' $image).Trim()
        $actualRole = (docker exec $dindId docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.role"}}' $image).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualSha -ne $Sha -or $actualRole -ne $role.Name) {
            throw "DIND cache identity verification failed for $image."
        }
        Write-Host "PASS: $image is loaded for $Sha."
    }
    foreach ($image in @('docker.m.daocloud.io/library/mysql:8.4', 'mcr.microsoft.com/playwright:v1.59.1-noble')) {
        docker exec $dindId docker image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) { throw "Required runtime image is missing from DIND: $image" }
        Write-Host "PASS: Runtime image is loaded: $image"
    }
    Write-Host "P4_PRELOAD_EVIDENCE: sha=$Sha prefix=$cachePrefix"
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
