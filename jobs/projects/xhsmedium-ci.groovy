pipelineJob('XHSMedium/CI/read-only') {
    description('Manual, read-only CI for XHSMedium. It resolves a trusted branch or full SHA, runs project checks on the isolated Build Agent, and never publishes or deploys.')
    parameters {
        stringParam('BRANCH', 'dev', 'Trusted XHSMedium branch name. The repository URL is fixed by the job.')
        stringParam('GIT_SHA', '', 'Optional full 40-character commit SHA. When set, it overrides branch resolution.')
    }
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _

pipeline {
    agent { label 'xhsmedium-build' }
    environment {
        XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'
        CI = 'true'
        NEXT_TELEMETRY_DISABLED = '1'
        GIT_TERMINAL_PROMPT = '0'
        npm_config_audit = 'false'
        npm_config_fund = 'false'
        npm_config_cache = "/tmp/${BUILD_TAG}-npm-cache"
    }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: true)
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }
    stages {
        stage('Resolve fixed SHA') {
            steps {
                script {
                    def requested = validateGitRef(branch: params.BRANCH, sha: params.GIT_SHA)
                    env.CI_BRANCH = requested.branch
                    if (requested.sha) {
                        env.RESOLVED_SHA = requested.sha
                    } else {
                        withCredentials([usernamePassword(
                            credentialsId: 'xhsmedium-scm-readonly',
                            usernameVariable: 'SCM_USER',
                            passwordVariable: 'SCM_TOKEN'
                        )]) {
                            env.SCM_ASKPASS_PATH = "/tmp/${env.BUILD_TAG}-git-askpass"
                            writeFile(
                                file: '.git-askpass.sh',
                                text: '#!/bin/sh\\ncase "$1" in\\n  *Username*) printf "%s\\\\n" "$SCM_USER" ;;\\n  *Password*) printf "%s\\\\n" "$SCM_TOKEN" ;;\\n  *) exit 1 ;;\\nesac\\n'
                            )
                            try {
                                env.RESOLVED_SHA = sh(
                                    returnStdout: true,
                                    script: 'set +x; install -m 700 .git-askpass.sh "$SCM_ASKPASS_PATH"; GIT_ASKPASS="$SCM_ASKPASS_PATH" GIT_ASKPASS_REQUIRE=force git ls-remote --exit-code --heads "$XHSMEDIUM_REPOSITORY" "refs/heads/$CI_BRANCH" | cut -f1'
                                ).trim()
                            } finally {
                                sh 'rm -f .git-askpass.sh "$SCM_ASKPASS_PATH"'
                            }
                        }
                    }
                    env.RESOLVED_SHA = validateGitRef(branch: env.CI_BRANCH, sha: env.RESOLVED_SHA).sha
                    echo "RESOLVED_SHA=${env.RESOLVED_SHA}"
                }
            }
        }
        stage('Checkout') {
            steps {
                platformCheckout(
                    url: env.XHSMEDIUM_REPOSITORY,
                    sha: env.RESOLVED_SHA,
                    credentialsId: 'xhsmedium-scm-readonly'
                )
                sh 'set -eu; test "$(git rev-parse HEAD)" = "$RESOLVED_SHA"; test "$(git remote get-url origin)" = "$XHSMEDIUM_REPOSITORY"'
                recordBuildMetadata(
                    repository: env.XHSMEDIUM_REPOSITORY,
                    branch: env.CI_BRANCH,
                    sha: env.RESOLVED_SHA,
                    output: 'ci-evidence/build-metadata.txt'
                )
            }
        }
        stage('Backend') {
            environment { NODE_OPTIONS = '--max-old-space-size=768' }
            steps {
                nodeModuleCi(
                    module: 'backend',
                    logName: 'backend.log',
                    commands: [
                        './.npm-ci-network-retry.sh --no-audit --no-fund',
                        'npm test -- --runInBand --json --outputFile="$WORKSPACE/ci-evidence/backend-tests.json"',
                        'npm run build'
                    ]
                )
            }
        }
        stage('Frontend') {
            environment { NODE_OPTIONS = '--max-old-space-size=1536' }
            steps {
                nodeModuleCi(
                    module: 'frontend',
                    logName: 'frontend.log',
                    commands: [
                        './.npm-ci-network-retry.sh --prefix ../automation --no-audit --no-fund',
                        './.npm-ci-network-retry.sh --no-audit --no-fund',
                        'npm run lint',
                        'npm test',
                        'npm run build'
                    ]
                )
            }
        }
        stage('Automation') {
            environment { NODE_OPTIONS = '--max-old-space-size=512' }
            steps {
                nodeModuleCi(
                    module: 'automation',
                    logName: 'automation.log',
                    commands: [
                        './.npm-ci-network-retry.sh --no-audit --no-fund',
                        'npm test',
                        'npm run validate'
                    ]
                )
            }
        }
        stage('Regression control plane') {
            environment { NODE_OPTIONS = '--max-old-space-size=512' }
            steps {
                nodeModuleCi(
                    module: 'regression',
                    logName: 'regression.log',
                    commands: [
                        './.npm-ci-network-retry.sh --no-audit --no-fund',
                        'npm test'
                    ]
                )
            }
        }
        stage('Read-only verification') {
            steps {
                sh 'git diff --exit-code -- .'
                echo 'READ_ONLY_CI_OK'
            }
        }
    }
    post {
        always {
            sh 'test -z "${SCM_ASKPASS_PATH:-}" || rm -f "$SCM_ASKPASS_PATH"'
            sh 'case "$npm_config_cache" in /tmp/jenkins-XHSMedium-CI-read-only-*-npm-cache) rm -rf -- "$npm_config_cache" ;; *) echo "Unsafe npm cache path" >&2; false ;; esac'
            echo 'QUALITY_GAP: backend npm run lint is omitted because the repository command uses --fix.'
            archiveArtifacts artifacts: 'ci-evidence/**', allowEmptyArchive: true, fingerprint: true
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator {
        numToKeep(20)
        artifactNumToKeep(5)
    }
    disabled(false)
}

pipelineJob('XHSMedium/CI/watch-dev') {
    description('Checks the private XHSMedium dev branch once per hour and triggers read-only CI exactly once for each newly observed SHA.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _

pipeline {
    agent { label 'xhsmedium-build' }
    environment {
        XHSMEDIUM_REPOSITORY = 'https://github.com/MuFannnn/xhsmedium.git'
        WATCH_BRANCH = 'dev'
        INITIAL_BASELINE_SHA = '1ac17fb695a8099fe01e0cd9311b6f272c23a491'
        GIT_TERMINAL_PROMPT = '0'
    }
    triggers { cron('H * * * *') }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 3, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }
    stages {
        stage('Check dev SHA') {
            steps {
                script {
                    withCredentials([usernamePassword(
                        credentialsId: 'xhsmedium-scm-readonly',
                        usernameVariable: 'SCM_USER',
                        passwordVariable: 'SCM_TOKEN'
                    )]) {
                        env.SCM_ASKPASS_PATH = "/tmp/${env.BUILD_TAG}-watch-git-askpass"
                        writeFile(
                            file: '.git-askpass.sh',
                            text: '#!/bin/sh\\ncase "$1" in\\n  *Username*) printf "%s\\\\n" "$SCM_USER" ;;\\n  *Password*) printf "%s\\\\n" "$SCM_TOKEN" ;;\\n  *) exit 1 ;;\\nesac\\n'
                        )
                        try {
                            env.REMOTE_SHA = sh(
                                returnStdout: true,
                                script: 'set +x; install -m 700 .git-askpass.sh "$SCM_ASKPASS_PATH"; GIT_ASKPASS="$SCM_ASKPASS_PATH" GIT_ASKPASS_REQUIRE=force git ls-remote --exit-code --heads "$XHSMEDIUM_REPOSITORY" "refs/heads/$WATCH_BRANCH" | cut -f1'
                            ).trim()
                        } finally {
                            sh 'rm -f .git-askpass.sh "$SCM_ASKPASS_PATH"'
                        }
                    }

                    env.REMOTE_SHA = validateGitRef(branch: env.WATCH_BRANCH, sha: env.REMOTE_SHA).sha
                    def decision = scmChangeDecision(
                        remoteSha: env.REMOTE_SHA,
                        baselineSha: env.INITIAL_BASELINE_SHA,
                        previousDescription: currentBuild.previousBuild?.description
                    )
                    if (!decision.changed) {
                        currentBuild.description = "SHA=${decision.remoteSha}"
                        echo "SCM_NO_CHANGE sha=${decision.remoteSha} source=${decision.source}"
                        return
                    }

                    build(
                        job: '/XHSMedium/CI/read-only',
                        parameters: [
                            string(name: 'BRANCH', value: env.WATCH_BRANCH),
                            string(name: 'GIT_SHA', value: decision.remoteSha)
                        ],
                        wait: false,
                        quietPeriod: 0
                    )
                    currentBuild.description = "SHA=${decision.remoteSha}"
                    echo "SCM_CHANGE_TRIGGERED previous=${decision.lastSeenSha} current=${decision.remoteSha}"
                }
            }
        }
    }
    post {
        always {
            sh 'test -z "${SCM_ASKPASS_PATH:-}" || rm -f "$SCM_ASKPASS_PATH"'
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(20); artifactNumToKeep(5) }
    disabled(false)
}
