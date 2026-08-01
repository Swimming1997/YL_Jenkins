def call(Map config = [:]) {
    String branch = config.branch?.toString()?.trim()
    String sha = config.sha?.toString()?.trim()

    if (!branch || branch.length() > 128 || !(branch ==~ /[A-Za-z0-9][A-Za-z0-9._\/-]*/)) {
        error('BRANCH must be a safe Git branch name of at most 128 characters')
    }
    if (branch.contains('..') || branch.contains('//') || branch.contains('@{') ||
        branch.endsWith('/') || branch.endsWith('.') || branch.endsWith('.lock')) {
        error('BRANCH contains a prohibited Git ref sequence')
    }
    if (sha && !(sha ==~ /(?i)[0-9a-f]{40}/)) {
        error('GIT_SHA must be empty or a full 40-character Git SHA')
    }

    return [branch: branch, sha: sha]
}
