import Testing

@testable import UtterAI

@MainActor
struct APIKeySettingsModelTests {
  @Test("AC-12: 保存済みかどうかを確かめる")
  func refreshSaved() throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-stored"))
    let model = APIKeySettingsModel(store: store)
    #expect(model.status == nil)

    model.refresh()

    #expect(model.status == .saved)
    #expect(model.canDelete)
    #expect(store.calls == [.load])
  }

  @Test("AC-12: 未保存なら notSaved で、削除できない")
  func refreshNotSaved() {
    let model = APIKeySettingsModel(store: StubAPIKeyStore())

    model.refresh()

    #expect(model.status == .notSaved)
    #expect(!model.canDelete)
  }

  @Test("AC-12: 保存先を確かめられないときは unavailable にする")
  func refreshUnavailable() {
    let store = StubAPIKeyStore()
    store.setFailure(.operationFailed(code: -25308), for: .load)
    let model = APIKeySettingsModel(store: store)

    model.refresh()

    #expect(model.status == .unavailable(.operationFailed(code: -25308)))
    #expect(!model.canDelete)
  }

  @Test("AC-12: 保存されている値を読めないときは unavailable にする")
  func refreshInvalidStoredData() {
    let store = StubAPIKeyStore()
    store.setFailure(.invalidStoredData, for: .load)
    let model = APIKeySettingsModel(store: store)

    model.refresh()

    #expect(model.status == .unavailable(.invalidStoredData))
  }

  @Test("AC-12: 制御文字だけの入力は保存できない")
  func controlOnlyInputCannotBeSaved() {
    let model = APIKeySettingsModel(store: StubAPIKeyStore())
    model.input = "\u{0}\u{7F}"

    #expect(!model.canSave)
  }

  @Test("AC-12: 前後の空白を除いて保存し、入力を消す")
  func savesTrimmedKey() throws {
    let store = StubAPIKeyStore()
    let model = APIKeySettingsModel(store: store)
    model.input = "  sk-ant-new\n"

    model.save()

    #expect(store.storedKey == (try APIKey("sk-ant-new")))
    #expect(store.storedKey?.value == "sk-ant-new")
    #expect(model.input.isEmpty)
    #expect(model.status == .saved)
    #expect(model.feedback == .saved)
  }

  @Test("AC-12: 保存済みのキーを置き換える")
  func replacesStoredKey() throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-old"))
    let model = APIKeySettingsModel(store: store)
    model.input = "sk-ant-new"

    model.save()

    #expect(store.storedKey?.value == "sk-ant-new")
  }

  @Test("AC-12: 空・空白だけの入力は保存しない", arguments: ["", "   ", "\n\t"])
  func rejectsBlankInput(_ input: String) throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-old"))
    let model = APIKeySettingsModel(store: store)
    model.input = input

    #expect(!model.canSave)
    model.save()

    #expect(model.feedback == .invalidInput(.empty))
    #expect(store.storedKey?.value == "sk-ant-old")
    #expect(!store.calls.contains(.save))
  }

  @Test("AC-12: 使えない文字を含む入力は保存せず、入力を残す")
  func rejectsInvalidInput() {
    let store = StubAPIKeyStore()
    let model = APIKeySettingsModel(store: store)
    model.input = "sk-ant abc"

    #expect(model.canSave)
    model.save()

    #expect(model.feedback == .invalidInput(.invalidCharacters))
    #expect(model.input == "sk-ant abc")
    #expect(store.storedKey == nil)
  }

  @Test("AC-12: 保存に失敗したら入力を残し、状態を変えない")
  func keepsInputWhenSaveFails() {
    let store = StubAPIKeyStore()
    store.setFailure(.operationFailed(code: -34018), for: .save)
    let model = APIKeySettingsModel(store: store)
    model.refresh()
    model.input = "sk-ant-new"

    model.save()

    #expect(model.feedback == .saveFailed(.operationFailed(code: -34018)))
    #expect(model.input == "sk-ant-new")
    #expect(model.status == .notSaved)
  }

  @Test("AC-12: 削除すると未保存になる")
  func deletes() throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-stored"))
    let model = APIKeySettingsModel(store: store)
    model.refresh()

    model.delete()

    #expect(store.storedKey == nil)
    #expect(model.status == .notSaved)
    #expect(model.feedback == .deleted)
  }

  @Test("AC-12: 削除に失敗したら保存先の状態を確かめ直す")
  func refreshesWhenDeleteFails() throws {
    let store = StubAPIKeyStore(key: try APIKey("sk-ant-stored"))
    store.setFailure(.operationFailed(code: -25293), for: .delete)
    let model = APIKeySettingsModel(store: store)
    model.refresh()

    model.delete()

    #expect(model.feedback == .deleteFailed(.operationFailed(code: -25293)))
    #expect(model.status == .saved)
    #expect(store.storedKey != nil)
  }

  @Test("AC-12: 画面を閉じるときに入力と結果を消す")
  func clearsInput() {
    let model = APIKeySettingsModel(store: StubAPIKeyStore())
    model.input = "sk-ant-typing"
    model.save()

    model.input = "sk-ant-typing-again"
    model.clearInput()

    #expect(model.input.isEmpty)
    #expect(model.feedback == nil)
  }

  @Test("AC-12: 文字列表現に入力中のキーを出さない")
  func redactsInput() {
    let model = APIKeySettingsModel(store: StubAPIKeyStore())
    model.input = "sk-ant-secret-value"

    #expect(!String(describing: model).contains("secret"))
    #expect(!String(reflecting: model).contains("secret"))
  }
}
