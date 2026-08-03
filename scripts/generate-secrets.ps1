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

$registryUsernamePath = Join-Path $secretDirectory 'registry_username'
if (-not (Test-Path -LiteralPath $registryUsernamePath) -or $Force) {
    [System.IO.File]::WriteAllText($registryUsernamePath, 'jenkins-release', [System.Text.UTF8Encoding]::new($false))
    Write-Host 'Generated secret: registry_username'
}

$registryPasswordPath = Join-Path $secretDirectory 'registry_password'
if (-not (Test-Path -LiteralPath $registryPasswordPath) -or $Force) {
    [System.IO.File]::WriteAllText($registryPasswordPath, (New-RandomSecret), [System.Text.UTF8Encoding]::new($false))
    Write-Host 'Generated secret: registry_password'
}

foreach ($environmentName in @('dev', 'test')) {
    foreach ($purpose in @('mysql_password', 'jwt_secret', 'draft_key')) {
        $name = "deploy_${environmentName}_${purpose}"
        $path = Join-Path $secretDirectory $name
        if ((Test-Path -LiteralPath $path) -and -not $Force) {
            Write-Host "Secret already exists: $name"
            continue
        }

        [System.IO.File]::WriteAllText($path, (New-RandomSecret), [System.Text.UTF8Encoding]::new($false))
        Write-Host "Generated secret: $name"
    }
}
