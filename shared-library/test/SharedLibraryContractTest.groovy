import com.lesfurets.jenkins.unit.BasePipelineTest
import org.junit.Before
import org.junit.Test

class SharedLibraryContractTest extends BasePipelineTest {
    @Before
    void configure() {
        super.setUp()
        helper.registerAllowedMethod('error', [String]) { String message -> throw new IllegalArgumentException(message) }
    }

    @Test
    void identityIsStable() {
        def script = loadScript('vars/platformIdentity.groovy')
        assert script.call() == [name: 'jenkins-platform-library', apiVersion: 'v1']
    }

    @Test
    void checkoutRejectsShortSha() {
        def script = loadScript('vars/platformCheckout.groovy')
        try {
            script.call(url: 'https://example.invalid/repo.git', sha: 'abc123')
            fail('Expected invalid SHA to fail')
        } catch (IllegalArgumentException error) {
            assert error.message.contains('40-character')
        }
    }

    @Test
    void timeoutInvokesBody() {
        boolean invoked = false
        helper.registerAllowedMethod('timeout', [Map, Closure]) { Map ignored, Closure body -> body() }
        def script = loadScript('vars/withPipelineTimeout.groovy')
        script.call(minutes: 2) { invoked = true }
        assert invoked
    }

    @Test
    void cleanupDeletesWorkspace() {
        boolean deleted = false
        helper.registerAllowedMethod('deleteDir', []) { deleted = true }
        def script = loadScript('vars/cleanupWorkspace.groovy')
        script.call()
        assert deleted
    }

    @Test
    void gitRefValidationAcceptsSafeBranchAndFullSha() {
        def script = loadScript('vars/validateGitRef.groovy')
        String sha = 'a' * 40
        assert script.call(branch: 'feature/read-only_ci', sha: sha) == [branch: 'feature/read-only_ci', sha: sha]
    }

    @Test
    void gitRefValidationRejectsUnsafeBranch() {
        def script = loadScript('vars/validateGitRef.groovy')
        try {
            script.call(branch: 'dev; touch unsafe', sha: '')
            fail('Expected unsafe branch to fail')
        } catch (IllegalArgumentException error) {
            assert error.message.contains('safe Git branch')
        }
    }

    @Test
    void nodeModuleCiRunsInsideRequestedDirectory() {
        String selectedDirectory = null
        Map shellCall = null
        Map written = null
        helper.registerAllowedMethod('dir', [String, Closure]) { String directory, Closure body ->
            selectedDirectory = directory
            body()
        }
        helper.registerAllowedMethod('libraryResource', [String]) { String resource -> "resource:${resource}" }
        helper.registerAllowedMethod('writeFile', [Map]) { Map arguments -> written = arguments }
        helper.registerAllowedMethod('sh', [Map]) { Map arguments -> shellCall = arguments }
        def script = loadScript('vars/nodeModuleCi.groovy')

        script.call(module: 'backend', logName: 'backend.log', commands: ['./.npm-ci-network-retry.sh', 'npm test'])

        assert selectedDirectory == 'backend'
        assert written == [file: '.npm-ci-network-retry.sh', text: 'resource:xhsmedium/npm-ci-network-retry.sh']
        assert shellCall.script.contains('./.npm-ci-network-retry.sh\nnpm test')
        assert shellCall.script.contains('ci-evidence/backend.log')
        assert shellCall.script.contains('chmod 0700 .npm-ci-network-retry.sh')
        assert shellCall.script.contains('trap cleanup_node_modules EXIT')
        assert shellCall.script.contains('rm -rf -- node_modules')
        assert shellCall.script.contains('rm -f -- .npm-ci-network-retry.sh')
    }

    @Test
    void npmCiRetryHelperIsBoundedToTransientNetworkFailures() {
        String retryHelper = new File('resources/xhsmedium/npm-ci-network-retry.sh').text

        assert retryHelper.contains('max_attempts=3')
        assert retryHelper.contains('npm ci "$@"')
        assert retryHelper.contains('ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|ECONNREFUSED|ERR_SOCKET_TIMEOUT')
        assert retryHelper.contains('NPM_CI_NETWORK_RETRY')
        assert retryHelper.contains('exit "$status"')
        assert !retryHelper.contains('registry.npmmirror.com')
    }

    @Test
    void buildMetadataRecordsNonReleaseIdentity() {
        Map written = null
        binding.setVariable('env', [BUILD_NUMBER: '7', BUILD_ID: '20260801', BUILD_URL: 'http://jenkins/job/7/'])
        helper.registerAllowedMethod('validateGitRef', [Map]) { Map arguments -> arguments }
        helper.registerAllowedMethod('writeFile', [Map]) { Map arguments -> written = arguments }
        def script = loadScript('vars/recordBuildMetadata.groovy')

        script.call(
            repository: 'https://github.com/MuFannnn/xhsmedium.git',
            branch: 'dev',
            sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            output: 'ci-evidence/build-metadata.txt'
        )

        assert written.file == 'ci-evidence/build-metadata.txt'
        assert written.text.contains('sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
        assert written.text.contains('release_eligible=false')
        assert written.text.contains('backend_lint=omitted_mutating_command')
    }

    @Test
    void scmPollingUsesValidatedBaselineOnFirstRun() {
        def script = loadScript('vars/scmChangeDecision.groovy')
        String sha = '1111111111111111111111111111111111111111'

        assert script.call(remoteSha: sha, baselineSha: sha, previousDescription: '').changed == false
        assert script.call(remoteSha: '2222222222222222222222222222222222222222', baselineSha: sha, previousDescription: '').changed == true
    }

    @Test
    void scmPollingUsesPreviousObservedShaAfterFirstRun() {
        def script = loadScript('vars/scmChangeDecision.groovy')
        String baseline = '1111111111111111111111111111111111111111'
        String observed = '2222222222222222222222222222222222222222'

        def unchanged = script.call(remoteSha: observed, baselineSha: baseline, previousDescription: "SHA=${observed}")
        def changed = script.call(remoteSha: '3333333333333333333333333333333333333333', baselineSha: baseline, previousDescription: "SHA=${observed}")

        assert unchanged == [changed: false, remoteSha: observed, lastSeenSha: observed, source: 'previous-build']
        assert changed.changed == true
        assert changed.lastSeenSha == observed
    }
}
