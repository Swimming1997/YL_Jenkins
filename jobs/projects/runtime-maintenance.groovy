def maintenanceTargets = [
    regression: [label: 'xhsmedium-regression', managesDependencyCaches: true],
    release: [label: 'xhsmedium-release', managesDependencyCaches: false],
    'deploy-dev': [label: 'xhsmedium-deploy-dev', managesDependencyCaches: false],
    'deploy-test': [label: 'xhsmedium-deploy-test', managesDependencyCaches: false]
]

maintenanceTargets.each { targetName, config ->
    def pipelineSource = '''
@Library('jenkins-platform-library') _

pipeline {
    agent { label '__MAINTENANCE_LABEL__' }
    environment {
        JENKINS_INTERNAL_URL = 'http://controller:8080'
        DIND_MAINTENANCE_TARGET = '__MAINTENANCE_TARGET__'
        DIND_MANAGES_DEPENDENCY_CACHES = '__MANAGES_DEPENDENCY_CACHES__'
        DIND_CACHE_LIMIT_BYTES = '4294967296'
    }
    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds(abortPrevious: false)
        timeout(time: 15, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }
    stages {
        stage('Validate request') {
            steps {
                script {
                    if (!(params.MODE in ['AUDIT', 'APPLY'])) { error('MODE must be AUDIT or APPLY') }
                    if (params.MODE == 'APPLY' && params.CONFIRMATION?.trim() != 'APPLY_DEDICATED_DIND_MAINTENANCE') {
                        error('APPLY requires the exact maintenance confirmation')
                    }
                    env.CURRENT_VALIDATED_SHA = params.CURRENT_VALIDATED_SHA?.trim() ?: ''
                    env.PREVIOUS_VALIDATED_SHA = params.PREVIOUS_VALIDATED_SHA?.trim() ?: ''
                    if (env.DIND_MANAGES_DEPENDENCY_CACHES == 'true') {
                        if (!(env.CURRENT_VALIDATED_SHA ==~ /[0-9a-f]{40}/)) { error('CURRENT_VALIDATED_SHA must be a full lowercase SHA') }
                        if (env.PREVIOUS_VALIDATED_SHA && !(env.PREVIOUS_VALIDATED_SHA ==~ /[0-9a-f]{40}/)) { error('PREVIOUS_VALIDATED_SHA must be blank or a full lowercase SHA') }
                        if (env.PREVIOUS_VALIDATED_SHA == env.CURRENT_VALIDATED_SHA) { error('Current and previous validated SHAs must differ') }
                    } else if (env.CURRENT_VALIDATED_SHA || env.PREVIOUS_VALIDATED_SHA) {
                        error('SHA retention parameters are accepted only by Regression maintenance')
                    }
                    currentBuild.description = "${env.DIND_MAINTENANCE_TARGET} ${params.MODE}"
                }
            }
        }
        stage('Verify idle Jenkins and validated SHAs') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'jenkins-audit-api', usernameVariable: 'JENKINS_API_USER', passwordVariable: 'JENKINS_API_PASSWORD')]) {
                    sh(
                        'set +x; set -eu\\n' +
                        'auth="$JENKINS_API_USER:$JENKINS_API_PASSWORD"\\n' +
                        'if [ "$MODE" = APPLY ]; then\\n' +
                        '  curl --globoff --fail --silent --show-error -u "$auth" "$JENKINS_INTERNAL_URL/queue/api/json?tree=items[id,task[fullDisplayName]]" -o queue.json\\n' +
                        '  curl --globoff --fail --silent --show-error -u "$auth" "$JENKINS_INTERNAL_URL/computer/api/json?tree=computer[displayName,executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]]" -o executors.json\\n' +
                        '  python3 -c "import json,os; q=json.load(open(\\\'queue.json\\\')); assert not q.get(\\\'items\\\'), \\\'JENKINS_QUEUE_NOT_EMPTY\\\'; data=json.load(open(\\\'executors.json\\\')); active=[e[\\\'currentExecutable\\\'][\\\'url\\\'] for c in data[\\\'computer\\\'] for e in c.get(\\\'executors\\\',[])+c.get(\\\'oneOffExecutors\\\',[]) if e.get(\\\'currentExecutable\\\')]; own=os.environ[\\\'BUILD_URL\\\'].rstrip(\\\'/\\\'); assert all(url.rstrip(\\\'/\\\')==own for url in active), \\\'OTHER_JENKINS_BUILD_RUNNING\\\'"\\n' +
                        'fi\\n' +
                        'if [ "$DIND_MANAGES_DEPENDENCY_CACHES" = true ]; then\\n' +
                        '  curl --globoff --fail --silent --show-error -u "$auth" "$JENKINS_INTERNAL_URL/job/XHSMedium/job/Regression/job/scheduled/api/json?tree=builds[number,result,actions[parameters[name,value]]]{0,30}" -o regression-builds.json\\n' +
                        '  python3 -c "import json,os,re; builds=json.load(open(\\\'regression-builds.json\\\'))[\\\'builds\\\']; seen=[]; [seen.append(v) for b in builds if b.get(\\\'result\\\')==\\\'SUCCESS\\\' for a in b.get(\\\'actions\\\',[]) for p in a.get(\\\'parameters\\\',[]) if p.get(\\\'name\\\')==\\\'GIT_SHA\\\' and isinstance((v:=p.get(\\\'value\\\')),str) and re.fullmatch(r\\\'[0-9a-f]{40}\\\',v) and v not in seen]; current=os.environ[\\\'CURRENT_VALIDATED_SHA\\\']; previous=os.environ.get(\\\'PREVIOUS_VALIDATED_SHA\\\',\\\'\\\'); assert seen and current==seen[0], \\\'CURRENT_SHA_NOT_LATEST_VALIDATED\\\'; expected=seen[1] if len(seen)>1 else \\\'\\\'; assert previous==expected, \\\'PREVIOUS_SHA_NOT_VALIDATED_WINDOW\\\'"\\n' +
                        'fi\\n'
                    )
                }
            }
        }
        stage('Audit or maintain dedicated DIND') {
            steps {
                script {
                    writeFile(file: '.docker-dind-maintenance.sh', text: libraryResource('xhsmedium/docker-dind-maintenance.sh'))
                }
                sh(
                    'set -eu\\n' +
                    'chmod 700 .docker-dind-maintenance.sh\\n' +
                    './.docker-dind-maintenance.sh "$DIND_MAINTENANCE_TARGET" "$MODE" "${CURRENT_VALIDATED_SHA:-}" "${PREVIOUS_VALIDATED_SHA:-}" "${CONFIRMATION:-}"\\n'
                )
            }
        }
    }
    post {
        always {
            sh 'rm -f .docker-dind-maintenance.sh queue.json executors.json regression-builds.json'
            script {
                def maintenanceTmp = "${env.WORKSPACE}@tmp"
                if (!(maintenanceTmp ==~ /\/home\/jenkins\/agent\/workspace\/Platform\/Maintenance\/dind-(regression|release|deploy-dev|deploy-test)@tmp/)) {
                    error("Refusing unsafe Maintenance temporary cleanup path: ${maintenanceTmp}")
                }
                dir(maintenanceTmp) { deleteDir() }
            }
            deleteDir()
        }
    }
}
'''.stripIndent()
        .replace('__MAINTENANCE_LABEL__', config.label)
        .replace('__MAINTENANCE_TARGET__', targetName)
        .replace('__MANAGES_DEPENDENCY_CACHES__', config.managesDependencyCaches.toString())

    pipelineJob("Platform/Maintenance/dind-${targetName}") {
        description("Audits or explicitly maintains only the isolated ${targetName} DIND. APPLY fails closed unless Jenkins is idle and the target has no running containers.")
        parameters {
            choiceParam('MODE', ['AUDIT', 'APPLY'], 'AUDIT is read-only. APPLY performs exact old-cache deletion and bounded BuildKit maintenance.')
            stringParam('CONFIRMATION', '', 'APPLY only: enter APPLY_DEDICATED_DIND_MAINTENANCE exactly.')
            stringParam('CURRENT_VALIDATED_SHA', '', 'Regression only: latest successful full SHA retained in the dependency-cache window.')
            stringParam('PREVIOUS_VALIDATED_SHA', '', 'Regression only: previous distinct successful full SHA retained in the dependency-cache window; blank only when none exists.')
        }
        definition {
            cps {
                sandbox(true)
                script(pipelineSource)
            }
        }
        logRotator { numToKeep(20) }
        disabled(false)
    }
}
