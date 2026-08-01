[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$secretDirectory = Join-Path $repoRoot '.secrets'
[System.IO.Directory]::CreateDirectory($secretDirectory) | Out-Null

foreach ($name in @('build_agent_ssh_key', 'regression_agent_ssh_key')) {
    $privatePath = Join-Path $secretDirectory $name
    $publicPath = "$privatePath.pub"
    if ((Test-Path -LiteralPath $privatePath) -and (Test-Path -LiteralPath $publicPath) -and -not $Force) {
        Write-Host "Agent key already exists: $name"
        continue
    }

    if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force }
    if (Test-Path -LiteralPath $publicPath) { Remove-Item -LiteralPath $publicPath -Force }

    & ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C "jenkins-platform-$name" -f $privatePath
    if ($LASTEXITCODE -ne 0) { throw "Could not generate agent key: $name" }
    Write-Host "Generated agent key: $name"
}
