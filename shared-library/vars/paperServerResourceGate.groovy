def call(Map config = [:]) {
    if (!env.PAPER_SERVER_RESOURCE_MODE?.equalsIgnoreCase('true')) {
        echo 'RESOURCE_GATE_EVIDENCE mode=disabled status=OK'
        return
    }

    String jenkinsUrl = (config.jenkinsUrl ?: env.JENKINS_INTERNAL_URL ?: 'http://controller:8080').toString().replaceAll('/+$', '')
    writeFile(file: '.paper-server-resource-gate.py', text: libraryResource('xhsmedium/paper-server-resource-gate.py'))
    try {
        withCredentials([usernamePassword(
            credentialsId: 'jenkins-audit-api',
            usernameVariable: 'RESOURCE_GATE_USER',
            passwordVariable: 'RESOURCE_GATE_PASSWORD'
        )]) {
            sh(
                'set +x; set -eu\n' +
                'auth="$RESOURCE_GATE_USER:$RESOURCE_GATE_PASSWORD"\n' +
                'attempt=1\n' +
                'while :; do\n' +
                '  curl --globoff --fail --silent --show-error -u "$auth" "' + jenkinsUrl + '/computer/(built-in)/api/json?depth=1" -o .resource-controller.json\n' +
                '  curl --globoff --fail --silent --show-error -u "$auth" "' + jenkinsUrl + '/computer/api/json?tree=computer[displayName,executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]]" -o .resource-executors.json\n' +
                '  set +e\n' +
                '  output=$(python3 .paper-server-resource-gate.py .resource-controller.json .resource-executors.json "$BUILD_URL" 2>&1)\n' +
                '  status=$?\n' +
                '  set -e\n' +
                '  if [ "$status" -eq 0 ]; then printf "%s\\n" "$output"; break; fi\n' +
                '  if [ "$status" -eq 77 ] && printf "%s\\n" "$output" | grep -q "reason=missing_disk_telemetry" && [ "$attempt" -lt 30 ]; then attempt=$((attempt + 1)); sleep 2; continue; fi\n' +
                '  printf "%s\\n" "$output" >&2\n' +
                '  exit "$status"\n' +
                'done\n'
            )
        }
    } finally {
        sh 'rm -f -- .paper-server-resource-gate.py .resource-controller.json .resource-executors.json'
    }
}
