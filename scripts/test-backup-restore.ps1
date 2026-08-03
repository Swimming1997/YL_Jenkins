[CmdletBinding()]
param(
    [int]$ExpectedRegressionBuild = 19
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
$containerName = "p45-restore-$suffix"
$volumeName = "p45_restore_$suffix"
$marker = "/var/jenkins_home/.p45-recovery-$suffix"
$backupsRoot = (Resolve-Path (Join-Path $repoRoot 'backups')).Path
$outputDirectory = Join-Path $backupsRoot "p45-drill-$suffix"
$sourceController = ''
$restoredStarted = $false
$volumeCreated = $false
$startedAt = Get-Date

Push-Location $repoRoot
try {
    $sourceController = (docker compose ps --quiet controller).Trim()
    Assert-True ([bool]$sourceController) 'Source Controller exists for the recovery drill.'
    docker exec $sourceController touch $marker
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the recovery marker.' }

    & (Join-Path $PSScriptRoot 'backup.ps1') -OutputDirectory $outputDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Backup command failed.' }
    $archives = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'jenkins-home-*.tar.gz')
    Assert-True ($archives.Count -eq 1 -and $archives[0].Length -gt 0) 'Exactly one sensitive Jenkins Home archive was created in the ignored drill directory.'
    $archive = $archives[0]
    $archiveHash = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($archiveHash -match '^[0-9a-f]{64}$') 'Backup archive has a SHA-256 checksum.'

    & (Join-Path $PSScriptRoot 'restore.ps1') -BackupFile $archive.FullName -TargetVolume $volumeName
    if ($LASTEXITCODE -ne 0) { throw 'Restore command failed.' }
    $volumeCreated = $true

    $dockerArguments = @(
        'run', '--detach', '--name', $containerName,
        '--publish', '127.0.0.1::8080',
        '--security-opt', 'no-new-privileges:true',
        '--memory', '1536m', '--cpus', '2', '--pids-limit', '512',
        '--env', 'CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs',
        '--env', 'JENKINS_PUBLIC_URL=http://127.0.0.1/',
        '--env', 'JENKINS_LIBRARY_URL=https://github.com/Swimming1997/YL_Jenkins.git',
        '--env', 'JAVA_OPTS=-Djenkins.install.runSetupWizard=false -Djava.awt.headless=true -Dio.jenkins.plugins.casc.core.HudsonPrivateSecurityRealmConfigurator.exportUsers=false -Dcom.michelin.cio.hudson.plugins.rolestrategy.RoleBasedAuthorizationStrategy.useItemAndAgentRoles=true',
        '--volume', "${volumeName}:/var/jenkins_home",
        '--volume', "${repoRoot}/jcasc:/var/jenkins_home/casc_configs:ro",
        '--volume', "${repoRoot}/jobs:/var/jenkins_home/job-dsl:ro",
        '--volume', "${repoRoot}/.secrets/jenkins_admin_password:/run/secrets/jenkins_admin_password:ro",
        '--volume', "${repoRoot}/.secrets/jenkins_audit_password:/run/secrets/jenkins_audit_password:ro",
        '--volume', "${repoRoot}/.secrets/xhsmedium_scm_token:/run/secrets/xhsmedium_scm_token:ro",
        '--volume', "${repoRoot}/.secrets/build_agent_ssh_key:/run/secrets/build_agent_ssh_private_key:ro",
        '--volume', "${repoRoot}/.secrets/regression_agent_ssh_key:/run/secrets/regression_agent_ssh_private_key:ro",
        'jenkins-platform/controller:2.568.1'
    )
    $restoredId = (& docker @dockerArguments).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $restoredId) { throw 'Could not start the isolated restored Controller.' }
    $restoredStarted = $true
    $published = (docker port $containerName 8080/tcp).Trim()
    Assert-True ($published -match '^127\.0\.0\.1:(\d+)$') 'Restored Controller uses an isolated random localhost port.'
    $restoredUrl = "http://$published"

    $password = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
    $pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$password"))
    $headers = @{ Authorization = "Basic $pair" }
    $deadline = (Get-Date).AddMinutes(4)
    $ready = $false
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$restoredUrl/login" -TimeoutSec 10
            if ([int]$response.StatusCode -eq 200) { $ready = $true; break }
        }
        catch {
            Write-Verbose "Restored Controller is not ready yet: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    Assert-True $ready 'Restored Controller reached the login endpoint.'
    Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri "$restoredUrl/api/json" -Headers $headers -TimeoutSec 20).StatusCode -eq 200) 'Restored administrator credentials work.'
    Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri "$restoredUrl/job/XHSMedium/job/Regression/job/scheduled/$ExpectedRegressionBuild/api/json" -Headers $headers -TimeoutSec 20).StatusCode -eq 200) "Restored build history contains regression build $ExpectedRegressionBuild."
    docker exec $containerName test -f $marker
    Assert-True ($LASTEXITCODE -eq 0) 'Recovery marker created immediately before backup exists in the restored volume.'

    $elapsed = (Get-Date) - $startedAt
    Assert-True ($elapsed.TotalHours -lt 4) 'Local recovery drill completed within the four-hour RTO.'
    Write-Host "P45_RECOVERY_EVIDENCE: archive_sha256=$archiveHash rto_seconds=$([math]::Round($elapsed.TotalSeconds)) marker=$suffix"
}
finally {
    if ($restoredStarted) { docker rm --force $containerName *> $null }
    if ($volumeCreated) { docker volume rm $volumeName *> $null }
    if ($sourceController) { docker exec $sourceController rm -f $marker *> $null }
    if (Test-Path -LiteralPath $outputDirectory) {
        $resolvedOutput = (Resolve-Path -LiteralPath $outputDirectory).Path
        if (-not $resolvedOutput.StartsWith($backupsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected recovery output: $resolvedOutput"
        }
        [IO.Directory]::Delete($resolvedOutput, $true)
    }
    Pop-Location
}
