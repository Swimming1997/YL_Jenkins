package org.swimming1997.jenkins

import groovy.io.FileType

import java.nio.file.Path
import java.util.regex.Pattern

class TraceRetentionPolicy {
    static final long MAX_AGE_MILLIS = 7L * 24L * 60L * 60L * 1000L
    static final int MAX_FAILURE_TRACES = 2
    private static final Pattern TRACE_PATH = Pattern.compile(
        '^artifacts/test-runs/[^/]+/playwright[^/]*-report/data/[^/]+\\.zip$'
    )
    private static final Set<String> FAILURE_RESULTS = ['FAILURE', 'UNSTABLE', 'ABORTED'] as Set

    static Map apply(List<Map> builds, long nowMillis) {
        List<Map> normalized = builds.collect { Map build ->
            File root = build.artifactsRoot as File
            [
                number: (build.number as Number).longValue(),
                result: build.result?.toString(),
                timestamp: (build.timestamp as Number).longValue(),
                keepLog: build.keepLog == true,
                artifactsRoot: root,
                traceFiles: findTraceFiles(root)
            ]
        }

        List<Map> eligibleFailures = normalized.findAll { Map build ->
            !build.keepLog && FAILURE_RESULTS.contains(build.result) &&
                nowMillis - build.timestamp >= 0L && nowMillis - build.timestamp <= MAX_AGE_MILLIS &&
                !build.traceFiles.isEmpty()
        }.sort { Map left, Map right ->
            int timestampOrder = (right.timestamp as Long) <=> (left.timestamp as Long)
            timestampOrder != 0 ? timestampOrder : (right.number as Long) <=> (left.number as Long)
        }
        List<Map> eligibleTraces = eligibleFailures.collectMany { Map build ->
            build.traceFiles.collect { File trace ->
                [number: build.number, timestamp: build.timestamp, trace: trace]
            }
        }.sort { Map left, Map right ->
            int timestampOrder = (right.timestamp as Long) <=> (left.timestamp as Long)
            if (timestampOrder != 0) { return timestampOrder }
            int buildOrder = (right.number as Long) <=> (left.number as Long)
            buildOrder != 0 ? buildOrder : (left.trace as File).path <=> (right.trace as File).path
        }
        Set<String> retainedTracePaths = eligibleTraces.take(MAX_FAILURE_TRACES).collect {
            (it.trace as File).canonicalPath
        } as Set

        long removedBytes = 0L
        int removedTraces = 0
        int retainedTraces = 0
        int pinnedTraces = 0
        normalized.each { Map build ->
            if (build.keepLog) {
                pinnedTraces += build.traceFiles.size()
                return
            }
            build.traceFiles.each { File trace ->
                boolean retain = retainedTracePaths.contains(trace.canonicalPath)
                if (retain) {
                    retainedTraces++
                } else {
                    long bytes = trace.length()
                    deleteExactTrace(build.artifactsRoot as File, trace)
                    removedBytes += bytes
                    removedTraces++
                }
            }
        }

        return [
            removedTraces: removedTraces,
            removedBytes: removedBytes,
            retainedTraces: retainedTraces,
            pinnedTraces: pinnedTraces,
            retainedFailureBuilds: eligibleTraces.take(MAX_FAILURE_TRACES).collect { it.number as Long }.unique().sort()
        ]
    }

    static List<File> findTraceFiles(File artifactsRoot) {
        if (artifactsRoot == null || !artifactsRoot.isDirectory()) {
            return []
        }
        Path rootPath = artifactsRoot.canonicalFile.toPath()
        List<File> traces = []
        artifactsRoot.eachFileRecurse(FileType.FILES) { File candidate ->
            Path candidatePath = candidate.canonicalFile.toPath()
            if (!candidatePath.startsWith(rootPath)) {
                throw new IllegalStateException("Trace candidate escapes Artifact root: ${candidate}")
            }
            String relative = rootPath.relativize(candidatePath).toString().replace('\\', '/')
            if (TRACE_PATH.matcher(relative).matches()) {
                traces << candidate
            }
        }
        return traces.sort { it.path }
    }

    private static void deleteExactTrace(File artifactsRoot, File trace) {
        Path rootPath = artifactsRoot.canonicalFile.toPath()
        Path tracePath = trace.canonicalFile.toPath()
        String relative = rootPath.relativize(tracePath).toString().replace('\\', '/')
        if (!tracePath.startsWith(rootPath) || !TRACE_PATH.matcher(relative).matches()) {
            throw new IllegalStateException("Refusing unsafe trace deletion: ${trace}")
        }
        if (!trace.delete() && trace.exists()) {
            throw new IllegalStateException("Could not delete retained-policy trace: ${relative}")
        }
    }
}
