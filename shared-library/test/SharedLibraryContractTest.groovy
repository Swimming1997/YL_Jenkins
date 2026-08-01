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
}
