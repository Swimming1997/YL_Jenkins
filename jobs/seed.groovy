freeStyleJob('Platform/seed') {
    description('Folder and validation jobs are generated automatically by JCasC Job DSL. Manual execution is reserved for the future SCM-backed seed flow.')
    disabled(true)
}

pipelineJob('Platform/Validation/shared-library-smoke') {
    description('Loads the SCM-backed platform Shared Library without allocating a build executor.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _

pipeline {
    agent none
    options {
        timeout(time: 2, unit: 'MINUTES')
    }
    stages {
        stage('Load library') {
            steps {
                script {
                    def identity = platformIdentity()
                    if (identity.name != 'jenkins-platform-library' || identity.apiVersion != 'v1') {
                        error("Unexpected library identity: ${identity}")
                    }
                    echo 'SCM_LIBRARY_OK'
                }
            }
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator {
        numToKeep(5)
    }
    disabled(false)
}

pipelineJob('Platform/Validation/build-agent-smoke') {
    description('Validates the isolated Node.js Build Agent toolchain and Docker absence.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _
pipeline {
    agent { label 'xhsmedium-build' }
    options { skipDefaultCheckout(true); timeout(time: 3, unit: 'MINUTES') }
    stages {
        stage('Toolchain') {
            steps {
                sh 'java -version && git --version && node --version && npm --version && python3 --version && make --version && g++ --version'
                sh 'if command -v docker >/dev/null 2>&1; then echo "Docker must not exist on Build Agent" >&2; exit 1; fi'
                echo 'BUILD_AGENT_OK'
            }
        }
    }
    post { always { cleanupWorkspace() } }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

pipelineJob('Platform/Validation/regression-agent-smoke') {
    description('Validates the Regression Agent and its isolated TLS Docker daemon.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _
pipeline {
    agent { label 'xhsmedium-regression' }
    options { skipDefaultCheckout(true); timeout(time: 5, unit: 'MINUTES') }
    stages {
        stage('Toolchain') {
            steps {
                sh 'java -version && git --version && node --version && npm --version && docker --version && docker compose version'
                sh 'docker info >/dev/null'
                sh 'docker volume create "p2-smoke-${BUILD_NUMBER}" >/dev/null && docker volume rm "p2-smoke-${BUILD_NUMBER}" >/dev/null'
                echo 'REGRESSION_AGENT_OK'
            }
        }
    }
    post {
        always {
            sh 'docker volume rm "p2-smoke-${BUILD_NUMBER}" >/dev/null 2>&1 || true'
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

pipelineJob('Platform/Validation/workspace-cleanup') {
    description('Creates a marker and proves post-always workspace cleanup runs.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _
pipeline {
    agent { label 'xhsmedium-build' }
    options { skipDefaultCheckout(true); timeout(time: 2, unit: 'MINUTES') }
    stages {
        stage('Create marker') {
            steps {
                sh 'mkdir -p p2-probe && printf marker > p2-probe/marker.txt'
                echo 'WORKSPACE_MARKER_CREATED'
            }
        }
    }
    post { always { cleanupWorkspace() } }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

pipelineJob('Platform/Validation/timeout-cleanup') {
    description('Intentionally times out and removes only its exact Docker network and workspace.')
    definition {
        cps {
            sandbox(true)
            script('''
@Library('jenkins-platform-library') _
pipeline {
    agent { label 'xhsmedium-regression' }
    options { skipDefaultCheckout(true) }
    stages {
        stage('Expected timeout') {
            steps {
                sh 'docker network create "p2-timeout-${BUILD_NUMBER}"'
                timeout(time: 3, unit: 'SECONDS') {
                    sleep 30
                }
            }
        }
    }
    post {
        always {
            sh 'docker network rm "p2-timeout-${BUILD_NUMBER}" >/dev/null 2>&1 || true'
            cleanupWorkspace()
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

pipelineJob('Platform/Validation/agent-reconnect') {
    description('Runs a lightweight command on both isolated Agent labels.')
    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
    agent none
    options { skipDefaultCheckout(true); timeout(time: 3, unit: 'MINUTES') }
    stages {
        stage('Both agents') {
            parallel {
                stage('Build Agent') {
                    agent { label 'xhsmedium-build' }
                    steps { sh 'printf BUILD_RECONNECTED' }
                }
                stage('Regression Agent') {
                    agent { label 'xhsmedium-regression' }
                    steps { sh 'printf REGRESSION_RECONNECTED' }
                }
            }
        }
    }
}
'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

pipelineJob('Platform/Validation/release-agent-smoke') {
    description('Validates the dedicated Release Agent, TLS DIND, and authenticated local Registry without publishing an image.')
    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
    agent { label 'xhsmedium-release' }
    options { skipDefaultCheckout(true); timeout(time: 3, unit: 'MINUTES') }
    environment { DOCKER_CONFIG = "${WORKSPACE}/.docker" }
    stages {
        stage('Release isolation') {
            steps {
                sh 'docker info >/dev/null && test ! -e /var/run/docker.sock && test "$LOCAL_REGISTRY" = registry:5000'
                withCredentials([usernamePassword(credentialsId: 'registry-xhsmedium-push', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh 'set +x; mkdir -p "$DOCKER_CONFIG"; printf "%s" "$REGISTRY_PASSWORD" | docker --config "$DOCKER_CONFIG" login "$LOCAL_REGISTRY" --username "$REGISTRY_USER" --password-stdin >/dev/null'
                }
                echo 'RELEASE_AGENT_OK'
            }
        }
    }
    post { always { sh 'docker --config "$DOCKER_CONFIG" logout "$LOCAL_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "$DOCKER_CONFIG"'; deleteDir() } }
}

'''.stripIndent())
        }
    }
    logRotator { numToKeep(10) }
}

['dev', 'test'].each { environmentName ->
    pipelineJob("Platform/Validation/deploy-${environmentName}-agent-smoke") {
        description("Validates the isolated ${environmentName} Deploy Agent, TLS DIND, and authenticated Registry pull access without deploying an application.")
        definition {
            cps {
                sandbox(true)
                script("""
pipeline {
    agent { label 'xhsmedium-deploy-${environmentName}' }
    options { skipDefaultCheckout(true); timeout(time: 3, unit: 'MINUTES') }
    environment { DOCKER_CONFIG = "\${WORKSPACE}/.docker" }
    stages {
        stage('Deploy target isolation') {
            steps {
                sh 'docker info >/dev/null && docker compose version && test ! -e /var/run/docker.sock && test "\$LOCAL_REGISTRY" = registry:5000 && test "\$DEPLOY_ENVIRONMENT" = ${environmentName}'
                withCredentials([usernamePassword(credentialsId: 'registry-xhsmedium-push', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh 'set +x; mkdir -p "\$DOCKER_CONFIG"; printf "%s" "\$REGISTRY_PASSWORD" | docker --config "\$DOCKER_CONFIG" login "\$LOCAL_REGISTRY" --username "\$REGISTRY_USER" --password-stdin >/dev/null'
                }
                echo 'DEPLOY_${environmentName.toUpperCase()}_AGENT_OK'
            }
        }
    }
    post { always { sh 'docker --config "\$DOCKER_CONFIG" logout "\$LOCAL_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "\$DOCKER_CONFIG"'; deleteDir() } }
}
""".stripIndent())
            }
        }
        logRotator { numToKeep(10) }
    }
}
