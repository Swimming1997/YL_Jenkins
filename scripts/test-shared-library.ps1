[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$libraryRoot = Join-Path $repoRoot 'shared-library'
$arguments = @(
    'run', '--rm',
    '--user', 'gradle',
    '--volume', "${libraryRoot}:/workspace:ro",
    '--volume', 'jenkins_platform_gradle_cache:/home/gradle/.gradle',
    '--tmpfs', '/workspace/build:rw,size=512m,uid=1000,gid=1000',
    '--workdir', '/workspace',
    'gradle@sha256:21bd311ed01360c189b8870c6b6e988199ff10f72d445d02fb39d3cff9da91d7',
    'gradle', 'test', '--no-daemon', '--project-cache-dir', '/tmp/jenkins-platform-gradle'
)
& docker @arguments
if ($LASTEXITCODE -ne 0) { throw 'Shared Library tests failed.' }
Write-Host 'PASS: Shared Library containerized tests completed.'
