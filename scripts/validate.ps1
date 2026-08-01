[CmdletBinding()]
param(
    [switch]$Runtime
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
Push-Location $repoRoot
try {
    $gitRoot = (git rev-parse --show-toplevel).Trim() -replace '/', '\'
    Assert-True ($gitRoot -eq $repoRoot) 'Git root is isolated to jenkins-platform.'

    git check-ignore --quiet .env
    Assert-True ($LASTEXITCODE -eq 0) '.env is ignored by Git.'
    git check-ignore --quiet .secrets/jenkins_admin_password
    Assert-True ($LASTEXITCODE -eq 0) '.secrets is ignored by Git.'

    $dockerfile = Get-Content -Raw -LiteralPath 'controller\Dockerfile'
    Assert-True ($dockerfile -match 'jenkins/jenkins:2\.568\.1-jdk21@sha256:[0-9a-f]{64}') 'Jenkins numeric LTS tag and digest are pinned.'

    $plugins = Get-Content -LiteralPath 'plugins\plugins.txt' | Where-Object { $_.Trim() }
    $invalidPlugins = $plugins | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9-]*:[^:\s]+$' }
    Assert-True (-not $invalidPlugins) 'Every plugin entry has an explicit version.'

    $pluginNames = $plugins | ForEach-Object { ($_ -split ':', 2)[0] }
    Assert-True (($pluginNames | Sort-Object -Unique).Count -eq $pluginNames.Count) 'Plugin list has no duplicate IDs.'
    foreach ($required in @('configuration-as-code', 'job-dsl', 'workflow-aggregator', 'git', 'credentials-binding', 'matrix-auth', 'role-strategy', 'docker-workflow')) {
        Assert-True ($pluginNames -contains $required) "Required plugin '$required' is locked."
    }

    foreach ($configFile in @('jcasc\jenkins.yaml', 'jcasc\security.yaml', 'jcasc\authorization.yaml', 'jcasc\jobs.yaml', 'jobs\folders.groovy', 'jobs\seed.groovy')) {
        Assert-True (Test-Path -LiteralPath $configFile) "Configuration file '$configFile' exists."
    }

    $securityConfig = Get-Content -Raw -LiteralPath 'jcasc\security.yaml'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_admin_password\}\}') 'Administrator password uses Docker Secret file interpolation.'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_audit_password\}\}') 'Audit password uses Docker Secret file interpolation.'

    $jenkinsConfig = Get-Content -Raw -LiteralPath 'jcasc\jenkins.yaml'
    Assert-True ($jenkinsConfig -match 'numExecutors:\s*0') 'Controller executor count is configured as zero.'
    Assert-True ($jenkinsConfig -match 'slaveAgentPort:\s*-1') 'Inbound agent TCP port is disabled.'

    $libraryConfig = Get-Content -Raw -LiteralPath 'jcasc\jobs.yaml'
    Assert-True ($libraryConfig -match 'https://github.com/Swimming1997/YL_Jenkins.git|\$\{JENKINS_LIBRARY_URL\}') 'SCM Shared Library URL is configured.'
    Assert-True ($libraryConfig -match 'libraryPath:\s*"shared-library"') 'SCM Shared Library path is configured.'

    docker compose config --quiet
    Assert-True ($LASTEXITCODE -eq 0) 'Docker Compose configuration is valid.'

    if ($Runtime) {
        $containerId = (docker compose ps --quiet controller).Trim()
        Assert-True ([bool]$containerId) 'Controller container exists.'

        $health = (docker inspect --format '{{.State.Health.Status}}' $containerId).Trim()
        Assert-True ($health -eq 'healthy') 'Controller container is healthy.'

        $jenkinsVersion = (docker exec $containerId printenv JENKINS_VERSION).Trim()
        Assert-True ($jenkinsVersion -eq '2.568.1') 'Running Jenkins version is 2.568.1.'

        $mount = docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}' $containerId
        Assert-True ([bool]$mount.Trim()) 'Jenkins home uses a named Docker volume.'

        $published = (docker port $containerId 8080/tcp).Trim()
        Assert-True ($published -match '^127\.0\.0\.1:') 'Jenkins HTTP port is bound only to localhost.'

        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://$published/login" -TimeoutSec 15
        Assert-True ($response.StatusCode -eq 200) 'Jenkins login page responds over HTTP.'

        $containerEnvironment = (docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $containerId) -join "`n"
        Assert-True ($containerEnvironment -notmatch '(?im)(PASSWORD|TOKEN|SECRET)=') 'Container environment does not contain password, token, or secret values.'

        $setupPasswordExists = docker exec $containerId test -f /var/jenkins_home/secrets/initialAdminPassword
        Assert-True ($LASTEXITCODE -ne 0) 'Setup Wizard initial password is absent.'

        $adminPassword = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
        $pair = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:$adminPassword"))
        $headers = @{ Authorization = "Basic $pair" }
        $computer = Invoke-RestMethod -Uri "http://$published/computer/(built-in)/api/json" -Headers $headers -TimeoutSec 15
        Assert-True ([int]$computer.numExecutors -eq 0) 'Running Controller executor count is zero.'
    }

    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
