import Foundation
import UtterPersistence

/// 一時音声の保存先（`TemporaryAudioStore`）への操作を、頼んだ順に1つずつ、メインスレッドの外で行う（7章, AC-10）。
///
/// `TemporaryAudioStore` は同じストアへの操作を呼び出し側で1つずつ行う前提のため、セッションの保存・削除（`TemporaryAudioRetention`）と
/// 起動時の復旧（`LaunchAudioRecovery`）は、このキューを共有する。
@MainActor
final class TemporaryAudioStoreQueue {
  let store: TemporaryAudioStore
  /// 最後に頼んだ操作。次の操作はこれを待ってから始める
  private var last: Task<Void, Never>?

  init(store: TemporaryAudioStore) {
    self.store = store
  }

  /// `operation` を、前に頼んだ操作がすべて終わってから行う。結果は返したタスクで受け取る。
  ///
  /// `operation` が終わるまで、後に頼んだ操作は始まらない（起動時の復旧は、認識し直す間もストアを占有する）
  @discardableResult
  func enqueue<Output: Sendable>(
    _ operation: @escaping @Sendable (TemporaryAudioStore) async -> Output
  ) -> Task<Output, Never> {
    let previous = last
    let store = store
    let task = Task.detached(priority: .utility) {
      await previous?.value
      return await operation(store)
    }
    last = Task.detached { _ = await task.value }
    return task
  }

  /// それまでに頼んだ操作がすべて終わるまで待つ
  func drain() async {
    await last?.value
  }

  /// アプリ専用の一時音声の置き場所（`~/Library/Application Support/<Bundle ID>/TemporaryAudio`）。
  ///
  /// App Group の共有コンテナには置かない（CLAUDE.md「プライバシー」）。ディレクトリは所有者だけが読み書きでき（0700）、
  /// ファイルは 0600 で保存する（`TemporaryAudioStore`）。Time Machine などのバックアップからは除外する。
  /// ディスク上の暗号化は FileVault に任せる（macOS には iOS のファイル保護クラスに当たる仕組みがアプリ単位でない）
  static func applicationStore(bundle: Bundle = .main) -> TemporaryAudioStore? {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    let directory =
      support
      .appendingPathComponent(bundle.bundleIdentifier ?? "utter", isDirectory: true)
      .appendingPathComponent("TemporaryAudio", isDirectory: true)
    return try? TemporaryAudioStore(directory: directory, protectFile: excludeFromBackup)
  }

  @Sendable
  private nonisolated static func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = url
    try url.setResourceValues(values)
  }
}
