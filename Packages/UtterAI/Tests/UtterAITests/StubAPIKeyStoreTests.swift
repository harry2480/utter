import Testing

@testable import UtterAI

struct StubAPIKeyStoreTests {
  @Test("AC-12: 保存・読み出し・削除")
  func roundTrip() throws {
    let store = StubAPIKeyStore()
    #expect(try store.load() == nil)

    try store.save(try APIKey("sk-ant-1"))
    #expect(try store.load()?.value == "sk-ant-1")

    try store.delete()
    #expect(try store.load() == nil)
    // 未保存の削除も成功する
    try store.delete()
    #expect(store.calls == [.load, .save, .load, .delete, .load, .delete])
  }

  @Test("AC-12: 操作ごとに注入した失敗を投げる", arguments: StubAPIKeyStore.Operation.allCases)
  func injectsFailure(_ operation: StubAPIKeyStore.Operation) throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-1"))
    let error = APIKeyStoreError.operationFailed(code: -1)
    store.setFailure(error, for: operation)

    #expect(throws: error) {
      switch operation {
      case .load: _ = try store.load()
      case .save: try store.save(try APIKey("sk-ant-2"))
      case .delete: try store.delete()
      }
    }
    // 失敗した操作は保存内容を変えない
    #expect(store.storedKey?.value == "sk-ant-1")

    store.setFailure(nil, for: operation)
    #expect(try store.load()?.value == "sk-ant-1")
  }
}
