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
        helper.registerAllowedMethod('dir', [String, Closure]) { String directory, Closure body ->
            selectedDirectory = directory
            body()
        }
        helper.registerAllowedMethod('sh', [Map]) { Map arguments -> shellCall = arguments }
        def script = loadScript('vars/nodeModuleCi.groovy')

        script.call(module: 'backend', logName: 'backend.log', commands: ['npm ci', 'npm test'])

        assert selectedDirectory == 'backend'
        assert shellCall.script.contains('npm ci\nnpm test')
        assert shellCall.script.contains('ci-evidence/backend.log')
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
}
