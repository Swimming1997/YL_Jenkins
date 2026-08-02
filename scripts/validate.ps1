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
    git check-ignore --quiet .secrets/build_agent_ssh_key
    Assert-True ($LASTEXITCODE -eq 0) 'Agent private keys are ignored by Git.'
    git check-ignore --quiet .secrets/xhsmedium_scm_token
    Assert-True ($LASTEXITCODE -eq 0) 'XHSMedium SCM token is ignored by Git.'
    Assert-True ((Test-Path -LiteralPath '.secrets\xhsmedium_scm_token') -and (Get-Item -LiteralPath '.secrets\xhsmedium_scm_token').Length -gt 1) 'XHSMedium SCM token Secret exists and is non-empty.'

    $dockerfile = Get-Content -Raw -LiteralPath 'controller\Dockerfile'
    Assert-True ($dockerfile -match 'jenkins/jenkins:2\.568\.1-jdk21@sha256:[0-9a-f]{64}') 'Jenkins numeric LTS tag and digest are pinned.'
    $buildAgentDockerfile = Get-Content -Raw -LiteralPath 'agents\build\Dockerfile'
    Assert-True ($buildAgentDockerfile -match '(?s)apt-get install.*?g\+\+\s+make\s+python3') 'Build Agent image installs the native Node.js build toolchain.'
    $regressionAgentDockerfile = Get-Content -Raw -LiteralPath 'agents\regression\Dockerfile'
    Assert-True ($regressionAgentDockerfile -match '(?s)apt-get install.*?g\+\+.*?make.*?python3' -and $regressionAgentDockerfile -match '(?s)python3 --version.*?make --version.*?g\+\+ --version') 'Regression Agent image installs and smokes the native Node.js build toolchain.'

    $plugins = Get-Content -LiteralPath 'plugins\plugins.txt' | Where-Object { $_.Trim() }
    $invalidPlugins = $plugins | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9-]*:[^:\s]+$' }
    Assert-True (-not $invalidPlugins) 'Every plugin entry has an explicit version.'

    $pluginNames = $plugins | ForEach-Object { ($_ -split ':', 2)[0] }
    Assert-True (($pluginNames | Sort-Object -Unique).Count -eq $pluginNames.Count) 'Plugin list has no duplicate IDs.'
    foreach ($required in @('configuration-as-code', 'job-dsl', 'workflow-aggregator', 'git', 'credentials-binding', 'matrix-auth', 'role-strategy', 'docker-workflow', 'ssh-slaves', 'trilead-api')) {
        Assert-True ($pluginNames -contains $required) "Required plugin '$required' is locked."
    }

    foreach ($configFile in @('jcasc\jenkins.yaml', 'jcasc\security.yaml', 'jcasc\authorization.yaml', 'jcasc\jobs.yaml', 'jcasc\agents.yaml', 'jcasc\credentials.yaml', 'jobs\folders.groovy', 'jobs\seed.groovy', 'jobs\projects\xhsmedium-ci.groovy', 'jobs\projects\xhsmedium-regression.groovy', 'shared-library\vars\validateGitRef.groovy', 'shared-library\vars\nodeModuleCi.groovy', 'shared-library\vars\recordBuildMetadata.groovy', 'shared-library\vars\scmChangeDecision.groovy', 'shared-library\resources\xhsmedium\docker-offline-wrapper.sh', 'shared-library\resources\xhsmedium\mysql-entrypoint-compat.yaml', 'shared-library\resources\xhsmedium\mysql-init-wrapper.sh', 'scripts\preload-xhsmedium-regression.ps1', 'scripts\test-xhsmedium-regression.ps1', 'scripts\test-xhsmedium-watcher.ps1', 'agents\build\Dockerfile', 'agents\regression\Dockerfile')) {
        Assert-True (Test-Path -LiteralPath $configFile) "Configuration file '$configFile' exists."
    }

    $securityConfig = Get-Content -Raw -LiteralPath 'jcasc\security.yaml'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_admin_password\}\}') 'Administrator password uses Docker Secret file interpolation.'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_audit_password\}\}') 'Audit password uses Docker Secret file interpolation.'

    $credentialsConfig = Get-Content -Raw -LiteralPath 'jcasc\credentials.yaml'
    Assert-True ($credentialsConfig -match 'id:\s*"xhsmedium-scm-readonly"') 'XHSMedium read-only SCM credential has a fixed Jenkins ID.'
    Assert-True ($credentialsConfig -match '\$\{trim:\$\{readFile:/run/secrets/xhsmedium_scm_token\}\}') 'XHSMedium SCM credential uses Docker Secret file interpolation.'

    $jenkinsConfig = Get-Content -Raw -LiteralPath 'jcasc\jenkins.yaml'
    Assert-True ($jenkinsConfig -match 'numExecutors:\s*0') 'Controller executor count is configured as zero.'
    Assert-True ($jenkinsConfig -match 'slaveAgentPort:\s*-1') 'Inbound agent TCP port is disabled.'

    $libraryConfig = Get-Content -Raw -LiteralPath 'jcasc\jobs.yaml'
    Assert-True ($libraryConfig -match 'https://github.com/Swimming1997/YL_Jenkins.git|\$\{JENKINS_LIBRARY_URL\}') 'SCM Shared Library URL is configured.'
    Assert-True ($libraryConfig -match 'libraryPath:\s*"shared-library"') 'SCM Shared Library path is configured.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-ci\.groovy') 'XHSMedium read-only CI Job DSL is loaded by JCasC.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-regression\.groovy') 'XHSMedium scheduled regression Job DSL is loaded by JCasC.'

    $xhsmediumCi = Get-Content -Raw -LiteralPath 'jobs\projects\xhsmedium-ci.groovy'
    Assert-True (([regex]::Matches($xhsmediumCi, "script\('''")).Count -eq 2 -and ([regex]::Matches($xhsmediumCi, "'''\.stripIndent\(\)")).Count -eq 2) 'Each XHSMedium Job DSL Pipeline script has an independent balanced boundary.'
    Assert-True ($xhsmediumCi -match "pipelineJob\('XHSMedium/CI/read-only'\)") 'XHSMedium read-only CI job has the expected fixed path.'
    Assert-True ($xhsmediumCi -match "XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'") 'XHSMedium repository URL is fixed in the job.'
    Assert-True ($xhsmediumCi -match "agent \{ label 'xhsmedium-build' \}") 'XHSMedium CI is restricted to the Build Agent.'
    Assert-True ($xhsmediumCi -match 'disableConcurrentBuilds\(abortPrevious: true\)') 'XHSMedium CI replaces an overlapping build.'
    Assert-True ($xhsmediumCi -match "credentialsId: 'xhsmedium-scm-readonly'") 'XHSMedium CI uses only the fixed read-only SCM credential.'
    Assert-True (([regex]::Matches($xhsmediumCi, "NODE_OPTIONS = '--max-old-space-size=768'")).Count -eq 1 -and ([regex]::Matches($xhsmediumCi, "NODE_OPTIONS = '--max-old-space-size=1536'")).Count -eq 1 -and ([regex]::Matches($xhsmediumCi, "NODE_OPTIONS = '--max-old-space-size=512'")).Count -eq 2) 'XHSMedium CI applies bounded per-module Node heap limits.'
    Assert-True ($xhsmediumCi -match 'GIT_ASKPASS_REQUIRE=force') 'XHSMedium branch resolution uses non-interactive Git credential handling.'
    Assert-True ($xhsmediumCi -match 'rm -f .*SCM_ASKPASS_PATH') 'XHSMedium CI explicitly cleans its temporary SCM AskPass wrapper.'
    Assert-True ($xhsmediumCi -match 'npm_config_cache = "/tmp/\$\{BUILD_TAG\}-npm-cache"' -and $xhsmediumCi -match 'rm -rf -- "\$npm_config_cache"') 'XHSMedium CI isolates and cleans its npm cache outside Workspace tmpfs.'
    Assert-True ($xhsmediumCi -match 'npm ci --prefix \.\./automation --no-audit --no-fund') 'Frontend type checking installs its imported automation fixture dependencies from the locked module.'
    Assert-True ($xhsmediumCi -notmatch 'https://[^\s"'']*\$SCM_(?:USER|TOKEN)') 'XHSMedium CI never embeds SCM credentials in a URL.'
    Assert-True ($xhsmediumCi -match 'git diff --exit-code -- \.') 'XHSMedium CI checks that tracked source files remain unchanged.'
    Assert-True ($xhsmediumCi -notmatch '(?i)docker\s+(?:build|compose|run)|ftp://|feishu|aliyun|ossutil') 'XHSMedium CI contains no Docker, FTP, Feishu, or OSS operation.'
    Assert-True ($xhsmediumCi -match "pipelineJob\('XHSMedium/CI/watch-dev'\)") 'XHSMedium dev watcher has the expected fixed path.'
    Assert-True ($xhsmediumCi -match "triggers \{ cron\('H \* \* \* \*'\) \}") 'XHSMedium dev watcher checks once per hour.'
    Assert-True ($xhsmediumCi -match "WATCH_BRANCH = 'dev'" -and $xhsmediumCi -match "INITIAL_BASELINE_SHA = '1ac17fb695a8099fe01e0cd9311b6f272c23a491'") 'XHSMedium watcher uses the confirmed dev branch and P3A baseline.'
    Assert-True ($xhsmediumCi -match "job: '/XHSMedium/CI/read-only'" -and $xhsmediumCi -match 'wait: false') 'XHSMedium watcher asynchronously triggers the fixed read-only CI job.'
    Assert-True ($xhsmediumCi -match 'SCM_NO_CHANGE' -and $xhsmediumCi -match 'SCM_CHANGE_TRIGGERED') 'XHSMedium watcher reports unchanged and changed decisions explicitly.'

    $xhsmediumRegression = Get-Content -Raw -LiteralPath 'jobs\projects\xhsmedium-regression.groovy'
    Assert-True (([regex]::Matches($xhsmediumRegression, "script\('''")).Count -eq 1 -and ([regex]::Matches($xhsmediumRegression, "'''\.stripIndent\(\)")).Count -eq 1 -and ([regex]::Matches($xhsmediumRegression, "'''")).Count -eq 2) 'XHSMedium regression Pipeline script has one isolated balanced boundary.'
    Assert-True (-not (($xhsmediumRegression -split "`r?`n") | Where-Object { $_ -match "(?<!\\)\\n'\s*\+?\s*$" })) 'Nested Pipeline shell strings preserve escaped newlines through Job DSL generation.'
    Assert-True ($xhsmediumRegression.Contains('test \"\\$(docker') -and $xhsmediumRegression.Contains('\"\\$image\")')) 'Nested Pipeline GString preserves escaped Shell substitutions through Job DSL generation.'
    Assert-True ($xhsmediumRegression -match "pipelineJob\('XHSMedium/Regression/scheduled'\)") 'XHSMedium scheduled regression job has the expected fixed path.'
    Assert-True ($xhsmediumRegression -match "agent \{ label 'xhsmedium-regression' \}") 'XHSMedium regression is restricted to the Regression Agent.'
    Assert-True ($xhsmediumRegression -match "triggers \{ cron\('0 \*/2 \* \* \*'\) \}") 'XHSMedium regression runs at each even-hour slot.'
    Assert-True ($xhsmediumRegression -match 'disableConcurrentBuilds\(abortPrevious: false\)') 'XHSMedium regression does not overlap scheduled runs.'
    Assert-True ($xhsmediumRegression -match 'libraryResource\(''xhsmedium/docker-offline-wrapper\.sh''\)') 'XHSMedium regression installs the reviewed offline Docker wrapper.'
    Assert-True ($xhsmediumRegression -match 'down --volumes --remove-orphans') 'XHSMedium regression performs exact Compose cleanup.'
    Assert-True ($xhsmediumRegression -notmatch '(?i)ftp://|feishu|aliyun|ossutil|/var/run/docker\.sock') 'XHSMedium regression contains no external delivery or host Docker Socket operation.'

    $offlineWrapper = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\docker-offline-wrapper.sh'
    Assert-True ($offlineWrapper -match 'xhsmedium\.preload\.sha' -and $offlineWrapper -match 'xhsmedium\.preload\.role') 'Offline Docker wrapper verifies full SHA and role labels.'
    Assert-True ($offlineWrapper -match 'OFFLINE_DEPENDENCY_CACHE' -and $offlineWrapper -match 'NPM_OFFLINE=true') 'Offline Docker wrapper reports and enforces cache use.'
    Assert-True ($offlineWrapper -match 'XHSMEDIUM_COMPOSE_OVERRIDE_PATH' -and $offlineWrapper -match 'prefix=.*-f.*compose_override') 'Offline Docker wrapper applies the external MySQL compatibility override.'
    Assert-True ($offlineWrapper -notmatch '/var/run/docker\.sock') 'Offline Docker wrapper never references the host Docker Socket.'
    $mysqlCompatibility = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\mysql-entrypoint-compat.yaml'
    Assert-True ($mysqlCompatibility -match 'XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH' -and $mysqlCompatibility -match 'XHSMEDIUM_ORIGINAL_MYSQL_INIT_PATH') 'MySQL compatibility override mounts the wrapper and original fixed-SHA script separately.'
    $mysqlInitWrapper = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\mysql-init-wrapper.sh'
    Assert-True ($mysqlInitWrapper.Trim() -eq "#!/bin/sh`nbash /automation/original-initialize-database.sh") 'MySQL compatibility wrapper only executes the original script in a child shell.'

    $preloadScript = Get-Content -Raw -LiteralPath 'scripts\preload-xhsmedium-regression.ps1'
    Assert-True ($preloadScript -match "'--target', 'dependencies'" -and $preloadScript -match 'xhsmedium\.preload\.sha') 'Regression preloader builds labeled dependency stages.'
    Assert-True ($preloadScript -match "'save'" -and $preloadScript -match "'load'") 'Regression preloader transfers images into isolated DIND.'
    Assert-True (($preloadScript -match 'sha256:8dbcf531a03aade657e181b9cf2f1d1803ce621a1d55610cb44cb531ab7d7db6') -and ($preloadScript -match 'sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0') -and ($preloadScript -match 'sha256:b0ab6f3cb99aa7803adbc14d9027ec1785fc6e433b97e134e0f8fe61683b6b53') -and ($preloadScript -match 'sha256:9bd26ad900bb5e0f4dee75839e957a89ae89c2b7ab1e76050e559790e946b948')) 'Regression preloader verifies pinned input image identities.'

    $composeText = Get-Content -Raw -LiteralPath 'compose.yaml'
    $controllerCompose = [regex]::Match($composeText, '(?ms)^  controller:.*?(?=^  build-agent:)').Value
    $buildAgentCompose = [regex]::Match($composeText, '(?ms)^  build-agent:.*?(?=^  regression-agent:)').Value
    Assert-True ($composeText -notmatch '/var/run/docker\.sock') 'Host Docker Socket is not referenced.'
    Assert-True (([regex]::Matches($composeText, '(?m)^\s+privileged:\s+true\s*$')).Count -eq 1) 'Exactly one service, isolated DIND, is privileged.'
    Assert-True ($composeText -match '(?s)build-agent:.*?networks:\s*\r?\n\s*- control') 'Build Agent is attached to the control network.'
    Assert-True ($composeText -match '(?s)regression-agent:.*?regression_docker') 'Regression Agent is attached to the isolated Docker network.'
    Assert-True (([regex]::Matches($composeText, 'regression_workspace:/home/jenkins/agent')).Count -eq 2) 'Regression Agent and DIND share the exact remote Workspace path.'
    Assert-True ($controllerCompose -match '(?s)secrets:.*?- xhsmedium_scm_token') 'Controller receives the XHSMedium SCM Docker Secret.'
    Assert-True ($buildAgentCompose -notmatch 'xhsmedium_scm_token') 'Build Agent does not mount the XHSMedium SCM Docker Secret.'
    Assert-True ($buildAgentCompose -match '/home/jenkins/agent:size=2g,uid=1000,gid=1000,mode=0700,exec') 'Build Agent Workspace tmpfs explicitly permits CI tool execution.'
    Assert-True ($buildAgentCompose -match 'mem_limit:\s*2g') 'Build Agent has the confirmed 2 GiB memory limit.'
    $seedJobs = Get-Content -Raw -LiteralPath 'jobs\seed.groovy'
    Assert-True ($seedJobs -match 'python3 --version && make --version && g\+\+ --version') 'Build Agent smoke verifies the native Node.js build toolchain.'

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

        $serviceIds = @{}
        foreach ($service in @('build-agent', 'regression-agent', 'regression-docker')) {
            $serviceId = (docker compose ps --quiet $service).Trim()
            Assert-True ([bool]$serviceId) "Service '$service' exists."
            $serviceHealth = (docker inspect --format '{{.State.Health.Status}}' $serviceId).Trim()
            Assert-True ($serviceHealth -eq 'healthy') "Service '$service' is healthy."
            $serviceIds[$service] = $serviceId
        }

        $buildInspect = (docker inspect $serviceIds['build-agent'] | ConvertFrom-Json)[0]
        $regressionInspect = (docker inspect $serviceIds['regression-agent'] | ConvertFrom-Json)[0]
        $dindInspect = (docker inspect $serviceIds['regression-docker'] | ConvertFrom-Json)[0]
        Assert-True (-not @($buildInspect.NetworkSettings.Ports.PSObject.Properties | Where-Object Value).Count) 'Build Agent publishes no host port.'
        Assert-True ([int64]$buildInspect.HostConfig.Memory -eq 2GB) 'Running Build Agent memory limit is 2 GiB.'
        $buildWorkspaceOptions = (docker exec $serviceIds['build-agent'] findmnt -no OPTIONS /home/jenkins/agent).Trim() -split ','
        Assert-True ($buildWorkspaceOptions -notcontains 'noexec') 'Running Build Agent Workspace permits CI tool execution.'
        Assert-True ($buildWorkspaceOptions -contains 'nosuid' -and $buildWorkspaceOptions -contains 'nodev') 'Running Build Agent Workspace retains nosuid and nodev isolation.'
        Assert-True (-not @($regressionInspect.NetworkSettings.Ports.PSObject.Properties | Where-Object Value).Count) 'Regression Agent publishes no host port.'
        Assert-True ($dindInspect.HostConfig.Privileged) 'Isolated DIND is privileged.'
        $regressionWorkspaceMount = @($regressionInspect.Mounts | Where-Object Destination -eq '/home/jenkins/agent')
        $dindWorkspaceMount = @($dindInspect.Mounts | Where-Object Destination -eq '/home/jenkins/agent')
        Assert-True ($regressionWorkspaceMount.Count -eq 1 -and $dindWorkspaceMount.Count -eq 1 -and $regressionWorkspaceMount[0].Type -eq 'volume' -and $regressionWorkspaceMount[0].Name -eq $dindWorkspaceMount[0].Name) 'Running Regression Agent and DIND use the same named Workspace volume.'
        $regressionWorkspaceIdentity = (docker exec $serviceIds['regression-agent'] stat -c '%u:%g:%a' /home/jenkins/agent).Trim()
        Assert-True ($regressionWorkspaceIdentity -eq '1002:1002:700') 'Running Regression Workspace is private to the Jenkins Agent user.'
        $socketMounts = @($buildInspect, $regressionInspect, $dindInspect | ForEach-Object { $_.Mounts } | Where-Object { $_.Source -match 'docker\.sock' })
        Assert-True ($socketMounts.Count -eq 0) 'Agent services do not mount the host Docker Socket.'
    }

    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
