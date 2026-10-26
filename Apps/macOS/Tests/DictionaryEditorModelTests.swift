import Foundation
import Testing
import UtterPersistence
import UtterText

/// テストごとに一時ディレクトリを作り、終わったら消す。
final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("utter-mac-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
struct DictionaryEditorModelTests {
  private let directory = TemporaryDirectory()

  private var databaseURL: URL { directory.url.appendingPathComponent("utter.sqlite") }

  private func makeModel() -> DictionaryEditorModel {
    let url = databaseURL
    return DictionaryEditorModel { DictionaryStore(database: try UtterDatabase.open(at: url)) }
  }

  private func store() throws -> DictionaryStore {
    DictionaryStore(database: try UtterDatabase.open(at: databaseURL))
  }

  @Test("AC-07: 編集した辞書を保存し、開き直しても同じ内容を読み込む")
  func savedEditsSurviveReload() async throws {
    let model = makeModel()
    await model.load()

    #expect(await model.addTerm("utter"))
    #expect(await model.addTerm("Claude"))
    #expect(await model.updateTerm(at: 1, to: "Claude Code"))
    #expect(await model.addRule(pattern: "ぎっとはぶ", replacement: "GitHub", ignoresCase: false))
    #expect(await model.addRule(pattern: "けす", replacement: "", ignoresCase: false))
    #expect(
      await model.updateRule(at: 0, pattern: "ぎっとはぶ", replacement: "GitHub", ignoresCase: true))
    #expect(await model.removeRule(at: 1))
    #expect(await model.removeTerm(at: 0))

    #expect(try store().terms() == ["Claude Code"])
    #expect(
      try store().rules() == [
        StoredReplacementRule(pattern: "ぎっとはぶ", replacement: "GitHub", ignoresCase: true)
      ])

    let reopened = makeModel()
    await reopened.load()
    #expect(reopened.editor == model.editor)
    #expect(reopened.editor?.dictionary.applyingReplacements(to: "ギットハブ") == "ギットハブ")
    #expect(reopened.editor?.dictionary.applyingReplacements(to: "ぎっとはぶ") == "GitHub")
  }

  @Test("TXT-03: 検証に失敗した編集は保存せず、入力値を含まない理由を示す")
  func invalidEditIsNotSaved() async throws {
    let model = makeModel()
    await model.load()
    #expect(await model.addTerm("ひみつのごい"))

    #expect(!(await model.addTerm("ひみつのごい")))
    #expect(model.errorMessage == "同じ辞書語が 1 番目にあります。")
    #expect(!(await model.addRule(pattern: " ", replacement: "x", ignoresCase: false)))
    #expect(model.errorMessage == "置換前の読みを入力してください。")

    #expect(try store().terms() == ["ひみつのごい"])
    #expect(try store().rules().isEmpty)

    #expect(await model.addTerm("utter"))
    #expect(model.errorMessage == nil)
  }

  @Test("TXT-03: 保存された内容から辞書を組み立てられなければ、編集できない状態にする")
  func conflictingStoredRulesFailToLoad() async throws {
    // 大文字小文字を無視するルールと、同じ読みの区別するルールは同時に持てない
    try store().replaceAll(
      terms: [],
      rules: [
        StoredReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true),
        StoredReplacementRule(pattern: "GitHub", replacement: "GitHub"),
      ])
    let model = makeModel()

    await model.load()

    #expect(model.state == .failed(.inconsistent))
    #expect(model.editor == nil)
    #expect(!(await model.addTerm("utter")))
    #expect(try store().terms().isEmpty)
  }

  @Test("TXT-03: 保存先を開けなければ、編集できない状態にする")
  func failsWhenStoreCannotOpen() async {
    struct OpenFailure: Error {}
    let model = DictionaryEditorModel { throw OpenFailure() }

    await model.load()

    #expect(model.state == .failed(.unreadable))
  }

  @Test("TXT-03: 保存に失敗した編集は画面に反映せず、理由を示す")
  func failedSaveDoesNotAdvanceState() async throws {
    try store().replaceAll(terms: ["utter"], rules: [])
    // 読み取り専用のファイルは読み取り専用で開かれ、読み込めるが書き込めない
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: databaseURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)
    }
    let model = makeModel()
    await model.load()
    let before = model.state
    #expect(model.editor?.terms.map(\.spelling) == ["utter"])

    #expect(!(await model.addTerm("Claude")))

    #expect(model.state == before)
    #expect(model.errorMessage == "辞書を保存できませんでした。")
    #expect(!model.isBusy)
  }

  @Test("TXT-03: 保存中の編集と読み込みは受け付けず、保存した内容を巻き戻さない")
  func rejectsOperationsWhileBusy() async throws {
    let model = makeModel()
    await model.load()

    async let first = model.addTerm("utter")
    async let second = model.addTerm("Claude")
    async let reload: Void = model.load()
    let results = await [first, second]
    await reload

    // どれが先に動くかは決まらないが、成功するのは高々1つで、画面と保存内容は一致する
    #expect(results.filter { $0 }.count <= 1)
    #expect(try store().terms().count == results.filter { $0 }.count)
    #expect(model.editor?.terms.map(\.spelling) == (try store().terms()))
  }
}
