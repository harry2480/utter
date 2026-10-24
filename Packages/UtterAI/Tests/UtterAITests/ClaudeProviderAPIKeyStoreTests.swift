import Foundation
import Testing
import UtterCore

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct ClaudeProviderAPIKeyStoreTests {
  private typealias StubTransport = ClaudeProviderTests.StubTransport

  private let request = RefinementRequest(text: "えーと明日の会議です", mode: .natural)
  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! ClaudeProvider.Configuration(model: "test-model")

  private func provider(_ store: StubAPIKeyStore, _ transport: StubTransport) -> ClaudeProvider {
    ClaudeProvider(apiKeyStore: store, configuration: configuration, transport: transport)
  }

  private func successTransport() -> StubTransport {
    StubTransport(.response(status: 200, body: ClaudeProviderTests.successBody))
  }

  @Test("AC-12: 保存先のキーを整形のたびに読み出して送る")
  func readsKeyForEachRequest() async throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-first"))
    let transport = successTransport()
    let provider = provider(store, transport)

    _ = try await provider.refine(request)
    try store.save(try APIKey("sk-ant-second"))
    _ = try await provider.refine(request)

    let keys = transport.requests.withLock { $0.map { $0.value(forHTTPHeaderField: "x-api-key") } }
    #expect(keys == ["sk-ant-first", "sk-ant-second"])
  }

  @Test("AC-12: キーが未設定なら送信せずに authenticationExpired を投げる")
  func missingKeyDoesNotSend() async {
    let transport = successTransport()

    await #expect(throws: AIProviderError.authenticationExpired) {
      try await provider(StubAPIKeyStore(), transport).refine(request)
    }
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("AC-12: キーを読み出せなければ送信せずに authenticationExpired を投げる")
  func unreadableKeyDoesNotSend() async throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-first"))
    store.setFailure(.operationFailed(code: -25308), for: .load)
    let transport = successTransport()

    await #expect(throws: AIProviderError.authenticationExpired) {
      try await provider(store, transport).refine(request)
    }
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("AC-12: Raw モードはキーを読み出さない")
  func rawDoesNotReadKey() async throws {
    let store = StubAPIKeyStore()

    let response = try await provider(store, successTransport())
      .refine(RefinementRequest(text: "えー", mode: .raw))

    #expect(response.text == "えー")
    #expect(store.calls.isEmpty)
  }

  @Test("AC-12: 文字列表現に保存先のキーを出さない")
  func descriptionHidesKey() throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-secret-value"))
    let provider = provider(store, successTransport())

    #expect(!String(describing: provider).contains("secret"))
    #expect(!String(reflecting: provider).contains("secret"))
  }

  @Test("AC-12: 固定のキーで作っても文字列表現とリフレクションにキーを出さない")
  func descriptionHidesFixedKey() {
    let provider = ClaudeProvider(
      apiKey: "sk-ant-secret-value", configuration: configuration, transport: successTransport())

    #expect(!String(describing: provider).contains("secret"))
    #expect(!String(reflecting: provider).contains("secret"))
    var dumped = ""
    dump(provider, to: &dumped)
    #expect(!dumped.contains("secret"))
  }
}
