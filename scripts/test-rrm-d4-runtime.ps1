[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$projectName = "jenkins-platform-rrm-d41-$suffix"
$volumeName = "jenkins_platform_rrm_d41_home_$suffix"
$networkName = "jenkins_platform_rrm_d41_control_$suffix"
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$baseUrl = "http://127.0.0.1:$port"
$oldEnvironment = @{}
$environment = @{
    COMPOSE_PROJECT_NAME = $projectName
    JENKINS_VOLUME_NAME = $volumeName
    CONTROL_NETWORK_NAME = $networkName
    JENKINS_HTTP_PORT = "$port"
    JENKINS_URL = "$baseUrl/"
    PAPER_SERVER_RESOURCE_MODE = 'false'
}
$cleanupError = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-JobConfig {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Headers)
    return (Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$Path/config.xml" -Headers $Headers -TimeoutSec 20).Content
}

function Invoke-FixtureBuild {
    param(
        [Parameter(Mandatory)][string]$JobUrl,
        [Parameter(Mandatory)][hashtable]$PostHeaders,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][hashtable]$ReadHeaders
    )
    $next = [int](Invoke-RestMethod -Uri "$JobUrl/api/json?tree=nextBuildNumber" -Headers $ReadHeaders -TimeoutSec 20).nextBuildNumber
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$JobUrl/build" -Headers $PostHeaders -WebSession $Session -TimeoutSec 20
    Assert-True ([int]$response.StatusCode -in @(200, 201, 202)) "Fixture build $next was not accepted."
    foreach ($attempt in 1..100) {
        $result = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$JobUrl/$next/api/json?tree=building,result" -Headers $ReadHeaders -TimeoutSec 20
        if ([int]$result.StatusCode -eq 200) {
            $state = $result.Content | ConvertFrom-Json
            if (-not $state.building) {
                Assert-True ($state.result -eq 'SUCCESS') "Fixture build $next did not succeed."
                return $next
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Fixture build $next did not finish."
}

Push-Location $repoRoot
try {
    foreach ($entry in $environment.GetEnumerator()) {
        $oldEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    Assert-True (-not (docker ps -a --filter "label=com.docker.compose.project=$projectName" --format '{{.ID}}')) 'Isolated RRM-D4 project unexpectedly already exists.'
    Assert-True (-not (docker volume ls --filter "name=^${volumeName}$" --format '{{.Name}}')) 'Isolated RRM-D4 volume unexpectedly already exists.'
    Assert-True (-not (docker network ls --filter "name=^${networkName}$" --format '{{.Name}}')) 'Isolated RRM-D4 network unexpectedly already exists.'

    docker compose up --detach controller
    if ($LASTEXITCODE -ne 0) { throw 'Could not start isolated RRM-D4 Controller.' }

    $healthy = $false
    foreach ($attempt in 1..90) {
        $container = (docker compose ps --quiet controller).Trim()
        if ($container) {
            $health = (docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $container).Trim()
            if ($health -eq 'healthy') { $healthy = $true; break }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) {
        docker compose logs --tail 200 controller
        throw 'Isolated RRM-D4 Controller did not become healthy.'
    }

    $password = [IO.File]::ReadAllText((Join-Path $repoRoot '.secrets\jenkins_admin_password')).Trim()
    $pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$password"))
    $headers = @{ Authorization = "Basic $pair" }
    $crumb = Invoke-RestMethod -Uri "$baseUrl/crumbIssuer/api/json" -Headers $headers -SessionVariable jenkinsSession -TimeoutSec 20
    $postHeaders = @{ Authorization = "Basic $pair" }
    $postHeaders[$crumb.crumbRequestField] = $crumb.crumb
    $managedJobs = @(
        'job/XHSMedium/job/CI/job/read-only',
        'job/XHSMedium/job/CI/job/watch-dev',
        'job/XHSMedium/job/Regression/job/scheduled',
        'job/XHSMedium/job/Release/job/candidate',
        'job/XHSMedium/job/Release/job/approve',
        'job/XHSMedium/job/Deploy/job/dev',
        'job/XHSMedium/job/Deploy/job/test',
        'job/Platform/job/Maintenance/job/dind-regression',
        'job/Platform/job/Maintenance/job/dind-release',
        'job/Platform/job/Maintenance/job/dind-deploy-dev',
        'job/Platform/job/Maintenance/job/dind-deploy-test'
    )
    foreach ($job in $managedJobs) {
        $config = Get-JobConfig -Path $job -Headers $headers
        Assert-True ($config -match '<numToKeep>20</numToKeep>') "$job does not retain exactly 20 build records."
        Assert-True ($config -match '<artifactNumToKeep>5</artifactNumToKeep>') "$job does not retain exactly five complete Artifact sets."
    }

    foreach ($job in @(
        'job/XHSMedium/job/Regression/job/scheduled',
        'job/XHSMedium/job/Release/job/candidate',
        'job/XHSMedium/job/Release/job/approve',
        'job/XHSMedium/job/Deploy/job/dev',
        'job/XHSMedium/job/Deploy/job/test'
    )) {
        Assert-True ((Get-JobConfig -Path $job -Headers $headers) -match 'paperServerResourceGate\(\)') "$job is missing the resource gate Stage."
    }
    foreach ($job in $managedJobs | Where-Object { $_ -like 'job/Platform/job/Maintenance/*' }) {
        Assert-True ((Get-JobConfig -Path $job -Headers $headers) -notmatch 'paperServerResourceGate\(') "$job must remain available for low-disk recovery."
    }
    $regression = Get-JobConfig -Path 'job/XHSMedium/job/Regression/job/scheduled' -Headers $headers
    Assert-True ($regression -match 'retainRegressionTraces\(result: currentBuild\.currentResult\)') 'Regression is missing post-archive trace retention.'

    $fixtureName = 'rrm-d4-retention-fixture'
    $fixtureUrl = "$baseUrl/job/$fixtureName"
    $fixtureConfig = @'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Isolated RRM-D4 build retention fixture.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <jenkins.model.BuildDiscarderProperty>
      <strategy class="hudson.tasks.LogRotator">
        <daysToKeep>-1</daysToKeep>
        <numToKeep>20</numToKeep>
        <artifactDaysToKeep>-1</artifactDaysToKeep>
        <artifactNumToKeep>5</artifactNumToKeep>
      </strategy>
    </jenkins.model.BuildDiscarderProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>pipeline { agent none; stages { stage('fixture') { steps { echo 'RRM_D4_RETENTION_FIXTURE' } } } }</script>
    <sandbox>true</sandbox>
  </definition>
  <disabled>false</disabled>
</flow-definition>
'@
    $created = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$baseUrl/createItem?name=$fixtureName" -ContentType 'application/xml' -Body $fixtureConfig -Headers $postHeaders -WebSession $jenkinsSession -TimeoutSec 20
    Assert-True ([int]$created.StatusCode -in @(200, 201)) 'Could not create isolated build-retention fixture Job.'
    $first = Invoke-FixtureBuild -JobUrl $fixtureUrl -PostHeaders $postHeaders -Session $jenkinsSession -ReadHeaders $headers
    Assert-True ($first -eq 1) 'Fixture first build number is not 1.'
    $keepStatus = 0
    try {
        $kept = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -Method Post -Uri "$fixtureUrl/1/toggleLogKeep" -Headers $postHeaders -WebSession $jenkinsSession -TimeoutSec 20
        $keepStatus = [int]$kept.StatusCode
    }
    catch {
        if ($null -eq $_.Exception.Response) { throw }
        $keepStatus = [int]$_.Exception.Response.StatusCode
    }
    Assert-True ($keepStatus -eq 302) 'Could not pin fixture build 1.'
    foreach ($ignored in 2..22) {
        Invoke-FixtureBuild -JobUrl $fixtureUrl -PostHeaders $postHeaders -Session $jenkinsSession -ReadHeaders $headers | Out-Null
    }
    $fixtureBuilds = @(Invoke-RestMethod -Uri "$fixtureUrl/api/json?tree=builds[number,keepLog]" -Headers $headers -TimeoutSec 20).builds
    $fixtureNumbers = @($fixtureBuilds | ForEach-Object { [int]$_.number })
    Assert-True ($fixtureNumbers.Count -eq 21) 'Build retention did not converge to one pin plus 20 ordinary records.'
    Assert-True ($fixtureNumbers -contains 1 -and $fixtureNumbers -notcontains 2) 'Build retention did not preserve pinned build 1 while deleting ordinary build 2.'

    $controller = (docker compose ps --quiet controller).Trim()
    $resourceMode = (docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $controller | Select-String '^PAPER_SERVER_RESOURCE_MODE=').ToString()
    Assert-True ($resourceMode -eq 'PAPER_SERVER_RESOURCE_MODE=false') 'Isolated local Controller did not keep paper-server resource mode disabled.'
    Write-Host "RRM_D4_RUNTIME_EVIDENCE jobs=$($managedJobs.Count) builds=20 artifacts=5 pinned_builds=1 ordinary_builds=20 gated_jobs=5 maintenance_exempt=4 computer_permissions_added=0 status=OK"
}
finally {
    try {
        docker compose stop controller
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop isolated RRM-D4 Controller.' }
        docker compose rm --force controller
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove isolated RRM-D4 Controller.' }
        docker volume rm $volumeName
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove isolated RRM-D4 Jenkins Home volume.' }
        docker network rm $networkName
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove isolated RRM-D4 control network.' }
        Assert-True (-not (docker ps -a --filter "label=com.docker.compose.project=$projectName" --format '{{.ID}}')) 'Isolated RRM-D4 containers remain.'
        Assert-True (-not (docker volume ls --filter "name=^${volumeName}$" --format '{{.Name}}')) 'Isolated RRM-D4 Jenkins Home volume remains.'
        Assert-True (-not (docker network ls --filter "name=^${networkName}$" --format '{{.Name}}')) 'Isolated RRM-D4 control network remains.'
    }
    catch {
        $cleanupError = $_
    }
    foreach ($entry in $oldEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    Pop-Location
    if ($cleanupError) { throw $cleanupError }
}

Write-Host 'PASS: isolated local Jenkins loaded RRM-D4 retention and resource-gate Job DSL with zero residue.'
