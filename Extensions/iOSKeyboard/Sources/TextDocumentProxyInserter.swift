import UIKit
import UtterPersistence

/// `UITextDocumentProxy` で入力欄へ本文を挿入する（iOS-05）。挿入はこの経路だけを使う。
///
/// 挿入できたかは、挿入の前後のカーソルより前の文脈を UtterPersistence の判定に渡して決める。
/// 文脈は判定にだけ使い、保存・記録しない。
@MainActor
final class TextDocumentProxyInserter: SharedResultTextInserter {
  private weak var controller: UIInputViewController?

  init(controller: UIInputViewController) {
    self.controller = controller
  }

  func insert(_ text: String) async -> SharedResultInsertionConfirmation {
    guard let proxy = controller?.textDocumentProxy else {
      // キーボードが閉じられた。挿入していないが、確認できないものとして扱う（自動では再挿入しない）
      return .unknown
    }
    let before = proxy.documentContextBeforeInput
    proxy.insertText(text)
    return SharedResultInsertionConfirmation(
      insertedText: text, contextBefore: before, contextAfter: proxy.documentContextBeforeInput)
  }
}
