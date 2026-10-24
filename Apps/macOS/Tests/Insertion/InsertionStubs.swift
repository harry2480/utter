import Foundation
import UtterCore

/// 挿入先のアプリの入力欄を模したもの。AX・Cmd+V・キー入力がこの値を書き換える。
@MainActor
final class FakeTextField {
  enum Behavior {
    /// 選択範囲へ書き込む
    case applies
    /// 成功を返すが何も変わらない
    case ignored
    /// 一部だけ入る
    case partial
  }

  /// 入力欄の値。`readable` が `false` なら読み戻せない
  var value: String
  var selection: FieldSnapshot.Selection?
  var readable = true
  var axSettable = true
  var axBehavior = Behavior.applies
  var pasteBehavior = Behavior.applies
  var typeBehavior = Behavior.applies

  init(value: String = "", selection: FieldSnapshot.Selection? = nil) {
    self.value = value
    self.selection = selection ?? FieldSnapshot.Selection(location: value.utf16.count, length: 0)
  }

  func receive(_ text: String, behavior: Behavior) {
    let inserted: String
    switch behavior {
    case .applies: inserted = text
    case .ignored: return
    case .partial: inserted = String(text.prefix(1))
    }
    let snapshot = FieldSnapshot(value: value, selection: selection)
    if let next = snapshot.expectedValue(inserting: inserted) {
      value = next
    } else {
      value += inserted
    }
    if let selection {
      self.selection = FieldSnapshot.Selection(
        location: selection.location + inserted.utf16.count, length: 0)
    }
  }
}

/// 操作の記録。発話本文は比較にだけ使う。
@MainActor
final class InsertionLog {
  enum Event: Equatable {
    case axInsert(String)
    case pasteboardWrite(String, markers: [String])
    case pasteboardRestore
    case commandV
    case typed(String)
    case preview(String, InsertionPreviewCause)
    case sleep(Duration)
  }

  var events: [Event] = []

  var sentInsertions: [Event] {
    events.filter {
      switch $0 {
      case .axInsert, .commandV, .typed: true
      default: false
      }
    }
  }

  var previews: [Event] {
    events.filter { if case .preview = $0 { true } else { false } }
  }
}

@MainActor
final class StubInspector: InsertionTargetInspector {
  /// `focusedTarget()` が順に返す値。最後の値を繰り返す
  var targets: [FocusedInsertionTarget?]
  var recorded: InsertionTargetID?
  var secure: SensitiveSignal = .off
  private(set) var focusQueries = 0

  init(targets: [FocusedInsertionTarget?], recorded: InsertionTargetID?) {
    self.targets = targets
    self.recorded = recorded
  }

  func recordTarget() -> InsertionTargetID? { recorded }

  func focusedTarget() -> FocusedInsertionTarget? {
    focusQueries += 1
    if targets.count > 1 {
      return targets.removeFirst()
    }
    return targets.first ?? nil
  }

  func secureEventInput() -> SensitiveSignal { secure }
}

@MainActor
final class StubFieldAccess: InsertionFieldAccess {
  let field: FakeTextField
  let target: InsertionTargetID
  let log: InsertionLog
  /// 値の読み取り1回にかかる時間（応答の遅いアプリ）
  var readLatency: (clock: StubClock, duration: Duration)?

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
    if let readLatency {
      readLatency.clock.advance(by: readLatency.duration)
    }
    return target == self.target && field.readable ? field.value : nil
  }

  func insertAtSelection(_ text: String, into target: InsertionTargetID) -> InsertionResponse {
    guard target == self.target, field.axSettable else { return .rejectedBeforeSend }
    log.events.append(.axInsert(text))
    field.receive(text, behavior: field.axBehavior)
    return .succeeded
  }
}

@MainActor
final class StubPasteboard: InsertionPasteboard {
  var changeCount = 0
  var contents: PasteboardSnapshot
  /// 退避の途中で他のアプリが書き換える
  var changesDuringCapture = false
  var writeSucceeds = true
  private let log: InsertionLog

  init(contents: PasteboardSnapshot, log: InsertionLog) {
    self.contents = contents
    self.log = log
  }

  func capture() -> PasteboardSnapshot {
    if changesDuringCapture {
      simulateOtherAppCopy("other")
    }
    return contents
  }

  func write(_ text: String, markers: [String]) -> Bool {
    log.events.append(.pasteboardWrite(text, markers: markers))
    changeCount += 1
    guard writeSucceeds else {
      contents = PasteboardSnapshot(items: [], unreadableTypeCount: 0)
      return false
    }
    contents = PasteboardSnapshot(
      items: [
        [PasteboardSnapshot.Entry(type: "public.utf8-plain-text", data: Data(text.utf8))]
          + markers.map { PasteboardSnapshot.Entry(type: $0, data: Data()) }
      ],
      unreadableTypeCount: 0)
    return true
  }

  func restore(_ snapshot: PasteboardSnapshot) -> Bool {
    log.events.append(.pasteboardRestore)
    changeCount += 1
    contents = PasteboardSnapshot(items: snapshot.items, unreadableTypeCount: 0)
    return true
  }

  func simulateOtherAppCopy(_ text: String) {
    changeCount += 1
    contents = PasteboardSnapshot(
      items: [[PasteboardSnapshot.Entry(type: "public.utf8-plain-text", data: Data(text.utf8))]],
      unreadableTypeCount: 0)
  }

  var plainText: String? {
    contents.items.first?.first { $0.type == "public.utf8-plain-text" }
      .map { String(decoding: $0.data, as: UTF8.self) }
  }
}

@MainActor
final class StubKeyEvents: InsertionKeyEvents {
  var pasteSucceeds = true
  private let field: FakeTextField
  private let pasteboard: StubPasteboard
  private let log: InsertionLog

  init(field: FakeTextField, pasteboard: StubPasteboard, log: InsertionLog) {
    self.field = field
    self.pasteboard = pasteboard
    self.log = log
  }

  func sendPaste() -> Bool {
    guard pasteSucceeds else { return false }
    log.events.append(.commandV)
    if let text = pasteboard.plainText {
      field.receive(text, behavior: field.pasteBehavior)
    }
    return true
  }

  func type(_ text: String, while isStillTargeting: () -> Bool) async -> InsertionResponse {
    var typed = ""
    for character in text {
      guard isStillTargeting() else { break }
      typed.append(character)
    }
    if !typed.isEmpty {
      log.events.append(.typed(typed))
      field.receive(typed, behavior: field.typeBehavior)
    }
    if typed.count == text.count { return .succeeded }
    return typed.isEmpty ? .rejectedBeforeSend : .failedAfterSend
  }
}

@MainActor
final class StubPermissions: InsertionPermissions {
  var accessibility = true
  var postEvents = true

  func isAccessibilityTrusted() -> Bool { accessibility }
  func canPostEvents() -> Bool { postEvents }
}

@MainActor
final class StubPreview: InsertionPreviewPresenting {
  private let log: InsertionLog

  init(log: InsertionLog) {
    self.log = log
  }

  func showPreview(text: String, cause: InsertionPreviewCause) {
    log.events.append(.preview(text, cause))
  }
}

/// 実際には待たずに経過時間を進め、記録する。`onSleep` で待っている間に起きることを差し込む
@MainActor
final class StubClock: InsertionClock {
  var onSleep: (() async -> Void)?
  private(set) var now = Duration.zero
  private let log: InsertionLog

  init(log: InsertionLog) {
    self.log = log
  }

  func elapsed() -> Duration { now }

  /// AX の問い合わせなど、待ち以外にかかった時間を進める
  func advance(by duration: Duration) {
    now += duration
  }

  func sleep(for duration: Duration) async {
    log.events.append(.sleep(duration))
    now += duration
    if let action = onSleep {
      onSleep = nil
      await action()
    }
  }
}
