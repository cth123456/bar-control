import XCTest
@testable import CodexTouchBarNative

final class CCSwitchProviderStoreTests: XCTestCase {
    func testAddsCustomAliasForOfficialProvider() throws {
        let source = """
        model = "gpt-5.6-sol"
        model_provider = "cc-switch-official"

        [desktop]
        followUpQueueMode = "steer"

        [model_providers.cc-switch-official]
        name = "OpenAI"
        requires_openai_auth = true
        supports_websockets = false
        wire_api = "responses"
        base_url = "http://127.0.0.1:15721/v1"
        """ + "\n"

        let patched = try CCSwitchProviderStore.compatibilityPatchedConfig(source)

        XCTAssertEqual(patched.activeProviderID, "cc-switch-official")
        XCTAssertTrue(patched.text.contains("[model_providers.custom]"))
        XCTAssertEqual(
            patched.text.components(separatedBy: "base_url = \"http://127.0.0.1:15721/v1\"").count - 1,
            2
        )
        XCTAssertEqual(
            try CCSwitchProviderStore.compatibilityPatchedConfig(patched.text).text,
            patched.text
        )
    }

    func testAddsOfficialAliasForDeepSeekProviderAndPreservesBearer() throws {
        let source = """
        model_provider = "custom"
        model = "deepseek-v4-flash-vision-exp"

        [model_providers.custom]
        name = "deepseek"
        base_url = "https://api.deepseek.com"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "local-secret-placeholder"
        """ + "\n"

        let patched = try CCSwitchProviderStore.compatibilityPatchedConfig(source)

        XCTAssertTrue(patched.text.contains("[model_providers.cc-switch-official]"))
        XCTAssertEqual(
            patched.text.components(separatedBy: "base_url = \"https://api.deepseek.com\"").count - 1,
            2
        )
        XCTAssertEqual(
            patched.text.components(separatedBy: "experimental_bearer_token = \"local-secret-placeholder\"").count - 1,
            2
        )
    }

    func testReplacesStaleCompatibilityAlias() throws {
        let source = """
        model_provider = "cc-switch-official"
        model = "gpt-5.6-sol"

        [model_providers.custom]
        name = "stale"
        base_url = "https://stale.invalid"
        wire_api = "responses"
        requires_openai_auth = true

        [model_providers.cc-switch-official]
        name = "OpenAI"
        base_url = "http://127.0.0.1:15721/v1"
        wire_api = "responses"
        requires_openai_auth = true
        """ + "\n"

        let patched = try CCSwitchProviderStore.compatibilityPatchedConfig(source)

        XCTAssertFalse(patched.text.contains("stale.invalid"))
        XCTAssertEqual(patched.text.components(separatedBy: "[model_providers.custom]").count - 1, 1)
    }

    func testRejectsMissingActiveProviderSection() {
        let source = """
        model_provider = "custom"
        model = "deepseek-v4-flash"
        """ + "\n"

        XCTAssertThrowsError(try CCSwitchProviderStore.compatibilityPatchedConfig(source))
    }
}
