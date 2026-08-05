def deployComposeFile = new File('/var/jenkins_home/job-dsl/resources/xhsmedium-deploy-compose.yaml')
if (!deployComposeFile.isFile()) {
    throw new IllegalStateException("Missing deployment template: ${deployComposeFile}")
}
def deployComposeBase64 = deployComposeFile.bytes.encodeBase64().toString()

def deploymentEnvironments = [
    dev: [label: 'xhsmedium-deploy-dev'],
    test: [label: 'xhsmedium-deploy-test']
]

deploymentEnvironments.each { environmentName, config ->
def pipelineSource = '''
@Library('jenkins-platform-library') _

pipeline {
    agent { label '__DEPLOY_LABEL__' }
    environment {
        JENKINS_INTERNAL_URL = 'http://controller:8080'
        XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'
        MYSQL_IMAGE = 'docker.m.daocloud.io/library/mysql@sha256:8dbcf531a03aade657e181b9cf2f1d1803ce621a1d55610cb44cb531ab7d7db6'
        EXPECTED_ENVIRONMENT = '__DEPLOY_ENVIRONMENT__'
        DOCKER_CONFIG = "${WORKSPACE}/.docker"
    }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: false)
        timeout(time: 25, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }
    stages {
        stage('Paper server resource gate') {
            steps { paperServerResourceGate() }
        }
        stage('Validate deployment approval') {
            steps {
                script {
                    if (!params.CONFIRM_DEPLOY) { error('CONFIRM_DEPLOY=true is required') }
                    if (!(params.APPROVED_RELEASE_BUILD_NUMBER?.trim() ==~ /[1-9][0-9]*/)) { error('APPROVED_RELEASE_BUILD_NUMBER must be a positive integer') }
                    if (env.DEPLOY_ENVIRONMENT != env.EXPECTED_ENVIRONMENT) { error("Agent environment mismatch: ${env.DEPLOY_ENVIRONMENT}") }
                    env.APPROVAL_BUILD = params.APPROVED_RELEASE_BUILD_NUMBER.trim()
                    env.DEPLOY_PROJECT = "xhsmedium-${env.EXPECTED_ENVIRONMENT}"
                    currentBuild.description = "${env.EXPECTED_ENVIRONMENT} APPROVAL=${env.APPROVAL_BUILD}"
                }
            }
        }
        stage('Load approved immutable manifest') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'jenkins-audit-api', usernameVariable: 'JENKINS_API_USER', passwordVariable: 'JENKINS_API_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'auth="$JENKINS_API_USER:$JENKINS_API_PASSWORD"\\n' +
                        'approval_url="$JENKINS_INTERNAL_URL/job/XHSMedium/job/Release/job/approve/$APPROVAL_BUILD"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$approval_url/api/json?tree=result" -o approval-build.json\\n' +
                        'python3 -c "import json; assert json.load(open(\\\'approval-build.json\\\'))[\\\'result\\\']==\\\'SUCCESS\\\'"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$approval_url/artifact/approved-release-manifest.json" -o approved-release-manifest.json\\n' +
                        'python3 -c "import json,re; m=json.load(open(\\\'approved-release-manifest.json\\\')); assert m[\\\'schemaVersion\\\']==\\\'1.0\\\'; assert re.fullmatch(r\\\'[0-9a-f]{40}\\\',m[\\\'gitSha\\\']); assert m[\\\'images\\\'][\\\'backend\\\'].startswith(\\\'registry:5000/xhsmedium/backend@sha256:\\\'); assert m[\\\'images\\\'][\\\'frontend\\\'].startswith(\\\'registry:5000/xhsmedium/frontend@sha256:\\\'); assert all(re.search(r\\\'@sha256:[0-9a-f]{64}$\\\',v) for v in m[\\\'images\\\'].values())"\\n'
                    )
                }
                script {
                    env.RESOLVED_SHA = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('approved-release-manifest.json'))['gitSha'])\\\"").trim()
                    env.RELEASE_ID = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('approved-release-manifest.json'))['releaseId'])\\\"").trim()
                    env.BACKEND_REFERENCE = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('approved-release-manifest.json'))['images']['backend'])\\\"").trim()
                    env.FRONTEND_REFERENCE = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('approved-release-manifest.json'))['images']['frontend'])\\\"").trim()
                }
            }
        }
        stage('Authenticate and verify published images') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-xhsmedium-push', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'mkdir -p "$DOCKER_CONFIG"\\n' +
                        'printf "%s" "$REGISTRY_PASSWORD" | docker --config "$DOCKER_CONFIG" login "$LOCAL_REGISTRY" --username "$REGISTRY_USER" --password-stdin >/dev/null\\n' +
                        'docker --config "$DOCKER_CONFIG" pull "$BACKEND_REFERENCE" >/dev/null\\n' +
                        'docker --config "$DOCKER_CONFIG" pull "$FRONTEND_REFERENCE" >/dev/null\\n' +
                        'for image in "$BACKEND_REFERENCE" "$FRONTEND_REFERENCE"; do\\n' +
                        '  test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.revision"}}\\\' "$image")" = "$RESOLVED_SHA"\\n' +
                        '  test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.source"}}\\\' "$image")" = "$XHSMEDIUM_REPOSITORY"\\n' +
                        'done\\n'
                    )
                }
            }
        }
        stage('Capture current deployment') {
            steps {
                sh 'printf "%s" "__DEPLOY_COMPOSE_BASE64__" | base64 -d > deploy-compose.yaml'
                sh(
                    'set -eu\\n' +
                    'backend_id=$(docker ps -aq --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=backend" | head -1)\\n' +
                    'frontend_id=$(docker ps -aq --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=frontend" | head -1)\\n' +
                    'if { [ -n "$backend_id" ] && [ -z "$frontend_id" ]; } || { [ -z "$backend_id" ] && [ -n "$frontend_id" ]; }; then echo DEPLOY_STATE_INCOMPLETE >&2; exit 71; fi\\n' +
                    'rm -f previous-deployment.env\\n' +
                    'if [ -n "$backend_id" ]; then\\n' +
                    '  previous_backend=$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$backend_id")\\n' +
                    '  previous_frontend=$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$frontend_id")\\n' +
                    '  previous_sha=$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.git-sha"}}\\\' "$backend_id")\\n' +
                    '  previous_approval=$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.approval-build"}}\\\' "$backend_id")\\n' +
                    '  case "$previous_backend:$previous_frontend" in registry:5000/xhsmedium/backend@sha256:*:registry:5000/xhsmedium/frontend@sha256:*) ;; *) echo INVALID_PREVIOUS_DEPLOYMENT >&2; exit 72 ;; esac\\n' +
                    '  printf "BACKEND_IMAGE=%s\\nFRONTEND_IMAGE=%s\\nGIT_SHA=%s\\nAPPROVAL_BUILD=%s\\n" "$previous_backend" "$previous_frontend" "$previous_sha" "$previous_approval" > previous-deployment.env\\n' +
                    'fi\\n' +
                    'if [ -n "$backend_id" ] && [ "$(docker inspect --format \\\'{{.State.Status}}\\\' "$backend_id")" = running ] && [ "$(docker inspect --format \\\'{{.State.Status}}\\\' "$frontend_id")" = running ] && [ "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$backend_id")" = "$BACKEND_REFERENCE" ] && [ "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$frontend_id")" = "$FRONTEND_REFERENCE" ]; then printf true > deployment.noop; else printf false > deployment.noop; fi\\n'
                )
                script {
                    env.DEPLOY_NOOP = readFile('deployment.noop').trim()
                    if (params.SIMULATE_HEALTH_FAILURE) { env.DEPLOY_NOOP = 'false' }
                }
            }
        }
        stage('Deploy exact digest') {
            when { expression { env.DEPLOY_NOOP != 'true' } }
            steps {
                withCredentials([
                    string(credentialsId: 'xhsmedium-__DEPLOY_ENVIRONMENT__-mysql-password', variable: 'MYSQL_PASSWORD'),
                    string(credentialsId: 'xhsmedium-__DEPLOY_ENVIRONMENT__-jwt-secret', variable: 'JWT_SECRET'),
                    string(credentialsId: 'xhsmedium-__DEPLOY_ENVIRONMENT__-draft-key', variable: 'DRAFT_KEY')
                ]) {
                    script {
                        def deployStatus = sh(returnStatus: true, script:
                            'set +x; set -eu\\n' +
                            'umask 077\\n' +
                            'printf "MYSQL_IMAGE=%s\\nBACKEND_IMAGE=%s\\nFRONTEND_IMAGE=%s\\nDEPLOY_ENVIRONMENT=%s\\nGIT_SHA=%s\\nAPPROVAL_BUILD=%s\\nMYSQL_PASSWORD=%s\\nJWT_SECRET=%s\\nDRAFT_KEY=%s\\n" "$MYSQL_IMAGE" "$BACKEND_REFERENCE" "$FRONTEND_REFERENCE" "$EXPECTED_ENVIRONMENT" "$RESOLVED_SHA" "$APPROVAL_BUILD" "$MYSQL_PASSWORD" "$JWT_SECRET" "$DRAFT_KEY" > runtime.env\\n' +
                            'extra_args=""; if [ "${SIMULATE_HEALTH_FAILURE}" = true ]; then extra_args="--force-recreate"; fi\\n' +
                            'docker compose --env-file runtime.env -f deploy-compose.yaml -p "$DEPLOY_PROJECT" up -d $extra_args --wait --wait-timeout 180\\n' +
                            'if [ "${SIMULATE_HEALTH_FAILURE}" = true ]; then docker stop "${DEPLOY_PROJECT}-frontend-1" >/dev/null; echo P6_SIMULATED_HEALTH_FAILURE >&2; exit 73; fi\\n' +
                            'backend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=backend" | head -1)\\n' +
                            'frontend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=frontend" | head -1)\\n' +
                            'docker exec "$backend_id" node -e "fetch(\\\'http://127.0.0.1:8089/api\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n' +
                            'docker exec "$frontend_id" node -e "fetch(\\\'http://127.0.0.1:3302/\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n'
                        )
                        if (deployStatus != 0) {
                            if (fileExists('previous-deployment.env')) {
                                sh(
                                    'set +x; set -eu\\n' +
                                    '. ./previous-deployment.env\\n' +
                                    'printf "MYSQL_IMAGE=%s\\nBACKEND_IMAGE=%s\\nFRONTEND_IMAGE=%s\\nDEPLOY_ENVIRONMENT=%s\\nGIT_SHA=%s\\nAPPROVAL_BUILD=%s\\nMYSQL_PASSWORD=%s\\nJWT_SECRET=%s\\nDRAFT_KEY=%s\\n" "$MYSQL_IMAGE" "$BACKEND_IMAGE" "$FRONTEND_IMAGE" "$EXPECTED_ENVIRONMENT" "$GIT_SHA" "$APPROVAL_BUILD" "$MYSQL_PASSWORD" "$JWT_SECRET" "$DRAFT_KEY" > rollback.env\\n' +
                                    'docker compose --env-file rollback.env -f deploy-compose.yaml -p "$DEPLOY_PROJECT" up -d --force-recreate --wait --wait-timeout 180\\n' +
                                    'backend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=backend" | head -1)\\n' +
                                    'frontend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=frontend" | head -1)\\n' +
                                    'test "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$backend_id")" = "$BACKEND_IMAGE"\\n' +
                                    'test "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$frontend_id")" = "$FRONTEND_IMAGE"\\n' +
                                    'docker exec "$backend_id" node -e "fetch(\\\'http://127.0.0.1:8089/api\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n' +
                                    'docker exec "$frontend_id" node -e "fetch(\\\'http://127.0.0.1:3302/\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n' +
                                    'python3 -c "import json,os; p={k:v for k,v in (line.rstrip().split(\\\'=\\\',1) for line in open(\\\'previous-deployment.env\\\'))}; json.dump({\\\'schemaVersion\\\':\\\'1.0\\\',\\\'environment\\\':os.environ[\\\'EXPECTED_ENVIRONMENT\\\'],\\\'failedApprovalBuild\\\':int(os.environ[\\\'APPROVAL_BUILD\\\']),\\\'restoredApprovalBuild\\\':int(p[\\\'APPROVAL_BUILD\\\']),\\\'gitSha\\\':p[\\\'GIT_SHA\\\'],\\\'images\\\':{\\\'backend\\\':p[\\\'BACKEND_IMAGE\\\'],\\\'frontend\\\':p[\\\'FRONTEND_IMAGE\\\']},\\\'healthy\\\':True},open(\\\'rollback-evidence.json\\\',\\\'w\\\'),indent=2)"\\n' +
                                    'echo "P6_DEPLOY_ROLLED_BACK environment=$EXPECTED_ENVIRONMENT approval=$APPROVAL_BUILD"\\n'
                                )
                            } else {
                                sh 'docker compose --env-file runtime.env -f deploy-compose.yaml -p "$DEPLOY_PROJECT" down --remove-orphans >/dev/null 2>&1 || true'
                            }
                            error("Deployment health gate failed with status ${deployStatus}; previous successful state was restored when available")
                        }
                    }
                }
            }
        }
        stage('Verify and record deployment') {
            steps {
                sh(
                    'set -eu\\n' +
                    'backend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=backend" | head -1)\\n' +
                    'frontend_id=$(docker ps -q --filter "label=com.docker.compose.project=$DEPLOY_PROJECT" --filter "label=com.docker.compose.service=frontend" | head -1)\\n' +
                    'test -n "$backend_id"; test -n "$frontend_id"\\n' +
                    'test "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$backend_id")" = "$BACKEND_REFERENCE"\\n' +
                    'test "$(docker inspect --format \\\'{{index .Config.Labels "xhsmedium.deploy.image-reference"}}\\\' "$frontend_id")" = "$FRONTEND_REFERENCE"\\n' +
                    'docker exec "$backend_id" node -e "fetch(\\\'http://127.0.0.1:8089/api\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n' +
                    'docker exec "$frontend_id" node -e "fetch(\\\'http://127.0.0.1:3302/\\\').then(r=>{if(r.status>=500)process.exit(1)}).catch(()=>process.exit(1))"\\n'
                )
                script {
                    env.DEPLOYED_AT = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
                    def action = env.DEPLOY_NOOP == 'true' ? 'NOOP' : 'DEPLOYED'
                    writeFile(file: 'deployment-evidence.json', text: """{
  \"schemaVersion\": \"1.0\",
  \"environment\": \"${env.EXPECTED_ENVIRONMENT}\",
  \"action\": \"${action}\",
  \"approvalBuild\": ${env.APPROVAL_BUILD},
  \"releaseId\": \"${env.RELEASE_ID}\",
  \"gitSha\": \"${env.RESOLVED_SHA}\",
  \"deployedAt\": \"${env.DEPLOYED_AT}\",
  \"images\": {\"backend\": \"${env.BACKEND_REFERENCE}\", \"frontend\": \"${env.FRONTEND_REFERENCE}\"},
  \"health\": {\"backend\": \"PASSED\", \"frontend\": \"PASSED\"}
}
""")
                    echo "P6_DEPLOY_OK environment=${env.EXPECTED_ENVIRONMENT} action=${action} approval=${env.APPROVAL_BUILD} sha=${env.RESOLVED_SHA}"
                }
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'approved-release-manifest.json,deployment-evidence.json,rollback-evidence.json', allowEmptyArchive: true, fingerprint: true
            sh 'set +x; docker --config "$DOCKER_CONFIG" logout "$LOCAL_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "$DOCKER_CONFIG" runtime.env rollback.env previous-deployment.env deploy-compose.yaml'
            deleteDir()
        }
    }
}
'''.stripIndent()
        .replace('__DEPLOY_LABEL__', config.label)
        .replace('__DEPLOY_ENVIRONMENT__', environmentName)
        .replace('__DEPLOY_COMPOSE_BASE64__', deployComposeBase64)

    pipelineJob("XHSMedium/Deploy/${environmentName}") {
        description("Deploys one approved XHSMedium manifest by digest to the isolated local ${environmentName} Docker target. It never builds source or contacts production systems.")
        parameters {
            stringParam('APPROVED_RELEASE_BUILD_NUMBER', '', 'Successful XHSMedium/Release/approve build to deploy by digest.')
            booleanParam('CONFIRM_DEPLOY', false, 'Required explicit non-production deployment confirmation.')
            booleanParam('SIMULATE_HEALTH_FAILURE', false, 'Acceptance-only fault injection; restores the previously successful deployment and leaves this build failed.')
        }
        definition {
            cps {
                sandbox(true)
                script(pipelineSource)
            }
        }
        logRotator { numToKeep(20); artifactNumToKeep(5) }
    }
}
