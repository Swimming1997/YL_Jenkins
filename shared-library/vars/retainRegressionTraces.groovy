import org.swimming1997.jenkins.TraceRetentionPolicy

def call(Map config = [:]) {
    String expectedJob = 'XHSMedium/Regression/scheduled'
    String jobName = env.JOB_NAME?.toString()
    if (jobName != expectedJob) {
        error("Trace retention is restricted to ${expectedJob}")
    }
    if (!(env.BUILD_NUMBER ==~ /[1-9][0-9]*/)) {
        error('Trace retention requires a positive BUILD_NUMBER')
    }

    Class jenkinsClass = this.class.classLoader.loadClass('jenkins.model.Jenkins')
    Object jenkins = jenkinsClass.getMethod('get').invoke(null)
    Object job = jenkins.getItemByFullName(expectedJob)
    if (job == null) {
        error("Trace retention Job was not found: ${expectedJob}")
    }

    long currentNumber = env.BUILD_NUMBER.toLong()
    String currentResult = (config.result ?: currentBuild.currentResult ?: 'FAILURE').toString()
    List<Map> builds = job.getBuilds().findAll { Object build ->
        !build.isBuilding() || build.getNumber() == currentNumber
    }.collect { Object build ->
        [
            number: build.getNumber(),
            result: build.getNumber() == currentNumber ? currentResult : build.getResult()?.toString(),
            timestamp: build.getStartTimeInMillis(),
            keepLog: build.isKeepLog(),
            artifactsRoot: build.getArtifactsDir()
        ]
    }

    Map evidence = TraceRetentionPolicy.apply(builds, System.currentTimeMillis())
    echo "TRACE_RETENTION_EVIDENCE job=${expectedJob} removed_traces=${evidence.removedTraces} " +
        "removed_bytes=${evidence.removedBytes} retained_traces=${evidence.retainedTraces} " +
        "pinned_traces=${evidence.pinnedTraces} status=OK"
    return evidence
}
