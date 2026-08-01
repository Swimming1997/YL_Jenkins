[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$secretDirectory = Join-Path $repoRoot '.secrets'
[System.IO.Directory]::CreateDirectory($secretDirectory) | Out-Null

function New-RandomSecret {
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

foreach ($name in @('jenkins_admin_password', 'jenkins_audit_password')) {
    $path = Join-Path $secretDirectory $name
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        Write-Host "Secret already exists: $name"
        continue
    }

    $secret = New-RandomSecret
    [System.IO.File]::WriteAllText($path, $secret, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Generated secret: $name"
}

