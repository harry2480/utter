import Foundation
import UtterCore

/// クリップボードの退避用コピー（INS-04）。中身はメモリ上にだけ持ち、記録・表示しない。
struct PasteboardSnapshot: Hashable, Sendable {
  struct Entry: Hashable, Sendable {
    let type: String
    let data: Data
  }

  /// 項目ごとの種別と中身
  var items: [[Entry]]
  /// 読み出せなかった種別の数（遅延提供・ファイルプロミスなど）。これらは復元できない
  var unreadableTypeCount: Int
}

extension PasteboardSnapshot: CustomStringConvertible, CustomReflectable {
  var description: String {
    "PasteboardSnapshot(items: \(items.count), unreadableTypes: \(unreadableTypeCount))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["items": items.count, "unreadableTypes": unreadableTypeCount])
  }
}

/// クリップボード管理アプリに履歴として残さないための種別（INS-06。nspasteboard.org の取り決め）。
enum ClipboardMarker {
  /// 一時的なデータ。履歴に残さない
  static let transient = "org.nspasteboard.TransientType"
  /// 機密のデータ。中身を表示・保存しない
  static let concealed = "org.nspasteboard.ConcealedType"

  static let all = [transient, concealed]
}

/// クリップボード復元の結果（INS-04）。
enum ClipboardRestoreOutcome: Hashable, Sendable {
  /// 退避した内容を書き戻した
  case restored
  /// 書き戻したが、読み出せなかった種別（遅延提供など）は失われた
  case restoredPartially
  /// 挿入用に書き込んだ後に他のアプリが書き換えたため、復元しなかった（changeCount が変わった）
  case skippedChanged
  /// 書き戻しに失敗した
  case failed
}

/// 挿入用に書き込んだクリップボードを、他のアプリと競合しない場合だけ元に戻す（INS-04）。
@MainActor
struct PendingClipboardRestore {
  let snapshot: PasteboardSnapshot
  let policy: ClipboardRestorePolicy

  func restore(on pasteboard: some InsertionPasteboard) -> ClipboardRestoreOutcome {
    guard policy.allowsRestore(currentChangeCount: pasteboard.changeCount) else {
      return .skippedChanged
    }
    guard pasteboard.restore(snapshot) else { return .failed }
    return snapshot.unreadableTypeCount == 0 ? .restored : .restoredPartially
  }
}
