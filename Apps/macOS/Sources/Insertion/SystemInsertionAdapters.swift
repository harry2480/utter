import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UtterCore

/// `NSPasteboard.general` による読み書き（INS-04, INS-06）。中身は記録・表示しない。
@MainActor
final class SystemInsertionPasteboard: InsertionPasteboard {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  var changeCount: Int { pasteboard.changeCount }

  func capture() -> PasteboardSnapshot {
    var unreadable = 0
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type -> PasteboardSnapshot.Entry? in
        guard let data = item.data(forType: type) else {
          unreadable += 1
          return nil
        }
        return PasteboardSnapshot.Entry(type: type.rawValue, data: data)
      }
    }.filter { !$0.isEmpty }  // 読み出せる種別がない項目は書き戻せない（空の項目の書き込みは失敗する）
    return PasteboardSnapshot(items: items, unreadableTypeCount: unreadable)
  }

  func write(_ text: String, markers: [String]) -> Bool {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    for marker in markers {
      item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
    }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  func restore(_ snapshot: PasteboardSnapshot) -> Bool {
    pasteboard.clearContents()
    guard !snapshot.items.isEmpty else { return true }
    let items = snapshot.items.map { entries in
      let item = NSPasteboardItem()
      for entry in entries {
        item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
      }
      return item
    }
    return pasteboard.writeObjects(items)
  }
}

/// CGEvent によるキー入力（INS-02）。Return キーは送らない（INS-03, AC-08）。
@MainActor
final class CGEventInsertionKeyEvents: InsertionKeyEvents {
  /// ANSI / JIS 配列の V キー。Dvorak など別配列では V にならない（既知の制限）
  private static let keyV: CGKeyCode = 9

  func sendPaste() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  /// Unicode 文字列付きのキーイベントを、書記素クラスタごとに送る。修飾キーは付けない
  func type(_ text: String, while isStillTargeting: () -> Bool) async -> InsertionResponse {
    // 改行・Tab は Return / Tab キーとして扱われうるため送らない（呼び出し側でも除いている）
    guard InsertionExecutor.isSafeForKeyEvents(text),
      let source = CGEventSource(stateID: .hidSystemState)
    else { return .rejectedBeforeSend }
    var sentAny = false
    for character in text {
      // 待つ間にメインスレッドを譲るため、利用者がフォーカスを移しうる。送る直前ごとに確かめる
      guard !Task.isCancelled, isStillTargeting() else {
        return sentAny ? .failedAfterSend : .rejectedBeforeSend
      }
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
      // 受け取る側が取りこぼさないよう少し間を空ける（AXInsertionProbe と同じ 5 ミリ秒）
      try? await Task.sleep(for: .milliseconds(5))
    }
    return .succeeded
  }
}

/// 権限の状態の確認（PERM-01, PERM-02）。許可ダイアログは出さない。
@MainActor
final class SystemInsertionPermissions: InsertionPermissions {
  func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  func canPostEvents() -> Bool {
    CGPreflightPostEventAccess()
  }
}

/// `ContinuousClock` による経過時間と待ち時間。
@MainActor
final class ContinuousInsertionClock: InsertionClock {
  private let origin = ContinuousClock.now

  func elapsed() -> Duration {
    ContinuousClock.now - origin
  }

  func sleep(for duration: Duration) async {
    // 呼び出し元の取り消しを引き継がないタスクで待つ（取り消されてもクリップボードの復元を早めない）
    await Task { try? await Task.sleep(for: duration) }.value
  }
}

extension InsertionExecutor {
  /// 本番のアダプターで組み立てる。
  ///
  /// `profiles`（アプリ別の既定経路）は Phase 0（#41）の判定後に `docs/挿入互換性表.md` から入れる。それまでは空で、
  /// すべてのアプリで既定の順（AX → Pasteboard → CGEvent）を試す。
  static func system(
    preview: any InsertionPreviewPresenting,
    policy: InsertionPolicy = InsertionPolicy(),
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy()
  ) -> (executor: InsertionExecutor, inspector: any InsertionTargetInspector) {
    let target = AccessibilityInsertionTarget()
    let executor = InsertionExecutor(
      inspector: target,
      field: target,
      pasteboard: SystemInsertionPasteboard(),
      keyEvents: CGEventInsertionKeyEvents(),
      permissions: SystemInsertionPermissions(),
      preview: preview,
      clock: ContinuousInsertionClock(),
      policy: policy,
      sensitivePolicy: sensitivePolicy)
    return (executor, target)
  }
}
