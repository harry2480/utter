import Foundation
import UtterPersistence

/// アプリが使う SQLite データベース（辞書・使用量・任意の入力履歴, 3章, 7章）を1つだけ開いて共有する。
///
/// 起動時には開かず、最初に使う画面が求めたときにメインスレッド以外で開く。開けなかったときは次に求められたときに開き直す。
/// 保存先は辞書・使用量と同じ `AppDatabaseLocation`（`~/Library/Application Support/utter/utter.sqlite`）。
@MainActor
final class AppDatabaseProvider {
  private var opening: Task<UtterDatabase, any Error>?

  func database() async throws -> UtterDatabase {
    let task: Task<UtterDatabase, any Error>
    if let opening {
      task = opening
    } else {
      task = Task.detached { try UtterDatabase.open(at: try AppDatabaseLocation.url()) }
      opening = task
    }
    do {
      return try await task.value
    } catch {
      if opening == task { opening = nil }
      throw error
    }
  }
}
