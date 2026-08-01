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

