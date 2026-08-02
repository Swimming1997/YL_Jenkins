pipelineJob('XHSMedium/Regression/scheduled') {
    description('Runs the XHSMedium sealed scheduled-regression plan every two hours at a fixed dev SHA on the isolated Regression Agent and offline runtime DIND.')
    parameters {
        stringParam('BRANCH', 'dev', 'Trusted XHSMedium branch. Scheduled runs use dev.')
        stringParam('GIT_SHA', '', 'Optional full SHA for a manually scheduled slot. It overrides branch resolution.')
        stringParam('VALIDATION_SLOT_UTC', '', 'Admin-only validation slot in YYYY-MM-DDTHH:00:00Z format. Empty for real cron runs.')
        stringParam('VALIDATION_TIMEOUT_MINUTES', '0', 'Admin-only inner timeout from 0 to 30 minutes. Zero disables it.')
    }
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _

pipeline {
    agent { label 'xhsmedium-regression' }
    environment {
        XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'
        CI = 'true'
        GIT_TERMINAL_PROMPT = '0'
        npm_config_audit = 'false'
        npm_config_fund = 'false'
        npm_config_cache = "/tmp/${BUILD_TAG}-npm-cache"
        XHSMEDIUM_COMPOSE_OVERRIDE_PATH = "/tmp/${BUILD_TAG}-mysql-compat.yaml"
        XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH = "/home/jenkins/agent/.platform-compat/${BUILD_TAG}-mysql-init-wrapper.sh"
    }
    triggers { cron('0 */2 * * *') }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: false)
        timeout(time: 7, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }
    stages {
        stage('Resolve fixed SHA') {
            steps {
                script {
                    def requested = validateGitRef(branch: params.BRANCH, sha: params.GIT_SHA)
                    env.REGRESSION_BRANCH = requested.branch
                    if (requested.sha) {
                        env.RESOLVED_SHA = requested.sha
                    } else {
                        withCredentials([usernamePassword(
                            credentialsId: 'xhsmedium-scm-readonly',
                            usernameVariable: 'SCM_USER',
                            passwordVariable: 'SCM_TOKEN'
                        )]) {
                            env.SCM_ASKPASS_PATH = "/tmp/${env.BUILD_TAG}-regression-git-askpass"
                            writeFile(file: '.git-askpass.sh', text: '#!/bin/sh\\ncase "$1" in\\n  *Username*) printf "%s\\\\n" "$SCM_USER" ;;\\n  *Password*) printf "%s\\\\n" "$SCM_TOKEN" ;;\\n  *) exit 1 ;;\\nesac\\n')
                            try {
                                env.RESOLVED_SHA = sh(
                                    returnStdout: true,
                                    script: 'set +x; install -m 700 .git-askpass.sh "$SCM_ASKPASS_PATH"; GIT_ASKPASS="$SCM_ASKPASS_PATH" GIT_ASKPASS_REQUIRE=force git ls-remote --exit-code --heads "$XHSMEDIUM_REPOSITORY" "refs/heads/$REGRESSION_BRANCH" | cut -f1'
                                ).trim()
                            } finally {
                                sh 'rm -f .git-askpass.sh "$SCM_ASKPASS_PATH"'
                            }
                        }
                    }
                    env.RESOLVED_SHA = validateGitRef(branch: env.REGRESSION_BRANCH, sha: env.RESOLVED_SHA).sha
                    env.XHSMEDIUM_DEPENDENCY_CACHE_PREFIX = "xhsmedium-deps-${env.RESOLVED_SHA.take(8)}"
                    echo "RESOLVED_SHA=${env.RESOLVED_SHA}"
                }
            }
        }
        stage('Checkout and pin origin') {
            steps {
                platformCheckout(url: env.XHSMEDIUM_REPOSITORY, sha: env.RESOLVED_SHA, credentialsId: 'xhsmedium-scm-readonly')
                sh(
                    'set -eu\\n' +
                    'test "$(git rev-parse HEAD)" = "$RESOLVED_SHA"\\n' +
                    'git init --bare .pinned-origin.git\\n' +
                    'git push "file://$WORKSPACE/.pinned-origin.git" "$RESOLVED_SHA:refs/heads/$REGRESSION_BRANCH"\\n' +
                    'git remote set-url origin "file://$WORKSPACE/.pinned-origin.git"\\n'
                )
            }
        }
        stage('Prepare offline runtime') {
            steps {
                script {
                    ['backend', 'frontend', 'runner'].each { role ->
                        sh """set -eu
image='${env.XHSMEDIUM_DEPENDENCY_CACHE_PREFIX}-${role}:latest'
test \"\\$(docker image inspect --format '{{index .Config.Labels \\\"xhsmedium.preload.sha\\\"}}' \"\\$image\")\" = '${env.RESOLVED_SHA}'
test \"\\$(docker image inspect --format '{{index .Config.Labels \\\"xhsmedium.preload.role\\\"}}' \"\\$image\")\" = '${role}'
"""
                    }
                    sh 'mkdir -p .platform-bin'
                    writeFile(file: '.platform-bin/docker', text: libraryResource('xhsmedium/docker-offline-wrapper.sh'))
                    writeFile(file: '.mysql-entrypoint-compat.yaml', text: libraryResource('xhsmedium/mysql-entrypoint-compat.yaml'))
                    writeFile(file: '.mysql-init-wrapper.sh', text: libraryResource('xhsmedium/mysql-init-wrapper.sh'))
                    env.XHSMEDIUM_RUNNER_UID = sh(returnStdout: true, script: 'id -u').trim()
                    env.XHSMEDIUM_RUNNER_GID = sh(returnStdout: true, script: 'id -g').trim()
                    env.XHSMEDIUM_ORIGINAL_MYSQL_INIT_PATH = "${env.WORKSPACE}/automation/fixtures/initialize-database.sh"
                    def validationSlot = params.VALIDATION_SLOT_UTC?.trim()
                    def validationTimeout = params.VALIDATION_TIMEOUT_MINUTES?.trim()
                    if (!(validationTimeout ==~ /[0-9]{1,2}/) || validationTimeout.toInteger() > 30) {
                        error('VALIDATION_TIMEOUT_MINUTES must be between 0 and 30')
                    }
                    env.VALIDATION_TIMEOUT_MINUTES = validationTimeout
                    if (validationSlot) {
                        if (!(validationSlot ==~ /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:00:00Z/) || validationSlot.substring(11, 13).toInteger() % 2 != 0) {
                            error('VALIDATION_SLOT_UTC must be an even UTC hour')
                        }
                        env.XHSMEDIUM_VALIDATION_SLOT_UTC = validationSlot
                        env.XHSMEDIUM_SLOT_SHIM_PATH = "/home/jenkins/agent/.platform-compat/${env.BUILD_TAG}-slot-shim.cjs"
                        env.SCHEDULE_NODE_OPTIONS = "--require=${env.XHSMEDIUM_SLOT_SHIM_PATH}"
                        writeFile(file: '.scheduled-slot-shim.cjs', text: libraryResource('xhsmedium/scheduled-slot-shim.cjs'))
                    }
                }
                sh(
                    'set -eu\\n' +
                    'chmod 700 .platform-bin/docker\\n' +
                    'install -m 600 .mysql-entrypoint-compat.yaml "$XHSMEDIUM_COMPOSE_OVERRIDE_PATH"\\n' +
                    'mkdir -p "$(dirname "$XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH")"\\n' +
                    'install -m 644 .mysql-init-wrapper.sh "$XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH"\\n' +
                    'if test -f .scheduled-slot-shim.cjs; then install -m 600 .scheduled-slot-shim.cjs "$XHSMEDIUM_SLOT_SHIM_PATH"; rm -f .scheduled-slot-shim.cjs; fi\\n' +
                    'rm -f .mysql-entrypoint-compat.yaml\\n' +
                    'rm -f .mysql-init-wrapper.sh\\n' +
                    'npm ci --prefix regression --no-audit --no-fund\\n' +
                    'mkdir -p regression/worktrees\\n' +
                    'cp automation/package.json automation/package-lock.json regression/worktrees/\\n' +
                    'npm ci --prefix regression/worktrees --no-audit --no-fund\\n' +
                    'npm ci --prefix automation --no-audit --no-fund\\n' +
                    'npm run build --prefix automation\\n'
                )
                script {
                    def utcSlot = env.XHSMEDIUM_VALIDATION_SLOT_UTC ?
                        env.XHSMEDIUM_VALIDATION_SLOT_UTC.substring(0, 10).replace('-', '') + '-' + env.XHSMEDIUM_VALIDATION_SLOT_UTC.substring(11, 19).replace(':', '') :
                        sh(returnStdout: true, script: 'date -u +%Y%m%d-%H%M00').trim()
                    env.EXPECTED_RUN_ID = "scheduled-${utcSlot}-${env.RESOLVED_SHA.take(8)}"
                    env.XHSMEDIUM_DOCKER_PROJECT = "xhsmedium-test-${env.EXPECTED_RUN_ID}".toLowerCase().replaceAll(/[^a-z0-9_-]+/, '-').replaceAll(/^-+|-+$/, '').take(63)
                    currentBuild.description = "SHA=${env.RESOLVED_SHA.take(8)} RUN=${env.EXPECTED_RUN_ID}"
                }
            }
        }
        stage('Sealed scheduled regression') {
            steps {
                script {
                    def command = (
                    '#!/usr/bin/env bash\\n' +
                    'set -euo pipefail\\n' +
                    'export PATH="$WORKSPACE/.platform-bin:$WORKSPACE/regression/worktrees/node_modules/.bin:$PATH"\\n' +
                    'NODE_OPTIONS="${SCHEDULE_NODE_OPTIONS:-}" node regression/src/scheduled-entry.js --branch "$REGRESSION_BRANCH" --build-number "$BUILD_NUMBER" 2>&1 | tee scheduled-regression.log\\n' +
                    'grep -q PASSED scheduled-regression.log\\n' +
                    'test -f "artifacts/test-runs/$EXPECTED_RUN_ID/summary.json"\\n' +
                    'grep -q runId "artifacts/test-runs/$EXPECTED_RUN_ID/summary.json"\\n' +
                    'echo "P4_SCHEDULED_REGRESSION_OK runId=$EXPECTED_RUN_ID sha=$RESOLVED_SHA"\\n'
                    )
                    if (env.VALIDATION_TIMEOUT_MINUTES.toInteger() > 0) {
                        timeout(time: env.VALIDATION_TIMEOUT_MINUTES.toInteger(), unit: 'MINUTES') { sh(command) }
                    } else {
                        sh(command)
                    }
                }
            }
        }
    }
    post {
        always {
            sh(
                'set -eu\\n' +
                'case "${XHSMEDIUM_DOCKER_PROJECT:-}" in\\n' +
                '  xhsmedium-test-scheduled-*) /usr/local/bin/docker compose -f "$WORKSPACE/automation/compose.test.yml" --project-name "$XHSMEDIUM_DOCKER_PROJECT" down --volumes --remove-orphans --timeout 30 ;;\\n' +
                'esac\\n' +
                'test -z "${SCM_ASKPASS_PATH:-}" || rm -f "$SCM_ASKPASS_PATH"\\n' +
                'test -z "${XHSMEDIUM_COMPOSE_OVERRIDE_PATH:-}" || rm -f "$XHSMEDIUM_COMPOSE_OVERRIDE_PATH"\\n' +
                'test -z "${XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH:-}" || rm -f "$XHSMEDIUM_MYSQL_INIT_WRAPPER_PATH"\\n' +
                'test -z "${XHSMEDIUM_SLOT_SHIM_PATH:-}" || rm -f "$XHSMEDIUM_SLOT_SHIM_PATH"\\n' +
                'rmdir /home/jenkins/agent/.platform-compat 2>/dev/null || true\\n' +
                'case "$npm_config_cache" in /tmp/jenkins-XHSMedium-Regression-scheduled-*-npm-cache) rm -rf -- "$npm_config_cache" ;; *) false ;; esac\\n'
            )
            archiveArtifacts artifacts: 'scheduled-regression.log,artifacts/test-runs/**,artifacts/regression/**', allowEmptyArchive: true, fingerprint: true
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(20) }
    disabled(false)
}
