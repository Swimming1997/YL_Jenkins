def call(Map config = [:]) {
    String url = config.url?.toString()?.trim()
    String sha = config.sha?.toString()?.trim()
    if (!url) {
        error('platformCheckout requires url')
    }
    if (!(sha ==~ /(?i)[0-9a-f]{40}/)) {
        error('platformCheckout requires a full 40-character Git SHA')
    }

    Map remote = [url: url]
    if (config.credentialsId) {
        remote.credentialsId = config.credentialsId.toString()
    }

    checkout([
        $class: 'GitSCM',
        branches: [[name: sha]],
        doGenerateSubmoduleConfigurations: false,
        extensions: [[$class: 'CloneOption', shallow: false, noTags: false]],
        userRemoteConfigs: [remote]
    ])
}
