import groovy.json.JsonOutput

def call(Map config = [:]) {
    if (!env.PAPER_SERVER_RESOURCE_MODE?.equalsIgnoreCase('true')) {
        echo 'RESOURCE_GATE_EVIDENCE mode=disabled status=OK'
        return
    }

    String jenkinsUrl = (config.jenkinsUrl ?: env.JENKINS_INTERNAL_URL ?: 'http://controller:8080').toString().replaceAll('/+$', '')
    File jenkinsHome = new File('/var/jenkins_home')
    if (!jenkinsHome.isDirectory()) {
        error('RESOURCE_GATE_INVALID reason=missing_jenkins_home')
    }
    long availableBytes = jenkinsHome.usableSpace
    if (availableBytes <= 0L) {
        error('RESOURCE_GATE_INVALID reason=invalid_jenkins_home_space')
    }
    writeFile(file: '.paper-server-resource-gate.py', text: libraryResource('xhsmedium/paper-server-resource-gate.py'))
    writeFile(file: '.resource-controller.json', text: JsonOutput.toJson([
        monitorData: [
            'hudson.node_monitors.DiskSpaceMonitor': [path: '/var/jenkins_home', size: availableBytes]
        ]
    ]))
    try {
        withCredentials([usernamePassword(
            credentialsId: 'jenkins-audit-api',
            usernameVariable: 'RESOURCE_GATE_USER',
            passwordVariable: 'RESOURCE_GATE_PASSWORD'
        )]) {
            sh(
                'set +x; set -eu\n' +
                'auth="$RESOURCE_GATE_USER:$RESOURCE_GATE_PASSWORD"\n' +
                'curl --globoff --fail --silent --show-error -u "$auth" "' + jenkinsUrl + '/computer/api/json?tree=computer[displayName,executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]]" -o .resource-executors.json\n' +
                'python3 .paper-server-resource-gate.py .resource-controller.json .resource-executors.json "$BUILD_URL"\n'
            )
        }
    } finally {
        sh 'rm -f -- .paper-server-resource-gate.py .resource-controller.json .resource-executors.json'
    }
}
