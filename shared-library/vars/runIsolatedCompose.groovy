def call(Map config = [:], Closure body = null) {
    String runId = config.runId?.toString()?.trim()
    String composeFile = config.composeFile?.toString()?.trim()
    if (!(runId ==~ /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/)) {
        error('runIsolatedCompose requires a safe runId of at most 63 characters')
    }
    if (!composeFile) {
        error('runIsolatedCompose requires composeFile')
    }

    String project = "jenkins-${runId}".toLowerCase()
    withEnv(["COMPOSE_PROJECT_NAME=${project}"]) {
        try {
            sh "docker compose -f '${composeFile}' up --detach --wait"
            if (body != null) {
                body()
            }
        } finally {
            sh "docker compose -f '${composeFile}' down --volumes --remove-orphans"
        }
    }
}
