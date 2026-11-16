import UIKit
import UtterCore
import UtterPersistence

extension KeyboardInputField {
  /// 入力欄の属性を OS 非依存の値にする。取れない属性は `unknown`（安全側, iOS-09）
  @MainActor
  init(_ proxy: any UITextDocumentProxy) {
    let secure: SensitiveSignal = proxy.isSecureTextEntry.map { $0 ? .on : .off } ?? .unknown
    let phone: SensitiveSignal =
      proxy.keyboardType.map { $0 == .phonePad || $0 == .namePhonePad ? .on : .off } ?? .unknown
    self.init(secureTextEntry: secure, phoneNumber: phone)
  }
}

/// `UITextDocumentProxy` で入力欄へ本文を挿入する（iOS-05）。挿入はこの経路だけを使う。
///
/// 挿入の直前（確保の読み書きを待った後）に、挿入を始めたときの表示が続いているか（閉じて表示し直していないか,
/// #271）と、その時点の入力欄の制限をもう一度確かめ、どちらかに通らなければ挿入しない。
/// 挿入できたかは、挿入の前後のカーソルより前の文脈を UtterPersistence の判定に渡して決める。
/// 文脈は判定にだけ使い、保存・記録しない。
@MainActor
final class TextDocumentProxyInserter: SharedResultTextInserter {
  private weak var controller: UIInputViewController?

  init(controller: UIInputViewController) {
    self.controller = controller
  }

  func insert(
    _ text: String, isStillTarget: @escaping SharedResultInsertionTargetCheck
  ) async -> SharedResultInsertionConfirmation {
    // 画面から外れたキーボードには挿入しない（待機セッションの停止後に閉じられた場合, iOS-06）
    guard controller?.viewIfLoaded?.window != nil, let proxy = controller?.textDocumentProxy else {
      // キーボードが閉じられた。挿入していないが、確認できないものとして扱う（自動では再挿入しない）
      return .unknown
    }
    // 確保を待つ間に閉じられ、別の入力欄で表示し直された。挿入せず、確認できないものとして扱う（iOS-06, #271）
    guard isStillTarget() else { return .unknown }
    guard KeyboardInputField(proxy).restrictions.isEmpty else {
      // 挿入していないが、確保した結果は挿入結果不明にして自動では再挿入しない（安全側）
      return .unknown
    }
    let before = proxy.documentContextBeforeInput
    proxy.insertText(text)
    return SharedResultInsertionConfirmation(
      insertedText: text, contextBefore: before, contextAfter: proxy.documentContextBeforeInput)
  }
}
