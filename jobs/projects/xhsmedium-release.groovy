pipelineJob('XHSMedium/Release/candidate') {
    description('Builds and pushes immutable images once, or strictly recovers both images from an audited failed build without rebuilding or pushing. It never deploys.')
    parameters {
        stringParam('BRANCH', 'dev', 'Trusted source branch recorded in the candidate manifest.')
        stringParam('GIT_SHA', '', 'Required full 40-character SHA already accepted by CI and regression.')
        stringParam('CI_BUILD_NUMBER', '', 'Successful XHSMedium/CI/read-only build for the same SHA.')
        stringParam('REGRESSION_BUILD_NUMBER', '', 'Successful XHSMedium/Regression/scheduled build for the same SHA.')
        stringParam('RECOVER_FROM_FAILED_BUILD', '', 'Optional failed candidate build whose already-pushed immutable images may be recovered without rebuilding or pushing.')
    }
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _

pipeline {
    agent { label 'xhsmedium-release' }
    environment {
        XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'
        JENKINS_INTERNAL_URL = 'http://controller:8080'
        GIT_TERMINAL_PROMPT = '0'
        DOCKER_CONFIG = "${WORKSPACE}/.docker"
    }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: false)
        timeout(time: 90, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }
    stages {
        stage('Validate immutable input') {
            steps {
                script {
                    def requested = validateGitRef(branch: params.BRANCH, sha: params.GIT_SHA)
                    if (!requested.sha) { error('GIT_SHA is required for a Release candidate') }
                    if (!(params.CI_BUILD_NUMBER?.trim() ==~ /[1-9][0-9]*/)) { error('CI_BUILD_NUMBER must be a positive integer') }
                    if (!(params.REGRESSION_BUILD_NUMBER?.trim() ==~ /[1-9][0-9]*/)) { error('REGRESSION_BUILD_NUMBER must be a positive integer') }
                    if (params.RECOVER_FROM_FAILED_BUILD?.trim() && !(params.RECOVER_FROM_FAILED_BUILD.trim() ==~ /[1-9][0-9]*/)) { error('RECOVER_FROM_FAILED_BUILD must be blank or a positive integer') }
                    env.RELEASE_BRANCH = requested.branch
                    env.RESOLVED_SHA = requested.sha
                    env.CI_BUILD_NUMBER = params.CI_BUILD_NUMBER.trim()
                    env.REGRESSION_BUILD_NUMBER = params.REGRESSION_BUILD_NUMBER.trim()
                    env.RECOVERY_BUILD_NUMBER = params.RECOVER_FROM_FAILED_BUILD?.trim() ?: ''
                    env.RECOVERY_MODE = env.RECOVERY_BUILD_NUMBER ? 'true' : 'false'
                    env.RELEASE_ID = "xhsmedium-${env.RESOLVED_SHA.take(8)}"
                    env.BACKEND_TAG = "${env.LOCAL_REGISTRY}/xhsmedium/backend:git-${env.RESOLVED_SHA}"
                    env.FRONTEND_TAG = "${env.LOCAL_REGISTRY}/xhsmedium/frontend:git-${env.RESOLVED_SHA}"
                    currentBuild.description = "SHA=${env.RESOLVED_SHA.take(8)} CI=${env.CI_BUILD_NUMBER} REG=${env.REGRESSION_BUILD_NUMBER}" + (env.RECOVERY_BUILD_NUMBER ? " RECOVER=${env.RECOVERY_BUILD_NUMBER}" : '')
                }
            }
        }
        stage('Verify CI and regression gates') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'jenkins-audit-api', usernameVariable: 'JENKINS_API_USER', passwordVariable: 'JENKINS_API_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'auth="$JENKINS_API_USER:$JENKINS_API_PASSWORD"\\n' +
                        'ci_url="$JENKINS_INTERNAL_URL/job/XHSMedium/job/CI/job/read-only/$CI_BUILD_NUMBER"\\n' +
                        'reg_url="$JENKINS_INTERNAL_URL/job/XHSMedium/job/Regression/job/scheduled/$REGRESSION_BUILD_NUMBER"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$ci_url/api/json?tree=result" -o ci-build.json\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$ci_url/artifact/ci-evidence/build-metadata.txt" -o ci-build-metadata.txt\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$reg_url/api/json?tree=result" -o regression-build.json\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$reg_url/consoleText" -o regression-console.txt\\n' +
                        'python3 -c "import json; assert json.load(open(\\\'ci-build.json\\\'))[\\\'result\\\'] == \\\'SUCCESS\\\'"\\n' +
                        'grep -q "^sha=$RESOLVED_SHA$" ci-build-metadata.txt\\n' +
                        'python3 -c "import json; assert json.load(open(\\\'regression-build.json\\\'))[\\\'result\\\'] == \\\'SUCCESS\\\'"\\n' +
                        'run_id=$(sed -n "s/.*P4_SCHEDULED_REGRESSION_OK runId=\\\\([^ ]*\\\\) sha=$RESOLVED_SHA.*/\\\\1/p" regression-console.txt | tail -1)\\n' +
                        'test -n "$run_id"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$reg_url/artifact/artifacts/test-runs/$run_id/summary.json" -o regression-summary.json\\n' +
                        'python3 -c "import json,os; s=json.load(open(\\\'regression-summary.json\\\')); assert s[\\\'status\\\']==\\\'PASSED\\\' and s[\\\'testedSha\\\']==os.environ[\\\'RESOLVED_SHA\\\'] and s[\\\'coverage\\\'][\\\'partial\\\']==0 and s[\\\'coverage\\\'][\\\'blocked\\\']==0 and s[\\\'cleanup\\\'][\\\'succeeded\\\']"\\n'
                    )
                }
            }
        }
        stage('Verify failed candidate recovery') {
            when { expression { env.RECOVERY_MODE == 'true' } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'jenkins-audit-api', usernameVariable: 'JENKINS_API_USER', passwordVariable: 'JENKINS_API_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'auth="$JENKINS_API_USER:$JENKINS_API_PASSWORD"\\n' +
                        'recovery_url="$JENKINS_INTERNAL_URL/job/XHSMedium/job/Release/job/candidate/$RECOVERY_BUILD_NUMBER"\\n' +
                        'curl --globoff --fail --silent --show-error -u "$auth" "$recovery_url/api/json?tree=result,actions[parameters[name,value]]" -o recovery-build.json\\n' +
                        'python3 -c "import json,os; b=json.load(open(\\\'recovery-build.json\\\')); p={x[\\\'name\\\']:str(x.get(\\\'value\\\',\\\'\\\')) for a in b.get(\\\'actions\\\',[]) for x in a.get(\\\'parameters\\\',[])}; assert b[\\\'result\\\']==\\\'FAILURE\\\'; assert p.get(\\\'BRANCH\\\')==os.environ[\\\'RELEASE_BRANCH\\\']; assert p.get(\\\'GIT_SHA\\\')==os.environ[\\\'RESOLVED_SHA\\\']; assert p.get(\\\'CI_BUILD_NUMBER\\\')==os.environ[\\\'CI_BUILD_NUMBER\\\']; assert p.get(\\\'REGRESSION_BUILD_NUMBER\\\')==os.environ[\\\'REGRESSION_BUILD_NUMBER\\\']"\\n'
                    )
                }
            }
        }
        stage('Checkout fixed SHA') {
            when { expression { env.RECOVERY_MODE != 'true' } }
            steps {
                platformCheckout(url: env.XHSMEDIUM_REPOSITORY, sha: env.RESOLVED_SHA, credentialsId: 'xhsmedium-scm-readonly')
                sh 'set -eu; test "$(git rev-parse HEAD)" = "$RESOLVED_SHA"; test -f deploy/docker/backend.Dockerfile; test -f deploy/docker/frontend.Dockerfile'
            }
        }
        stage('Authenticate and inspect immutable tags') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-xhsmedium-push', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'mkdir -p "$DOCKER_CONFIG"\\n' +
                        'printf "%s" "$REGISTRY_PASSWORD" | docker --config "$DOCKER_CONFIG" login "$LOCAL_REGISTRY" --username "$REGISTRY_USER" --password-stdin >/dev/null\\n' +
                        'backend_exists=false; frontend_exists=false\\n' +
                        'if docker --config "$DOCKER_CONFIG" pull "$BACKEND_TAG" >/dev/null 2>&1; then backend_exists=true; fi\\n' +
                        'if docker --config "$DOCKER_CONFIG" pull "$FRONTEND_TAG" >/dev/null 2>&1; then frontend_exists=true; fi\\n' +
                        'if [ "$RECOVERY_MODE" = true ]; then\\n' +
                        '  if [ "$backend_exists" != true ] || [ "$frontend_exists" != true ]; then echo "RECOVERY_TAG_SET_INCOMPLETE backend=$backend_exists frontend=$frontend_exists" >&2; exit 63; fi\\n' +
                        'else\\n' +
                        '  if [ "$backend_exists" = true ]; then echo "IMMUTABLE_TAG_EXISTS image=$BACKEND_TAG" >&2; exit 61; fi\\n' +
                        '  if [ "$frontend_exists" = true ]; then echo "IMMUTABLE_TAG_EXISTS image=$FRONTEND_TAG" >&2; exit 61; fi\\n' +
                        'fi\\n'
                    )
                }
            }
        }
        stage('Build and push once') {
            when { expression { env.RECOVERY_MODE != 'true' } }
            steps {
                sh(
                    'set -eu\\n' +
                    'docker build --pull --label "org.opencontainers.image.revision=$RESOLVED_SHA" --label "org.opencontainers.image.source=$XHSMEDIUM_REPOSITORY" -f deploy/docker/backend.Dockerfile -t "$BACKEND_TAG" .\\n' +
                    'docker build --pull --label "org.opencontainers.image.revision=$RESOLVED_SHA" --label "org.opencontainers.image.source=$XHSMEDIUM_REPOSITORY" -f deploy/docker/frontend.Dockerfile -t "$FRONTEND_TAG" .\\n' +
                    'docker --config "$DOCKER_CONFIG" push "$BACKEND_TAG"\\n' +
                    'docker --config "$DOCKER_CONFIG" push "$FRONTEND_TAG"\\n' +
                    'docker --config "$DOCKER_CONFIG" pull "$BACKEND_TAG" >/dev/null\\n' +
                    'docker --config "$DOCKER_CONFIG" pull "$FRONTEND_TAG" >/dev/null\\n' +
                    'backend_reference=$(docker image inspect --format "{{range .RepoDigests}}{{println .}}{{end}}" "$BACKEND_TAG" | grep "^$LOCAL_REGISTRY/xhsmedium/backend@sha256:" | head -1)\\n' +
                    'frontend_reference=$(docker image inspect --format "{{range .RepoDigests}}{{println .}}{{end}}" "$FRONTEND_TAG" | grep "^$LOCAL_REGISTRY/xhsmedium/frontend@sha256:" | head -1)\\n' +
                    'backend_digest=${backend_reference##*@}\\n' +
                    'frontend_digest=${frontend_reference##*@}\\n' +
                    'case "$backend_digest:$frontend_digest" in sha256:*:sha256:*) ;; *) echo "Invalid Registry digest" >&2; exit 62 ;; esac\\n' +
                    'printf "%s" "$backend_digest" > backend.digest\\n' +
                    'printf "%s" "$frontend_digest" > frontend.digest\\n'
                )
            }
        }
        stage('Recover existing immutable images') {
            when { expression { env.RECOVERY_MODE == 'true' } }
            steps {
                sh(
                    'set -eu\\n' +
                    'for image in "$BACKEND_TAG" "$FRONTEND_TAG"; do\\n' +
                    '  test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.revision"}}\\\' "$image")" = "$RESOLVED_SHA"\\n' +
                    '  test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.source"}}\\\' "$image")" = "$XHSMEDIUM_REPOSITORY"\\n' +
                    'done\\n' +
                    'backend_reference=$(docker image inspect --format "{{range .RepoDigests}}{{println .}}{{end}}" "$BACKEND_TAG" | grep "^$LOCAL_REGISTRY/xhsmedium/backend@sha256:" | head -1)\\n' +
                    'frontend_reference=$(docker image inspect --format "{{range .RepoDigests}}{{println .}}{{end}}" "$FRONTEND_TAG" | grep "^$LOCAL_REGISTRY/xhsmedium/frontend@sha256:" | head -1)\\n' +
                    'backend_digest=${backend_reference##*@}\\n' +
                    'frontend_digest=${frontend_reference##*@}\\n' +
                    'case "$backend_digest:$frontend_digest" in sha256:*:sha256:*) ;; *) echo "Invalid Registry digest" >&2; exit 62 ;; esac\\n' +
                    'printf "%s" "$backend_digest" > backend.digest\\n' +
                    'printf "%s" "$frontend_digest" > frontend.digest\\n' +
                    'echo "P5_CANDIDATE_RECOVERED failedBuild=$RECOVERY_BUILD_NUMBER sha=$RESOLVED_SHA backend=$backend_digest frontend=$frontend_digest"\\n'
                )
            }
        }
        stage('Record candidate manifest') {
            steps {
                script {
                    env.BACKEND_DIGEST = readFile('backend.digest').trim()
                    env.FRONTEND_DIGEST = readFile('frontend.digest').trim()
                    env.RECORDED_AT = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
                    def recoveryField = env.RECOVERY_BUILD_NUMBER ? "\\n  \\\"recoveredFromFailedBuild\\\": ${env.RECOVERY_BUILD_NUMBER}," : ''
                    writeFile(file: 'candidate-manifest.json', text: """{
  \"schemaVersion\": \"1.0\",
  \"releaseId\": \"${env.RELEASE_ID}\",
  \"gitSha\": \"${env.RESOLVED_SHA}\",
  \"branch\": \"${env.RELEASE_BRANCH}\",
  \"recordedAt\": \"${env.RECORDED_AT}\",${recoveryField}
  \"jenkins\": {\"job\": \"${env.JOB_NAME}\", \"build\": ${env.BUILD_NUMBER}},
  \"gates\": {\"ciBuild\": ${env.CI_BUILD_NUMBER}, \"regressionBuild\": ${env.REGRESSION_BUILD_NUMBER}},
  \"images\": {
    \"backend\": {\"tag\": \"${env.BACKEND_TAG}\", \"digest\": \"${env.BACKEND_DIGEST}\", \"reference\": \"${env.LOCAL_REGISTRY}/xhsmedium/backend@${env.BACKEND_DIGEST}\"},
    \"frontend\": {\"tag\": \"${env.FRONTEND_TAG}\", \"digest\": \"${env.FRONTEND_DIGEST}\", \"reference\": \"${env.LOCAL_REGISTRY}/xhsmedium/frontend@${env.FRONTEND_DIGEST}\"}
  }
}
""")
                    echo "P5_CANDIDATE_OK releaseId=${env.RELEASE_ID} sha=${env.RESOLVED_SHA} backend=${env.BACKEND_DIGEST} frontend=${env.FRONTEND_DIGEST}"
                }
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'candidate-manifest.json,ci-build-metadata.txt,regression-summary.json,recovery-build.json', allowEmptyArchive: true, fingerprint: true
            sh 'docker image rm "$BACKEND_TAG" "$FRONTEND_TAG" >/dev/null 2>&1 || true; docker --config "$DOCKER_CONFIG" logout "$LOCAL_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "$DOCKER_CONFIG"'
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(20) }
}

pipelineJob('XHSMedium/Release/approve') {
    description('Approves an existing candidate manifest after rechecking its fixed SHA gates and Registry digests. It never rebuilds, retags, or deploys images.')
    parameters {
        stringParam('CANDIDATE_BUILD_NUMBER', '', 'Successful XHSMedium/Release/candidate build to approve without rebuilding.')
    }
    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
    agent { label 'xhsmedium-release' }
    environment {
        JENKINS_INTERNAL_URL = 'http://controller:8080'
        DOCKER_CONFIG = "${WORKSPACE}/.docker"
    }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: false)
        timeout(time: 10, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    stages {
        stage('Load existing candidate') {
            steps {
                script {
                    if (!(params.CANDIDATE_BUILD_NUMBER?.trim() ==~ /[1-9][0-9]*/)) { error('CANDIDATE_BUILD_NUMBER must be a positive integer') }
                    env.CANDIDATE_BUILD_NUMBER = params.CANDIDATE_BUILD_NUMBER.trim()
                }
                withCredentials([usernamePassword(credentialsId: 'jenkins-audit-api', usernameVariable: 'JENKINS_API_USER', passwordVariable: 'JENKINS_API_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'auth="$JENKINS_API_USER:$JENKINS_API_PASSWORD"\\n' +
                        'candidate_url="$JENKINS_INTERNAL_URL/job/XHSMedium/job/Release/job/candidate/$CANDIDATE_BUILD_NUMBER"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$candidate_url/api/json?tree=result" -o candidate-build.json\\n' +
                        'python3 -c "import json; assert json.load(open(\\\'candidate-build.json\\\'))[\\\'result\\\'] == \\\'SUCCESS\\\'"\\n' +
                        'curl --fail --silent --show-error -u "$auth" "$candidate_url/artifact/candidate-manifest.json" -o candidate-manifest.json\\n' +
                        'python3 -c "import json,re; m=json.load(open(\\\'candidate-manifest.json\\\')); assert re.fullmatch(r\\\'[0-9a-f]{40}\\\',m[\\\'gitSha\\\']); assert all(re.fullmatch(r\\\'sha256:[0-9a-f]{64}\\\',m[\\\'images\\\'][r][\\\'digest\\\']) for r in (\\\'backend\\\',\\\'frontend\\\'))"\\n'
                    )
                }
                script {
                    env.RESOLVED_SHA = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('candidate-manifest.json'))['gitSha'])\\\"").trim()
                    env.RELEASE_ID = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('candidate-manifest.json'))['releaseId'])\\\"").trim()
                    env.BACKEND_REFERENCE = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('candidate-manifest.json'))['images']['backend']['reference'])\\\"").trim()
                    env.FRONTEND_REFERENCE = sh(returnStdout: true, script: "python3 -c \\\"import json; print(json.load(open('candidate-manifest.json'))['images']['frontend']['reference'])\\\"").trim()
                    currentBuild.description = "${env.RELEASE_ID} CANDIDATE=${env.CANDIDATE_BUILD_NUMBER}"
                }
            }
        }
        stage('Verify immutable Registry digests') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-xhsmedium-push', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'mkdir -p "$DOCKER_CONFIG"\\n' +
                        'printf "%s" "$REGISTRY_PASSWORD" | docker --config "$DOCKER_CONFIG" login "$LOCAL_REGISTRY" --username "$REGISTRY_USER" --password-stdin >/dev/null\\n' +
                        'docker --config "$DOCKER_CONFIG" pull "$BACKEND_REFERENCE" >/dev/null\\n' +
                        'docker --config "$DOCKER_CONFIG" pull "$FRONTEND_REFERENCE" >/dev/null\\n' +
                        'test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.revision"}}\\\' "$BACKEND_REFERENCE")" = "$RESOLVED_SHA"\\n' +
                        'test "$(docker image inspect --format \\\'{{index .Config.Labels "org.opencontainers.image.revision"}}\\\' "$FRONTEND_REFERENCE")" = "$RESOLVED_SHA"\\n'
                    )
                }
            }
        }
        stage('Approve without rebuild') {
            steps {
                script {
                    env.APPROVED_AT = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
                    writeFile(file: 'approved-release-manifest.json', text: """{
  \"schemaVersion\": \"1.0\",
  \"releaseId\": \"${env.RELEASE_ID}\",
  \"gitSha\": \"${env.RESOLVED_SHA}\",
  \"candidateBuild\": ${env.CANDIDATE_BUILD_NUMBER},
  \"approvedAt\": \"${env.APPROVED_AT}\",
  \"approvedBy\": \"${env.BUILD_USER_ID ?: 'jenkins-admin'}\",
  \"images\": {\"backend\": \"${env.BACKEND_REFERENCE}\", \"frontend\": \"${env.FRONTEND_REFERENCE}\"}
}
""")
                    echo "P5_RELEASE_APPROVED releaseId=${env.RELEASE_ID} sha=${env.RESOLVED_SHA} candidate=${env.CANDIDATE_BUILD_NUMBER}"
                }
                archiveArtifacts artifacts: 'candidate-manifest.json,approved-release-manifest.json', fingerprint: true
            }
        }
    }
    post {
        always {
            sh 'docker image rm "$BACKEND_REFERENCE" "$FRONTEND_REFERENCE" >/dev/null 2>&1 || true; docker --config "$DOCKER_CONFIG" logout "$LOCAL_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "$DOCKER_CONFIG"'
            deleteDir()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(30) }
}
