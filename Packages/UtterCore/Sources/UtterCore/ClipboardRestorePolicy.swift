/// Pasteboard 経由の挿入後に、元のクリップボードを戻してよいかを判定する（INS-04）。
///
/// 挿入のために書き込んだ直後の changeCount を記録し、その後に他のアプリが書き込んでいない
/// （changeCount が変わっていない）場合だけ復元を許可する。
public struct ClipboardRestorePolicy: Hashable, Sendable {
  /// 挿入用に書き込んだ直後の changeCount
  public let changeCountAfterWrite: Int

  public init(changeCountAfterWrite: Int) {
    self.changeCountAfterWrite = changeCountAfterWrite
  }

  /// 現在の changeCount で、復元してよいか。
  public func allowsRestore(currentChangeCount: Int) -> Bool {
    currentChangeCount == changeCountAfterWrite
  }
}
