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
    git check-ignore --quiet .secrets/registry_password
    Assert-True ($LASTEXITCODE -eq 0) 'Registry credentials are ignored by Git.'
    Assert-True ((Test-Path -LiteralPath '.secrets\registry_username') -and (Get-Item -LiteralPath '.secrets\registry_username').Length -gt 1 -and (Test-Path -LiteralPath '.secrets\registry_password') -and (Get-Item -LiteralPath '.secrets\registry_password').Length -gt 15) 'Local Registry credentials exist and are non-empty.'
    foreach ($environmentName in @('dev', 'test')) {
        Assert-True ((Test-Path -LiteralPath ".secrets\deploy_${environmentName}_agent_ssh_key") -and (Test-Path -LiteralPath ".secrets\deploy_${environmentName}_agent_ssh_key.pub")) "$environmentName Deploy Agent SSH credentials exist."
        foreach ($purpose in @('mysql_password', 'jwt_secret', 'draft_key')) {
            $secretPath = ".secrets\deploy_${environmentName}_${purpose}"
            Assert-True ((Test-Path -LiteralPath $secretPath) -and (Get-Item -LiteralPath $secretPath).Length -gt 15) "$environmentName deployment Secret '$purpose' exists and is non-empty."
        }
    }

    $dockerfile = Get-Content -Raw -LiteralPath 'controller\Dockerfile'
    Assert-True ($dockerfile -match 'jenkins/jenkins:2\.568\.1-jdk21@sha256:[0-9a-f]{64}') 'Jenkins numeric LTS tag and digest are pinned.'
    $buildAgentDockerfile = Get-Content -Raw -LiteralPath 'agents\build\Dockerfile'
    Assert-True ($buildAgentDockerfile -match '(?s)apt-get install.*?g\+\+\s+make\s+python3') 'Build Agent image installs the native Node.js build toolchain.'
    Assert-True ($buildAgentDockerfile -match 'ARG DEBIAN_MIRROR=\s*\r?\n' -and $buildAgentDockerfile -match 'ARG DEBIAN_SECURITY_MIRROR=\s*\r?\n') 'Build Agent Debian mirror overrides are optional by default.'
    Assert-True ($buildAgentDockerfile -match 'deb\.debian\.org/debian-security.*?DEBIAN_SECURITY_MIRROR' -and $buildAgentDockerfile -match 'deb\.debian\.org/debian.*?DEBIAN_MIRROR') 'Build Agent supports separate Debian and security mirror overrides.'
    Assert-True (([regex]::Matches($buildAgentDockerfile, 'Acquire::Retries=5')).Count -eq 2 -and ([regex]::Matches($buildAgentDockerfile, 'Acquire::(?:http|https)::Timeout=20')).Count -eq 4) 'Build Agent apt downloads use bounded retries and timeouts.'
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

    foreach ($configFile in @('jcasc\jenkins.yaml', 'jcasc\security.yaml', 'jcasc\authorization.yaml', 'jcasc\jobs.yaml', 'jcasc\agents.yaml', 'jcasc\credentials.yaml', 'jobs\folders.groovy', 'jobs\seed.groovy', 'jobs\projects\xhsmedium-ci.groovy', 'jobs\projects\xhsmedium-regression.groovy', 'jobs\projects\xhsmedium-release.groovy', 'jobs\projects\xhsmedium-deploy.groovy', 'jobs\resources\xhsmedium-deploy-compose.yaml', 'shared-library\vars\validateGitRef.groovy', 'shared-library\vars\nodeModuleCi.groovy', 'shared-library\vars\recordBuildMetadata.groovy', 'shared-library\vars\scmChangeDecision.groovy', 'shared-library\resources\xhsmedium\npm-ci-network-retry.sh', 'shared-library\resources\xhsmedium\docker-offline-wrapper.sh', 'shared-library\resources\xhsmedium\mysql-entrypoint-compat.yaml', 'shared-library\resources\xhsmedium\mysql-init-wrapper.sh', 'shared-library\resources\xhsmedium\scheduled-slot-shim.cjs', 'shared-library\resources\xhsmedium\runner-volume-entrypoint.sh', 'shared-library\resources\xhsmedium\docker-project-cleanup.sh', 'scripts\preload-xhsmedium-regression.ps1', 'scripts\preload-xhsmedium-regression.sh', 'scripts\test-xhsmedium-regression.ps1', 'scripts\test-xhsmedium-regression-paper-server.sh', 'scripts\test-xhsmedium-regression-resilience.ps1', 'scripts\test-xhsmedium-watcher.ps1', 'scripts\test-xhsmedium-release.ps1', 'scripts\test-xhsmedium-deploy.ps1', 'scripts\test-npm-ci-network-retry.ps1', 'scripts\test-backup-restore.ps1', 'scripts\test-disk-pressure.ps1', 'scripts\test-retention.ps1', 'scripts\test-hardening.ps1', 'scripts\bootstrap-paper-server.sh', 'compose.paper-server.yaml', 'docs\platform-hardening.md', 'docs\operations.md', 'docs\incident-response.md', 'docs\onboarding-project.md', 'docs\xhsmedium-release.md', 'docs\xhsmedium-deployment.md', 'docs\registry-cloud-deployment.md', 'docs\paper-server-deployment.md', 'agents\build\Dockerfile', 'agents\regression\Dockerfile', 'agents\release\Dockerfile', 'agents\release\entrypoint.sh', 'agents\deploy\Dockerfile', 'agents\deploy\entrypoint.sh')) {
        Assert-True (Test-Path -LiteralPath $configFile) "Configuration file '$configFile' exists."
    }

    $securityConfig = Get-Content -Raw -LiteralPath 'jcasc\security.yaml'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_admin_password\}\}') 'Administrator password uses Docker Secret file interpolation.'
    Assert-True ($securityConfig -match '\$\{trim:\$\{readFile:/run/secrets/jenkins_audit_password\}\}') 'Audit password uses Docker Secret file interpolation.'

    $credentialsConfig = Get-Content -Raw -LiteralPath 'jcasc\credentials.yaml'
    Assert-True ($credentialsConfig -match 'id:\s*"xhsmedium-scm-readonly"') 'XHSMedium read-only SCM credential has a fixed Jenkins ID.'
    Assert-True ($credentialsConfig -match '\$\{trim:\$\{readFile:/run/secrets/xhsmedium_scm_token\}\}') 'XHSMedium SCM credential uses Docker Secret file interpolation.'
    Assert-True ($credentialsConfig -match 'id:\s*"registry-xhsmedium-push"' -and $credentialsConfig -match '\$\{trim:\$\{readFile:/run/secrets/registry_password\}\}') 'Authenticated local Registry credential uses Docker Secret interpolation.'
    Assert-True ($credentialsConfig -match 'id:\s*"jenkins-audit-api"' -and $credentialsConfig -match 'username:\s*"audit"') 'Release gates use a fixed read-only Jenkins API credential.'
    Assert-True (([regex]::Matches($credentialsConfig, 'id:\s*"deploy-(?:dev|test)-agent-ssh"')).Count -eq 2) 'Dev and test Deploy Agents use independent SSH credentials.'
    Assert-True (([regex]::Matches($credentialsConfig, 'id:\s*"xhsmedium-(?:dev|test)-(?:mysql-password|jwt-secret|draft-key)"')).Count -eq 6) 'Dev and test deployment runtime Secrets have fixed environment-scoped credential IDs.'

    $jenkinsConfig = Get-Content -Raw -LiteralPath 'jcasc\jenkins.yaml'
    Assert-True ($jenkinsConfig -match 'numExecutors:\s*0') 'Controller executor count is configured as zero.'
    Assert-True ($jenkinsConfig -match 'slaveAgentPort:\s*-1') 'Inbound agent TCP port is disabled.'

    $libraryConfig = Get-Content -Raw -LiteralPath 'jcasc\jobs.yaml'
    Assert-True ($libraryConfig -match 'https://github.com/Swimming1997/YL_Jenkins.git|\$\{JENKINS_LIBRARY_URL\}') 'SCM Shared Library URL is configured.'
    Assert-True ($libraryConfig -match 'libraryPath:\s*"shared-library"') 'SCM Shared Library path is configured.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-ci\.groovy') 'XHSMedium read-only CI Job DSL is loaded by JCasC.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-regression\.groovy') 'XHSMedium scheduled regression Job DSL is loaded by JCasC.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-release\.groovy') 'XHSMedium Release Job DSL is loaded by JCasC.'
    Assert-True ($libraryConfig -match 'job-dsl/projects/xhsmedium-deploy\.groovy') 'XHSMedium Deploy Job DSL is loaded by JCasC.'

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
    Assert-True (([regex]::Matches($xhsmediumCi, '\./\.npm-ci-network-retry\.sh')).Count -eq 5) 'Every XHSMedium CI npm install uses the bounded network retry helper.'
    Assert-True ($xhsmediumCi -match '\./\.npm-ci-network-retry\.sh --prefix \.\./automation --no-audit --no-fund') 'Frontend type checking installs its imported automation fixture dependencies through the retry helper.'
    $npmRetryHelper = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\npm-ci-network-retry.sh'
    Assert-True ($npmRetryHelper -match 'max_attempts=3' -and $npmRetryHelper -match 'NPM_CI_NETWORK_RETRY' -and $npmRetryHelper -match 'exit "\$status"') 'npm ci network retry helper is bounded and preserves final status.'
    Assert-True ($npmRetryHelper -match 'ECONNRESET\|ETIMEDOUT\|EAI_AGAIN\|ENETUNREACH\|ECONNREFUSED\|ERR_SOCKET_TIMEOUT' -and $npmRetryHelper -notmatch 'ERESOLVE|registry\.npmmirror\.com') 'npm ci retries only recognized transient network errors and keeps the official registry.'
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
    Assert-True ($xhsmediumRegression -match 'PAPER_SERVER_RESOURCE_MODE' -and $xhsmediumRegression -match 'if \(!paperServerResourceMode\)') 'paper-server resource mode omits the automatic regression timer.'
    Assert-True ($xhsmediumRegression -match 'disableConcurrentBuilds\(abortPrevious: false\)') 'XHSMedium regression does not overlap scheduled runs.'
    Assert-True ($xhsmediumRegression -match 'libraryResource\(''xhsmedium/docker-offline-wrapper\.sh''\)') 'XHSMedium regression installs the reviewed offline Docker wrapper.'
    Assert-True ($xhsmediumRegression -match 'libraryResource\(''xhsmedium/npm-ci-network-retry\.sh''\)' -and ([regex]::Matches($xhsmediumRegression, '\.platform-bin/npm-ci-network-retry --prefix')).Count -eq 3) 'Every regression npm install uses the bounded network retry helper.'
    Assert-True ($xhsmediumRegression -match 'XHSMEDIUM_OFFLINE_EVIDENCE_PATH' -and $xhsmediumRegression -match 'offline-dependency-cache\.log') 'XHSMedium regression archives fixed-SHA offline cache evidence.'
    Assert-True ($xhsmediumRegression -match 'down --volumes --remove-orphans') 'XHSMedium regression performs exact Compose cleanup.'
    Assert-True ($xhsmediumRegression -match 'VALIDATION_SLOT_UTC' -and $xhsmediumRegression -match 'VALIDATION_TIMEOUT_MINUTES must be between 0 and 30') 'XHSMedium regression bounds admin-only slot and timeout validation parameters.'
    Assert-True ($xhsmediumRegression -match 'NODE_OPTIONS="\$\{SCHEDULE_NODE_OPTIONS:-\}"') 'Production scheduled runs tolerate an absent validation slot shim.'
    Assert-True ($xhsmediumRegression -match 'substring\(11, 19\)' -and $xhsmediumRegression -match '%Y%m%d-%H%M00') 'Expected Compose project preserves the scheduler HHmmss runId format.'
    Assert-True ($xhsmediumRegression -notmatch '(?i)ftp://|feishu|aliyun|ossutil|/var/run/docker\.sock') 'XHSMedium regression contains no external delivery or host Docker Socket operation.'

    $xhsmediumRelease = Get-Content -Raw -LiteralPath 'jobs\projects\xhsmedium-release.groovy'
    Assert-True (([regex]::Matches($xhsmediumRelease, "pipelineJob\('XHSMedium/Release/(?:candidate|approve)'\)")).Count -eq 2) 'XHSMedium Release creates only candidate and approval Jobs.'
    Assert-True (-not (($xhsmediumRelease -split "`r?`n") | Where-Object { $_ -match "(?<!\\)\\n'\s*\+?\s*$" })) 'Nested Release Pipeline shell strings preserve escaped newlines through Job DSL generation.'
    Assert-True (([regex]::Matches($xhsmediumRelease, "agent \{ label 'xhsmedium-release' \}")).Count -eq 2) 'Release Jobs run only on the dedicated Release Agent.'
    Assert-True ($xhsmediumRelease -match 'GIT_SHA is required for a Release candidate' -and $xhsmediumRelease -match 'CI_BUILD_NUMBER' -and $xhsmediumRelease -match 'REGRESSION_BUILD_NUMBER') 'Candidate build requires fixed SHA CI and regression gates.'
    Assert-True ($xhsmediumRelease -match 'IMMUTABLE_TAG_EXISTS' -and $xhsmediumRelease -match 'git-\$\{env\.RESOLVED_SHA\}' -and $xhsmediumRelease -notmatch 'xhsmedium/(?:backend|frontend):latest') 'Candidate tags are full-SHA immutable tags and never latest.'
    Assert-True ($xhsmediumRelease -match "stringParam\('RECOVER_FROM_FAILED_BUILD'" -and $xhsmediumRelease -match 'assert b.*FAILURE' -and $xhsmediumRelease -match 'RECOVERY_TAG_SET_INCOMPLETE') 'Candidate recovery audits one failed build and requires both immutable tags.'
    Assert-True ($xhsmediumRelease -match "stage\('Build and push once'\)\s*\{\s*when \{ expression \{ env\.RECOVERY_MODE != 'true' \} \}" -and $xhsmediumRelease -match "stage\('Recover existing immutable images'\)\s*\{\s*when \{ expression \{ env\.RECOVERY_MODE == 'true' \} \}" -and $xhsmediumRelease -match 'org\.opencontainers\.image\.source' -and $xhsmediumRelease -match 'P5_CANDIDATE_RECOVERED') 'Recovery and build paths are mutually exclusive and recovered OCI metadata is verified.'
    Assert-True ($xhsmediumRelease -match 'candidate-manifest\.json' -and $xhsmediumRelease -match 'approved-release-manifest\.json' -and $xhsmediumRelease -match '@\$\{env\.(?:BACKEND|FRONTEND)_DIGEST\}') 'Release manifests preserve immutable Registry digests.'
    $approvalDsl = $xhsmediumRelease.Substring($xhsmediumRelease.IndexOf("pipelineJob('XHSMedium/Release/approve')"))
    Assert-True ($approvalDsl -notmatch 'docker build(?:x)?\s+(?:build|--pull)' -and $approvalDsl -match 'docker --config.*pull.*BACKEND_REFERENCE' -and $approvalDsl -match 'org\.opencontainers\.image\.revision') 'Release approval pulls existing digests with scoped credentials, verifies their SHA labels, and never rebuilds.'
    Assert-True ($xhsmediumRelease -notmatch '(?i)ftp://|feishu|aliyun|ossutil|/var/run/docker\.sock|\bdocker\s+compose\s+up\b|\bkubectl\b|\bssh\s+') 'P5 Release Jobs do not deploy, notify externally, or use the host Docker Socket.'

    $xhsmediumDeploy = Get-Content -Raw -LiteralPath 'jobs\projects\xhsmedium-deploy.groovy'
    Assert-True ($xhsmediumDeploy -match 'deploymentEnvironments' -and $xhsmediumDeploy -match 'pipelineJob\("XHSMedium/Deploy/\$\{environmentName\}"\)') 'P6 generates only the fixed dev and test deployment Jobs.'
    Assert-True ($xhsmediumDeploy -match 'CONFIRM_DEPLOY=true is required' -and $xhsmediumDeploy -match 'approved-release-manifest\.json' -and $xhsmediumDeploy -match 'approval-build\.json' -and $xhsmediumDeploy -match 'SUCCESS') 'P6 requires explicit confirmation and a successful approved Release manifest.'
    Assert-True ($xhsmediumDeploy -notmatch '(?i)docker\s+(?:build|buildx)|\bgit\s+(?:clone|checkout)|ftp://|feishu|aliyun|ossutil|/var/run/docker\.sock|\bkubectl\b|\bssh\s+') 'P6 deploys published images without source builds, external delivery, or the host Docker Socket.'
    Assert-True ($xhsmediumDeploy -match 'P6_DEPLOY_OK' -and $xhsmediumDeploy -match 'action=\$\{action\}' -and $xhsmediumDeploy -match 'deployment\.noop') 'P6 records digest deployment and explicit idempotent NOOP evidence.'
    Assert-True ($xhsmediumDeploy -match 'P6_SIMULATED_HEALTH_FAILURE' -and $xhsmediumDeploy -match 'P6_DEPLOY_ROLLED_BACK' -and $xhsmediumDeploy -match 'rollback-evidence\.json') 'P6 failure injection restores and records the previous successful deployment state.'
    $deployCompose = Get-Content -Raw -LiteralPath 'jobs\resources\xhsmedium-deploy-compose.yaml'
    Assert-True ($deployCompose -match 'image:\s*\$\{BACKEND_IMAGE\}' -and $deployCompose -match 'image:\s*\$\{FRONTEND_IMAGE\}' -and $deployCompose -notmatch '(?m)^\s*build:') 'P6 Compose consumes exact image references and contains no build context.'
    Assert-True ($deployCompose -match 'MYSQL_IMAGE' -and $deployCompose -match 'healthcheck:' -and $deployCompose -notmatch '(?m)^\s*ports:') 'P6 Compose uses an isolated MySQL dependency, health checks, and no host port publication.'

    $offlineWrapper = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\docker-offline-wrapper.sh'
    Assert-True ($offlineWrapper -match 'xhsmedium\.preload\.sha' -and $offlineWrapper -match 'xhsmedium\.preload\.role') 'Offline Docker wrapper verifies full SHA and role labels.'
    Assert-True ($offlineWrapper -match 'OFFLINE_DEPENDENCY_CACHE' -and $offlineWrapper -match 'NPM_OFFLINE=true' -and $offlineWrapper -match 'tee -a "\$evidence_path"') 'Offline Docker wrapper persists and enforces cache use.'
    Assert-True ($offlineWrapper -match 'XHSMEDIUM_COMPOSE_OVERRIDE_PATH' -and $offlineWrapper -match 'prefix=.*-f.*compose_override') 'Offline Docker wrapper applies the external MySQL compatibility override.'
    Assert-True ($offlineWrapper -notmatch '/var/run/docker\.sock') 'Offline Docker wrapper never references the host Docker Socket.'
    $mysqlCompatibility = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\mysql-entrypoint-compat.yaml'
    Assert-True ($mysqlCompatibility -match 'XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH' -and $mysqlCompatibility -match 'XHSMEDIUM_ORIGINAL_MYSQL_INIT_PATH') 'MySQL compatibility override mounts the wrapper and original fixed-SHA script separately.'
    Assert-True ($mysqlCompatibility -match 'XHSMEDIUM_RUNNER_UID' -and $mysqlCompatibility -match 'XHSMEDIUM_RUNNER_GID' -and $mysqlCompatibility -match 'XHSMEDIUM_RUNNER_ENTRYPOINT_PATH' -and $mysqlCompatibility -match 'HOME:\s*/tmp') 'Compose compatibility override installs the bounded runner volume entrypoint.'
    Assert-True ($xhsmediumRegression -match "XHSMEDIUM_RUNNER_UID = sh\(returnStdout: true, script: 'id -u'\)" -and $xhsmediumRegression -match "XHSMEDIUM_RUNNER_GID = sh\(returnStdout: true, script: 'id -g'\)") 'XHSMedium regression resolves the runner identity from the assigned Agent.'
    $runnerVolumeEntrypoint = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\runner-volume-entrypoint.sh'
    Assert-True ($runnerVolumeEntrypoint -match 'mountpoint -q' -and $runnerVolumeEntrypoint -match 'chown -R' -and $runnerVolumeEntrypoint -match 'exec setpriv.*--clear-groups') 'Runner volume entrypoint validates isolated mounts, initializes ownership, and drops root before running tests.'
    $projectCleanup = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\docker-project-cleanup.sh'
    Assert-True ($projectCleanup -match '\^xhsmedium-test-scheduled-' -and $projectCleanup -match 'label=com\.docker\.compose\.project=\$project' -and $projectCleanup -notmatch '(?i)system\s+prune') 'Project cleanup helper permits only scheduled projects and selects resources by exact Compose label.'
    Assert-True ($xhsmediumRegression -match 'XHSMEDIUM_PROJECT_CLEANUP_PATH' -and $xhsmediumRegression -match 'cleanup_status=0' -and $xhsmediumRegression -match 'exit "\$cleanup_status"') 'XHSMedium regression retries exact project cleanup and propagates cleanup failure.'
    $mysqlInitWrapper = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\mysql-init-wrapper.sh'
    Assert-True ($mysqlInitWrapper.Trim() -eq "#!/bin/sh`nbash /automation/original-initialize-database.sh") 'MySQL compatibility wrapper only executes the original script in a child shell.'
    $slotShim = Get-Content -Raw -LiteralPath 'shared-library\resources\xhsmedium\scheduled-slot-shim.cjs'
    Assert-True ($slotShim -match 'delete process\.env\.NODE_OPTIONS' -and $slotShim -match 'Invalid XHSMEDIUM_VALIDATION_SLOT_UTC') 'Scheduled slot shim validates its input and does not affect child Node processes.'

    $preloadScript = Get-Content -Raw -LiteralPath 'scripts\preload-xhsmedium-regression.ps1'
    Assert-True ($preloadScript -match "'--target', 'dependencies'" -and $preloadScript -match 'xhsmedium\.preload\.sha') 'Regression preloader builds labeled dependency stages.'
    Assert-True ($preloadScript -match "'save'" -and $preloadScript -match "'load'") 'Regression preloader transfers images into isolated DIND.'
    Assert-True (($preloadScript -match 'sha256:8dbcf531a03aade657e181b9cf2f1d1803ce621a1d55610cb44cb531ab7d7db6') -and ($preloadScript -match 'sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0') -and ($preloadScript -match 'sha256:b0ab6f3cb99aa7803adbc14d9027ec1785fc6e433b97e134e0f8fe61683b6b53') -and ($preloadScript -match 'sha256:9bd26ad900bb5e0f4dee75839e957a89ae89c2b7ab1e76050e559790e946b948')) 'Regression preloader verifies pinned input image identities.'
    $paperPreloadScript = Get-Content -Raw -LiteralPath 'scripts\preload-xhsmedium-regression.sh'
    Assert-True ($paperPreloadScript -match 'GIT_ASKPASS_REQUIRE=force' -and $paperPreloadScript -match 'fetch --quiet --depth=1 origin "\$sha"' -and $paperPreloadScript -notmatch '/opt/xhsmedium') 'paper-server preloader fetches only the requested SHA with non-interactive read-only credentials.'
    Assert-True (([regex]::Matches($paperPreloadScript, 'docker build --network host --target dependencies')).Count -eq 3 -and $paperPreloadScript -match 'xhsmedium\.preload\.sha') 'paper-server preloader builds three labeled dependency stages in Docker.'
    Assert-True (([regex]::Matches($paperPreloadScript, '--cache-from "\$cache_prefix-(?:backend|frontend|runner):latest"')).Count -eq 3) 'paper-server preloader can reuse exact preseeded dependency layers without changing fixed-SHA inputs.'
    Assert-True ($paperPreloadScript -match 'docker save --output' -and $paperPreloadScript -match 'docker load --input' -and $paperPreloadScript -match 'trap cleanup EXIT') 'paper-server preloader transfers caches into DIND and always cleans temporary resources.'
    $paperRegressionTest = Get-Content -Raw -LiteralPath 'scripts\test-xhsmedium-regression-paper-server.sh'
    Assert-True ($paperRegressionTest -match 'P4_PAPER_SERVER_EVIDENCE' -and $paperRegressionTest -match '(?s)stage_count=.*?\[ "\$stage_count" = 11 \]' -and $paperRegressionTest -match 'SCM token was found') 'paper-server regression acceptance checks business evidence, exact stage count, cleanup, and Secret leakage.'

    $composeText = Get-Content -Raw -LiteralPath 'compose.yaml'
    $controllerCompose = [regex]::Match($composeText, '(?ms)^  controller:.*?(?=^  build-agent:)').Value
    $buildAgentCompose = [regex]::Match($composeText, '(?ms)^  build-agent:.*?(?=^  regression-agent:)').Value
    Assert-True ($composeText -notmatch '/var/run/docker\.sock') 'Host Docker Socket is not referenced.'
    Assert-True (([regex]::Matches($composeText, '(?m)^\s+privileged:\s+true\s*$')).Count -eq 4) 'Exactly four isolated DIND services are privileged.'
    Assert-True ($composeText -match '(?s)build-agent:.*?networks:\s*\r?\n\s*- control') 'Build Agent is attached to the control network.'
    Assert-True ($composeText -match '(?s)regression-agent:.*?regression_docker') 'Regression Agent is attached to the isolated Docker network.'
    Assert-True (([regex]::Matches($composeText, 'regression_workspace:/home/jenkins/agent')).Count -eq 2) 'Regression Agent and DIND share the exact remote Workspace path.'
    Assert-True ($controllerCompose -match '(?s)secrets:.*?- xhsmedium_scm_token') 'Controller receives the XHSMedium SCM Docker Secret.'
    Assert-True ($controllerCompose -match '(?s)secrets:.*?- registry_username.*?- registry_password') 'Controller receives local Registry credentials through Docker Secrets.'
    Assert-True ($buildAgentCompose -notmatch 'xhsmedium_scm_token') 'Build Agent does not mount the XHSMedium SCM Docker Secret.'
    Assert-True ($buildAgentCompose -match '/home/jenkins/agent:size=2g,uid=1000,gid=1000,mode=0700,exec') 'Build Agent Workspace tmpfs explicitly permits CI tool execution.'
    Assert-True ($buildAgentCompose -match 'mem_limit:\s*2g') 'Build Agent has the confirmed 2 GiB memory limit.'
    Assert-True ($composeText -match '(?s)release-agent:.*?DOCKER_HOST:\s*tcp://release-docker:2376.*?tmpfs:.*?/home/jenkins/agent:size=4g' -and $composeText -match '(?s)release-docker:.*?--insecure-registry=registry:5000') 'Release Agent uses only its dedicated TLS DIND and local Registry endpoint.'
    Assert-True ($composeText -match '(?s)deploy-dev-agent:.*?DOCKER_HOST:\s*tcp://deploy-dev-docker:2376' -and $composeText -match '(?s)deploy-test-agent:.*?DOCKER_HOST:\s*tcp://deploy-test-docker:2376') 'Dev and test Deploy Agents use separate TLS Docker endpoints.'
    Assert-True ($composeText -match 'registry:2\.8\.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373' -and $composeText -match 'REGISTRY_STORAGE_DELETE_ENABLED:\s*"false"' -and $composeText -match '127\.0\.0\.1:\$\{REGISTRY_HTTP_PORT:-5000\}:5000') 'Local Registry is pinned, deletion-disabled, authenticated, and localhost-bound.'
    $releaseAgentDockerfile = Get-Content -Raw -LiteralPath 'agents\release\Dockerfile'
    Assert-True ($releaseAgentDockerfile -match 'docker:29\.3\.1-dind@sha256:686d2c' -and $releaseAgentDockerfile -match 'docker buildx version') 'Release Agent image pins and verifies its Docker toolchain.'
    $deployAgentDockerfile = Get-Content -Raw -LiteralPath 'agents\deploy\Dockerfile'
    Assert-True ($deployAgentDockerfile -match 'docker:29\.3\.1-dind@sha256:686d2c' -and $deployAgentDockerfile -match 'docker compose version') 'Deploy Agent image pins and verifies Docker Compose.'
    $seedJobs = Get-Content -Raw -LiteralPath 'jobs\seed.groovy'
    Assert-True ($seedJobs -match 'python3 --version && make --version && g\+\+ --version') 'Build Agent smoke verifies the native Node.js build toolchain.'
    Assert-True ($seedJobs -match "pipelineJob\('Platform/Validation/release-agent-smoke'\)" -and $seedJobs -match 'RELEASE_AGENT_OK') 'Release Agent smoke verifies TLS DIND and authenticated Registry access.'
    Assert-True ($seedJobs -match 'deploy-\$\{environmentName\}-agent-smoke' -and $seedJobs -match 'DEPLOY_\$\{environmentName\.toUpperCase\(\)\}_AGENT_OK') 'Deploy Agent smoke Jobs verify both isolated deployment targets.'

    $paperCompose = Get-Content -Raw -LiteralPath 'compose.paper-server.yaml'
    Assert-True (([regex]::Matches($paperCompose, '(?m)^\s+network:\s+host\s*$')).Count -eq 6) 'paper-server uses host networking only for six trusted image builds.'
    Assert-True (([regex]::Matches($paperCompose, '(?m)^\s+profiles:\s+\["(?:regression|release|deploy-dev|deploy-test)"\]\s*$')).Count -eq 8) 'paper-server gates all eight heavy Agent and DIND services behind profiles.'
    Assert-True ($paperCompose -match 'DEBIAN_MIRROR:\s+https://mirrors\.aliyun\.com/debian\s' -and $paperCompose -match 'DEBIAN_SECURITY_MIRROR:\s+https://mirrors\.aliyun\.com/debian-security\s') 'paper-server Build Agent uses separate reachable Debian mirrors.'
    Assert-True ($paperCompose -match 'PAPER_SERVER_RESOURCE_MODE:\s+"true"') 'paper-server Controller enables bounded on-demand resource mode.'
    Assert-True ($paperCompose -match '(?s)controller:.*?mem_limit:\s+1280m.*?cpus:\s+1\.0' -and $paperCompose -match '(?s)build-agent:.*?mem_limit:\s+2g.*?cpus:\s+1\.5' -and $paperCompose -match '(?s)registry:.*?mem_limit:\s+512m.*?cpus:\s+0\.25') 'paper-server baseline services have bounded CPU and memory.'
    Assert-True ($paperCompose -notmatch '/var/run/docker\.sock') 'paper-server override does not introduce the host Docker Socket.'
    $paperBootstrap = Get-Content -Raw -LiteralPath 'scripts\bootstrap-paper-server.sh'
    Assert-True ($paperBootstrap -match 'repo_root" != "/opt/jenkins-platform"' -and $paperBootstrap -match 'Missing required read-only SCM Secret') 'paper-server bootstrap enforces its fixed root and required read-only SCM Secret.'
    Assert-True ($paperBootstrap -match 'up --detach --build controller build-agent registry' -and $paperBootstrap -notmatch '(?i)down\s+--volumes|system\s+prune') 'paper-server bootstrap starts only baseline services and performs no destructive global cleanup.'

    docker compose config --quiet
    Assert-True ($LASTEXITCODE -eq 0) 'Docker Compose configuration is valid.'
    docker compose -f compose.yaml -f compose.paper-server.yaml config --quiet
    Assert-True ($LASTEXITCODE -eq 0) 'paper-server Docker Compose override is valid.'

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
        foreach ($service in @('build-agent', 'regression-agent', 'regression-docker', 'release-agent', 'release-docker', 'deploy-dev-agent', 'deploy-dev-docker', 'deploy-test-agent', 'deploy-test-docker', 'registry')) {
            $serviceId = (docker compose ps --quiet $service).Trim()
            Assert-True ([bool]$serviceId) "Service '$service' exists."
            $serviceHealth = (docker inspect --format '{{.State.Health.Status}}' $serviceId).Trim()
            Assert-True ($serviceHealth -eq 'healthy') "Service '$service' is healthy."
            $serviceIds[$service] = $serviceId
        }

        $buildInspect = (docker inspect $serviceIds['build-agent'] | ConvertFrom-Json)[0]
        $regressionInspect = (docker inspect $serviceIds['regression-agent'] | ConvertFrom-Json)[0]
        $dindInspect = (docker inspect $serviceIds['regression-docker'] | ConvertFrom-Json)[0]
        $releaseInspect = (docker inspect $serviceIds['release-agent'] | ConvertFrom-Json)[0]
        $releaseDindInspect = (docker inspect $serviceIds['release-docker'] | ConvertFrom-Json)[0]
        $deployDevInspect = (docker inspect $serviceIds['deploy-dev-agent'] | ConvertFrom-Json)[0]
        $deployDevDindInspect = (docker inspect $serviceIds['deploy-dev-docker'] | ConvertFrom-Json)[0]
        $deployTestInspect = (docker inspect $serviceIds['deploy-test-agent'] | ConvertFrom-Json)[0]
        $deployTestDindInspect = (docker inspect $serviceIds['deploy-test-docker'] | ConvertFrom-Json)[0]
        $registryInspect = (docker inspect $serviceIds['registry'] | ConvertFrom-Json)[0]
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
        Assert-True (-not @($releaseInspect.NetworkSettings.Ports.PSObject.Properties | Where-Object Value).Count) 'Release Agent publishes no host port.'
        Assert-True ($releaseDindInspect.HostConfig.Privileged) 'Release DIND is privileged and isolated from the host daemon.'
        $releaseEnvironment = $releaseInspect.Config.Env -join "`n"
        Assert-True ($releaseEnvironment -notmatch '(?im)(PASSWORD|TOKEN|SECRET)=') 'Release Agent environment contains no persistent credential value.'
        foreach ($deployInspect in @($deployDevInspect, $deployTestInspect)) {
            Assert-True (-not @($deployInspect.NetworkSettings.Ports.PSObject.Properties | Where-Object Value).Count) 'Deploy Agent publishes no host port.'
            Assert-True (($deployInspect.Config.Env -join "`n") -notmatch '(?im)(PASSWORD|TOKEN|SECRET)=') 'Deploy Agent environment contains no persistent credential value.'
        }
        Assert-True ($deployDevDindInspect.HostConfig.Privileged -and $deployTestDindInspect.HostConfig.Privileged) 'Dev and test Deploy DIND services are privileged and isolated from the host daemon.'
        $registryPort = @($registryInspect.NetworkSettings.Ports.'5000/tcp')[0].HostIp
        Assert-True ($registryPort -eq '127.0.0.1') 'Local Registry publishes only on localhost.'
        $socketMounts = @($buildInspect, $regressionInspect, $dindInspect, $releaseInspect, $releaseDindInspect, $deployDevInspect, $deployDevDindInspect, $deployTestInspect, $deployTestDindInspect | ForEach-Object { $_.Mounts } | Where-Object { $_.Source -match 'docker\.sock' })
        Assert-True ($socketMounts.Count -eq 0) 'Agent services do not mount the host Docker Socket.'
    }

    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
