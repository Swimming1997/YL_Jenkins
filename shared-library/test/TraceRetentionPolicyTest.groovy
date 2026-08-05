import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.swimming1997.jenkins.TraceRetentionPolicy

class TraceRetentionPolicyTest {
    @Rule
    public TemporaryFolder temporary = new TemporaryFolder()

    private Map build(long number, String result, long timestamp, boolean keepLog = false) {
        File root = temporary.newFolder("build-${number}")
        File trace = new File(root, "artifacts/test-runs/run-${number}/playwright-report/data/trace-${number}.zip")
        trace.parentFile.mkdirs()
        trace.bytes = new byte[(int) number]
        File summary = new File(root, "artifacts/test-runs/run-${number}/summary.json")
        summary.parentFile.mkdirs()
        summary.text = '{"status":"preserved"}'
        return [number: number, result: result, timestamp: timestamp, keepLog: keepLog, artifactsRoot: root, trace: trace, summary: summary]
    }

    @Test
    void keepsOnlyTwoNewestFailureTracesAndPreservesJson() {
        long now = 1_800_000_000_000L
        Map oldest = build(1, 'FAILURE', now - 3000)
        Map middle = build(2, 'ABORTED', now - 2000)
        Map newest = build(3, 'UNSTABLE', now - 1000)

        Map evidence = TraceRetentionPolicy.apply([oldest, newest, middle], now)

        assert !oldest.trace.exists()
        assert middle.trace.exists()
        assert newest.trace.exists()
        assert [oldest, middle, newest].every { it.summary.exists() }
        assert evidence.removedTraces == 1
        assert evidence.retainedFailureBuilds == [2L, 3L]
    }

    @Test
    void removesExpiredAndSuccessfulTraces() {
        long now = 1_800_000_000_000L
        Map expired = build(4, 'FAILURE', now - TraceRetentionPolicy.MAX_AGE_MILLIS - 1)
        Map successful = build(5, 'SUCCESS', now - 1000)

        Map evidence = TraceRetentionPolicy.apply([expired, successful], now)

        assert !expired.trace.exists()
        assert !successful.trace.exists()
        assert expired.summary.exists() && successful.summary.exists()
        assert evidence.removedTraces == 2
    }

    @Test
    void pinnedTraceIsExemptFromAutomaticDeletion() {
        long now = 1_800_000_000_000L
        Map pinned = build(6, 'FAILURE', now - TraceRetentionPolicy.MAX_AGE_MILLIS - 1, true)

        Map evidence = TraceRetentionPolicy.apply([pinned], now)

        assert pinned.trace.exists()
        assert evidence.pinnedTraces == 1
        assert evidence.removedTraces == 0
    }

    @Test
    void retainsAtMostTwoTraceFilesEvenWithinOneFailureBuild() {
        long now = 1_800_000_000_000L
        Map newest = build(8, 'FAILURE', now - 1000)
        File second = new File(newest.artifactsRoot as File, 'artifacts/test-runs/run-8/playwright-report/data/trace-8b.zip')
        second.text = 'second'
        File third = new File(newest.artifactsRoot as File, 'artifacts/test-runs/run-8/playwright-report/data/trace-8c.zip')
        third.text = 'third'

        Map evidence = TraceRetentionPolicy.apply([newest], now)

        assert evidence.retainedTraces == 2
        assert evidence.removedTraces == 1
        assert TraceRetentionPolicy.findTraceFiles(newest.artifactsRoot as File).size() == 2
        assert newest.summary.exists()
    }

    @Test
    void ignoresZipFilesOutsideExactPlaywrightTracePath() {
        File root = temporary.newFolder('unrelated')
        File unrelated = new File(root, 'artifacts/test-runs/run-7/screenshots/evidence.zip')
        unrelated.parentFile.mkdirs()
        unrelated.text = 'keep'

        assert TraceRetentionPolicy.findTraceFiles(root).isEmpty()
        assert unrelated.exists()
    }
}
