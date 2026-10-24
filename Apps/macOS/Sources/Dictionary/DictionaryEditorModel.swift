import Foundation
import Observation
import UtterPersistence
import UtterText

/// 辞書の編集画面の状態（TXT-03, AC-07）。
///
/// 編集と検証は UtterText の `DictionaryEditor`、保存は UtterPersistence の `DictionaryStore` が持つ。
/// ここは両者をつなぎ、編集が保存できたときだけ画面の内容を進める。保存はメインスレッドの外で行う。
/// 辞書語・置換ルールの値はログにもエラー文言にも出さない。
@MainActor
@Observable
final class DictionaryEditorModel {
  enum State: Equatable {
    case loading
    case loaded(DictionaryEditor)
    /// 読み込めない。編集はできない
    case failed(LoadFailure)
  }

  enum LoadFailure: Error, Equatable {
    /// 保存先を開けない・読み出せない
    case unreadable
    /// 保存された内容から辞書を組み立てられない（競合するルールなど）。開き直しても直らないため、上書きしない
    case inconsistent
  }

  private(set) var state: State = .loading
  /// 直前の操作が失敗した理由。利用者の入力は含めない
  private(set) var errorMessage: String?
  /// 読み込み中・保存中は次の読み込みや編集を受け付けない。読み込みと保存が交錯して、保存した内容が画面から巻き戻るのを防ぐ
  private(set) var isBusy = false

  private let openStore: @Sendable () throws -> DictionaryStore
  private var store: DictionaryStore?

  init(openStore: @escaping @Sendable () throws -> DictionaryStore) {
    self.openStore = openStore
  }

  var editor: DictionaryEditor? {
    if case .loaded(let editor) = state { editor } else { nil }
  }

  /// 保存された辞書を読み込む。画面を開くたびに呼び、ほかの経路で変わった内容も読み直す
  func load() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let store = self.store
    let openStore = self.openStore
    let result = await Task.detached {
      () -> Result<(DictionaryStore, UserDictionary), LoadFailure> in
      let opened: DictionaryStore
      let contents: (terms: [String], rules: [StoredReplacementRule])
      do {
        opened = try store ?? openStore()
        contents = try opened.contents()
      } catch {
        return .failure(.unreadable)
      }
      do {
        return .success((opened, try Self.dictionary(from: contents)))
      } catch {
        return .failure(.inconsistent)
      }
    }.value
    switch result {
    case .success(let (opened, dictionary)):
      self.store = opened
      state = .loaded(DictionaryEditor(dictionary: dictionary))
      errorMessage = nil
    case .failure(let failure):
      state = .failed(failure)
      errorMessage = nil
    }
  }

  @discardableResult
  func addTerm(_ spelling: String) async -> Bool {
    await apply { editor throws(DictionaryEditError) in try editor.addTerm(spelling) }
  }

  @discardableResult
  func updateTerm(at index: Int, to spelling: String) async -> Bool {
    await apply { editor throws(DictionaryEditError) in
      try editor.updateTerm(at: index, to: spelling)
    }
  }

  @discardableResult
  func removeTerm(at index: Int) async -> Bool {
    await apply { editor throws(DictionaryEditError) in try editor.removeTerm(at: index) }
  }

  @discardableResult
  func addRule(pattern: String, replacement: String, ignoresCase: Bool) async -> Bool {
    await apply { editor throws(DictionaryEditError) in
      try editor.addRule(pattern: pattern, replacement: replacement, ignoresCase: ignoresCase)
    }
  }

  @discardableResult
  func updateRule(
    at index: Int, pattern: String, replacement: String, ignoresCase: Bool
  ) async -> Bool {
    await apply { editor throws(DictionaryEditError) in
      try editor.updateRule(
        at: index, pattern: pattern, replacement: replacement, ignoresCase: ignoresCase)
    }
  }

  @discardableResult
  func removeRule(at index: Int) async -> Bool {
    await apply { editor throws(DictionaryEditError) in try editor.removeRule(at: index) }
  }

  /// 編集を検証して保存し、保存できたら画面の内容を進める。成功したら true
  private func apply(
    _ edit: (inout DictionaryEditor) throws(DictionaryEditError) -> Void
  ) async -> Bool {
    guard !isBusy, case .loaded(var edited) = state, let store else { return false }
    do {
      try edit(&edited)
    } catch {
      errorMessage = Self.message(for: error)
      return false
    }
    isBusy = true
    defer { isBusy = false }
    let dictionary = edited.dictionary
    do {
      try await Task.detached { try Self.save(dictionary, to: store) }.value
    } catch {
      errorMessage = "辞書を保存できませんでした。"
      return false
    }
    state = .loaded(edited)
    errorMessage = nil
    return true
  }

  nonisolated private static func dictionary(
    from contents: (terms: [String], rules: [StoredReplacementRule])
  ) throws -> UserDictionary {
    try UserDictionary(
      terms: contents.terms.map(DictionaryTerm.init),
      rules: contents.rules.map {
        try ReplacementRule(
          pattern: $0.pattern, replacement: $0.replacement, ignoresCase: $0.ignoresCase)
      })
  }

  nonisolated private static func save(_ dictionary: UserDictionary, to store: DictionaryStore)
    throws
  {
    try store.replaceAll(
      terms: dictionary.terms.map(\.spelling),
      rules: dictionary.rules.map {
        StoredReplacementRule(
          pattern: $0.pattern, replacement: $0.replacement, ignoresCase: $0.ignoresCase)
      })
  }

  /// 検証エラーの文言。位置は 1 始まりで示し、入力値は含めない
  static func message(for error: DictionaryEditError) -> String {
    switch error {
    case .emptySpelling: "辞書語を入力してください。"
    case .duplicateSpelling(let index): "同じ辞書語が \(index + 1) 番目にあります。"
    case .emptyPattern: "置換前の読みを入力してください。"
    case .duplicatePattern(let index): "\(index + 1) 番目のルールと同じ読みに一致します。"
    case .indexOutOfRange: "対象が見つかりません。画面を開き直してください。"
    }
  }
}
