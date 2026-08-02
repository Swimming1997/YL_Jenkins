def call(Map config = [:]) {
    String remoteSha = config.remoteSha?.toString()?.trim()?.toLowerCase()
    String baselineSha = config.baselineSha?.toString()?.trim()?.toLowerCase()
    String previousDescription = config.previousDescription?.toString()?.trim() ?: ''

    if (!(remoteSha ==~ /[0-9a-f]{40}/)) {
        error('scmChangeDecision requires a full remote SHA')
    }
    if (!(baselineSha ==~ /[0-9a-f]{40}/)) {
        error('scmChangeDecision requires a full baseline SHA')
    }

    String previousSha = ''
    if (previousDescription.startsWith('SHA=') && previousDescription.length() >= 44) {
        String candidate = previousDescription.substring(4, 44).toLowerCase()
        if (candidate ==~ /[0-9a-f]{40}/) {
            previousSha = candidate
        }
    }

    String lastSeenSha = previousSha ?: baselineSha
    return [
        changed: remoteSha != lastSeenSha,
        remoteSha: remoteSha,
        lastSeenSha: lastSeenSha,
        source: previousSha ? 'previous-build' : 'baseline'
    ]
}
