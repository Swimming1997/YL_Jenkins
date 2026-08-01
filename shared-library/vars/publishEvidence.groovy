def call(Map config = [:]) {
    if (config.junitPattern) {
        junit testResults: config.junitPattern.toString(), allowEmptyResults: false
    }
    if (config.artifactPattern) {
        archiveArtifacts artifacts: config.artifactPattern.toString(), allowEmptyArchive: false, fingerprint: true
    }
}
