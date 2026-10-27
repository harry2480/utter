import Foundation
import UtterAI
import UtterCore
import UtterText

/// Edit Mode の入力欄の Stub。`FakeTextField` の値と選択範囲を AX の代わりに読み書きする。
@MainActor
final class StubEditField: EditFieldAccess {
  let field: FakeTextField
  let target: InsertionTargetID
  let log: InsertionLog
  var secure: SensitiveSignal = .off
  /// `kAXSelectedTextAttribute` を読めるか
  var selectedTextReadable = true
  /// `kAXSelectedTextAttribute` が値の範囲と食い違うアプリを模す
  var selectedTextOverride: String?
  /// 選択範囲を変えられるか
  var selectable = true
  private(set) var selections: [FieldSnapshot.Selection] = []

  init(field: FakeTextField, target: InsertionTargetID, log: InsertionLog) {
    self.field = field
    self.target = target
    self.log = log
  }

  func snapshot(of target: InsertionTargetID) -> FieldSnapshot {
    guard target == self.target, field.readable else {
      return FieldSnapshot(value: nil, selection: nil)
    }
    return FieldSnapshot(value: field.value, selection: field.selection)
  }

  func value(of target: InsertionTargetID) -> String? {
    target == self.target && field.readable ? field.value : nil
  }

  func insertAtSelection(_ text: String, into target: InsertionTargetID) -> InsertionResponse {
    guard target == self.target, field.axSettable else { return .rejectedBeforeSend }
    log.events.append(.axInsert(text))
    field.receive(text, behavior: field.axBehavior)
    return .succeeded
  }

  func selectedText(of target: InsertionTargetID) -> String? {
    guard target == self.target, selectedTextReadable, let selection = field.selection else {
      return nil
    }
    if let selectedTextOverride { return selectedTextOverride }
    return EditModeCoordinator.text(in: field.value, at: selection)
  }

  func select(_ range: FieldSnapshot.Selection, in target: InsertionTargetID) -> Bool {
    guard target == self.target, selectable else { return false }
    selections.append(range)
    field.selection = range
    return true
  }

  func secureField(of target: InsertionTargetID) -> SensitiveSignal {
    target == self.target ? secure : .unknown
  }
}

/// 差分プレビュー・通知・退避の記録。本文は比較にだけ使う。
@MainActor
final class StubEditPresenter: EditModePresenting {
  enum Event: Equatable {
    case proposal(String)
    case dismiss
    case notice(EditModeNotice)
    case fallback(String, EditFallbackCause)
  }

  var events: [Event] = []
  /// 進行中の表示の移り変わり（`nil` は閉じた）。`events` とは分けて記録する
  var statuses: [EditModeStatus?] = []

  var proposals: [String] {
    events.compactMap { if case .proposal(let text) = $0 { text } else { nil } }
  }

  var notices: [EditModeNotice] {
    events.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
  }

  var fallbacks: [Event] {
    events.filter { if case .fallback = $0 { true } else { false } }
  }

  func showProposal(_ proposal: EditProposal) {
    events.append(.proposal(proposal.diff.editedText))
  }

  func dismissProposal() {
    events.append(.dismiss)
  }

  func showNotice(_ notice: EditModeNotice) {
    events.append(.notice(notice))
  }

  func showFallback(text: String, cause: EditFallbackCause) {
    events.append(.fallback(text, cause))
  }

  func showStatus(_ status: EditModeStatus?) {
    statuses.append(status)
  }

  /// 最後の進行中の表示
  var currentStatus: EditModeStatus? {
    statuses.last ?? nil
  }
}
