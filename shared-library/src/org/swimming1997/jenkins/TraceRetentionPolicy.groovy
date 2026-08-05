package org.swimming1997.jenkins

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
        List<Map> normalized = []
        for (Map build : builds) {
            File root = build.artifactsRoot as File
            normalized.add([
                number: (build.number as Number).longValue(),
                result: build.result?.toString(),
                timestamp: (build.timestamp as Number).longValue(),
                keepLog: build.keepLog == true,
                artifactsRoot: root,
                traceFiles: findTraceFiles(root)
            ])
        }

        List<Map> eligibleTraces = []
        for (Map build : normalized) {
            long age = nowMillis - (build.timestamp as Long)
            if (!build.keepLog && FAILURE_RESULTS.contains(build.result) && age >= 0L && age <= MAX_AGE_MILLIS) {
                for (File trace : build.traceFiles as List<File>) {
                    eligibleTraces.add([number: build.number, timestamp: build.timestamp, trace: trace])
                }
            }
        }
        sortTraceEntries(eligibleTraces)
        Set<String> retainedTracePaths = [] as Set
        int retainedLimit = Math.min(MAX_FAILURE_TRACES, eligibleTraces.size())
        for (int index = 0; index < retainedLimit; index++) {
            retainedTracePaths.add((eligibleTraces[index].trace as File).canonicalPath)
        }

        long removedBytes = 0L
        int removedTraces = 0
        int retainedTraces = 0
        int pinnedTraces = 0
        for (Map build : normalized) {
            if (build.keepLog) {
                pinnedTraces += build.traceFiles.size()
            } else {
                for (File trace : build.traceFiles as List<File>) {
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
        }

        List<Long> retainedFailureBuilds = []
        for (int index = 0; index < retainedLimit; index++) {
            Long number = eligibleTraces[index].number as Long
            if (!retainedFailureBuilds.contains(number)) {
                retainedFailureBuilds.add(number)
            }
        }
        if (retainedFailureBuilds.size() == 2 && retainedFailureBuilds[0] > retainedFailureBuilds[1]) {
            Long first = retainedFailureBuilds[0]
            retainedFailureBuilds[0] = retainedFailureBuilds[1]
            retainedFailureBuilds[1] = first
        }

        return [
            removedTraces: removedTraces,
            removedBytes: removedBytes,
            retainedTraces: retainedTraces,
            pinnedTraces: pinnedTraces,
            retainedFailureBuilds: retainedFailureBuilds
        ]
    }

    private static void sortTraceEntries(List<Map> entries) {
        for (int index = 1; index < entries.size(); index++) {
            Map current = entries[index]
            int position = index - 1
            while (position >= 0 && compareTraceEntries(current, entries[position]) < 0) {
                entries[position + 1] = entries[position]
                position--
            }
            entries[position + 1] = current
        }
    }

    private static int compareTraceEntries(Map left, Map right) {
        long leftTimestamp = left.timestamp as Long
        long rightTimestamp = right.timestamp as Long
        if (leftTimestamp != rightTimestamp) {
            return leftTimestamp > rightTimestamp ? -1 : 1
        }
        long leftNumber = left.number as Long
        long rightNumber = right.number as Long
        if (leftNumber != rightNumber) {
            return leftNumber > rightNumber ? -1 : 1
        }
        return (left.trace as File).path.compareTo((right.trace as File).path)
    }

    static List<File> findTraceFiles(File artifactsRoot) {
        if (artifactsRoot == null || !artifactsRoot.isDirectory()) {
            return []
        }
        Path rootPath = artifactsRoot.canonicalFile.toPath()
        List<File> traces = []
        List<File> pending = [artifactsRoot]
        while (!pending.isEmpty()) {
            File directory = pending.remove(pending.size() - 1)
            File[] children = directory.listFiles()
            if (children == null) {
                throw new IllegalStateException("Could not list Artifact directory: ${directory}")
            }
            for (File candidate : children) {
                Path candidatePath = candidate.canonicalFile.toPath()
                if (!candidatePath.startsWith(rootPath)) {
                    throw new IllegalStateException("Trace candidate escapes Artifact root: ${candidate}")
                }
                if (candidate.isDirectory()) {
                    pending.add(candidate)
                } else if (candidate.isFile()) {
                    String relative = rootPath.relativize(candidatePath).toString().replace('\\', '/')
                    if (TRACE_PATH.matcher(relative).matches()) {
                        traces.add(candidate)
                    }
                }
            }
        }
        for (int index = 1; index < traces.size(); index++) {
            File current = traces[index]
            int position = index - 1
            while (position >= 0 && current.path.compareTo(traces[position].path) < 0) {
                traces[position + 1] = traces[position]
                position--
            }
            traces[position + 1] = current
        }
        return traces
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
