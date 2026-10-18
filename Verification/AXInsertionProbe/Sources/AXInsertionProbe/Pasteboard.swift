import AppKit
import UtterCore

/// クリップボードの退避用コピー。中身はメモリ上にだけ持ち、記録・表示しない。
struct PasteboardSnapshot: Equatable {
  struct Entry: Equatable {
    let type: String
    let data: Data
  }

  var items: [[Entry]]
  /// 読み出せなかった種別の数（遅延提供・ファイルプロミスなど）。これらは復元できない
  var unreadableTypeCount: Int

  @MainActor
  static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
    var unreadable = 0
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type -> Entry? in
        guard let data = item.data(forType: type) else {
          unreadable += 1
          return nil
        }
        return Entry(type: type.rawValue, data: data)
      }
    }
    return PasteboardSnapshot(items: items, unreadableTypeCount: unreadable)
  }

  var typeCount: Int { items.reduce(0) { $0 + $1.count } }

  @MainActor
  func makeItems() -> [NSPasteboardItem] {
    items.map { entries in
      let item = NSPasteboardItem()
      for entry in entries {
        item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
      }
      return item
    }
  }
}

/// クリップボード復元の結果（INS-04）
enum RestoreOutcome: String {
  /// 復元し、退避した内容と一致することを確かめた
  case restored
  /// 復元したが、読み出した内容が退避した内容と一致しない
  case restoredMismatch = "restored-mismatch"
  /// 挿入後に他のアプリがクリップボードを書き換えたため、復元しなかった（changeCount が変わった）
  case skippedChanged = "skipped-changed"
  /// 書き戻しに失敗した
  case failed
  /// Pasteboard を使わない経路
  case notApplicable = "n/a"
}

@MainActor
enum PasteboardRestorer {
  static func restore(
    _ snapshot: PasteboardSnapshot, on pasteboard: NSPasteboard, policy: ClipboardRestorePolicy
  ) -> RestoreOutcome {
    guard policy.allowsRestore(currentChangeCount: pasteboard.changeCount) else {
      return .skippedChanged
    }
    pasteboard.clearContents()
    if !snapshot.items.isEmpty, !pasteboard.writeObjects(snapshot.makeItems()) {
      return .failed
    }
    let restored = PasteboardSnapshot.capture(pasteboard)
    return restored.items == snapshot.items ? .restored : .restoredMismatch
  }
}
