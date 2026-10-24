import AppKit
import ApplicationServices
import UtterCore

/// Pasteboard 経路で、挿入後に復元するために持っておく情報
struct PendingRestore {
  let snapshot: PasteboardSnapshot
  let policy: ClipboardRestorePolicy
}

/// Pasteboard 経路の結果。退避にかかった時間と Cmd+V を送った時刻を、挿入の時間と分けて返す
struct PasteboardInsertion {
  let response: InsertionResponse
  /// 退避中に他のアプリがクリップボードを書き換えたため書き込まなかった場合は nil（復元もしない）
  let pending: PendingRestore?
  let captureDuration: Duration
  let sentAt: ContinuousClock.Instant?
}

@MainActor
enum Inserter {
  /// kAXSelectedTextAttribute に書き込む
  static func axSelected(_ element: AXUIElement, text: String) -> InsertionResponse {
    guard AX.isSettable(element, AXAttribute.selectedText) else { return .rejectedBeforeSend }
    return AX.set(element, AXAttribute.selectedText, text as CFString) == .success
      ? .succeeded : .failedAfterSend
  }

  /// kAXValueAttribute に、選択範囲を置き換えた全体の値を書き込み、カーソルを挿入した文字列の後ろへ移す
  static func axValue(_ element: AXUIElement, before: FieldSnapshot, text: String)
    -> InsertionResponse
  {
    guard AX.isSettable(element, AXAttribute.value),
      let expected = before.expectedValue(inserting: text),
      let range = before.selectedRange
    else { return .rejectedBeforeSend }
    guard AX.set(element, AXAttribute.value, expected as CFString) == .success else {
      return .failedAfterSend
    }
    // カーソル移動の失敗は挿入の成否に含めない（値の書き込みは成功している）
    _ = AX.setSelectedRange(
      element, CFRange(location: range.location + text.utf16.count, length: 0))
    return .succeeded
  }

  /// Unicode 文字列付きのキーイベントを、書記素クラスタごとに送る。修飾キーは付けない
  static func cgEvent(text: String) -> InsertionResponse {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return .rejectedBeforeSend }
    var sentAny = false
    for character in text {
      let units = Array(String(character).utf16)
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return sentAny ? .failedAfterSend : .rejectedBeforeSend }
      for event in [down, up] {
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.post(tap: .cghidEventTap)
      }
      sentAny = true
      Thread.sleep(forTimeInterval: 0.005)
    }
    return .succeeded
  }

  /// クリップボードを退避してから文字列と一時データの印を書き込み、Cmd+V を送る（INS-04, INS-06）
  static func pasteboard(text: String, markers: MarkerSet) -> PasteboardInsertion {
    let pasteboard = NSPasteboard.general
    let clock = ContinuousClock()
    let captureStart = clock.now
    let changeCountBeforeCapture = pasteboard.changeCount
    let snapshot = PasteboardSnapshot.capture(pasteboard)
    let captureDuration = clock.now - captureStart
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    for marker in markers.types {
      item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
    }
    // 退避の途中で書き換えられていたら、退避した内容は最新ではない。上書きせずに中止する
    guard pasteboard.changeCount == changeCountBeforeCapture else {
      return PasteboardInsertion(
        response: .rejectedBeforeSend, pending: nil, captureDuration: captureDuration, sentAt: nil)
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      let policy = ClipboardRestorePolicy(changeCountAfterWrite: pasteboard.changeCount)
      return PasteboardInsertion(
        response: .rejectedBeforeSend, pending: PendingRestore(snapshot: snapshot, policy: policy),
        captureDuration: captureDuration, sentAt: nil)
    }
    let pending = PendingRestore(
      snapshot: snapshot,
      policy: ClipboardRestorePolicy(changeCountAfterWrite: pasteboard.changeCount))
    let sentAt = clock.now
    guard sendCommandV() else {
      return PasteboardInsertion(
        response: .rejectedBeforeSend, pending: pending, captureDuration: captureDuration,
        sentAt: nil)
    }
    return PasteboardInsertion(
      response: .succeeded, pending: pending, captureDuration: captureDuration, sentAt: sentAt)
  }

  /// Cmd+V。仮想キーコード 9 は ANSI / JIS 配列の V（Dvorak など別配列では README の注意を参照）
  private static func sendCommandV() -> Bool {
    let keyV: CGKeyCode = 9
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}
