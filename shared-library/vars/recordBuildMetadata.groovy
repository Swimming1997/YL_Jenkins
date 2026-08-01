def call(Map config = [:]) {
    String repository = config.repository?.toString()?.trim()
    String branch = config.branch?.toString()?.trim()
    String sha = config.sha?.toString()?.trim()
    String output = config.output?.toString()?.trim() ?: 'ci-evidence/build-metadata.txt'

    if (repository != 'https://github.com/MuFannnn/xhsmedium.git') {
        error('recordBuildMetadata accepts only the fixed XHSMedium repository')
    }
    def ref = validateGitRef(branch: branch, sha: sha)
    if (!(output ==~ /ci-evidence\/[A-Za-z0-9._-]+\.txt/)) {
        error('recordBuildMetadata output must be a safe ci-evidence text path')
    }

    writeFile(
        file: output,
        text: [
            "repository=${repository}",
            "branch=${ref.branch}",
            "sha=${ref.sha}",
            "build_number=${env.BUILD_NUMBER}",
            "build_id=${env.BUILD_ID}",
            "build_url=${env.BUILD_URL}",
            'release_eligible=false',
            'backend_lint=omitted_mutating_command'
        ].join('\n') + '\n'
    )
}
