import Foundation

/// キーボードで共有結果に対して出す操作（iOS-05, iOS-IPC-03）。
public enum SharedResultKeyboardAction: Hashable, Sendable {
  /// 挿入する（`SharedResultInsertionCoordinator.insert(sessionID:)`）
  case insert
  /// 挿入結果が不明な結果を、入力欄に入っていたとして挿入済みにする（「入っていた」, `confirmInserted(sessionID:)`）
  case confirmInserted
  /// 挿入結果が不明な結果を、利用者の確認を受けて挿入し直す（「もう一度入れる」, `insert(sessionID:confirmedReinsertion:)`）
  case reinsert
  /// 結果を消し、本体アプリでも使えなくする（「消す」, `discard(sessionID:)`）
  case discard
}

/// キーボードで、プレビューした共有結果に対して出す操作と残り時間（iOS-05, iOS-IPC-02, iOS-IPC-03）。
///
/// 表示している間に時刻が進むため、プレビューを読み込んだ時刻ではなく表示する時刻で決める。
/// 本文は持たない（本文は `SharedResultPreview` から画面に表示するだけ）。
/// 挿入結果が不明なときは「入っていた」と「もう一度入れる」を出し、どちらも選ばれるまで自動では挿入し直さない。
public struct SharedResultKeyboardPanel: Hashable, Sendable {
  /// 出す操作。並べる順
  public let actions: [SharedResultKeyboardAction]
  /// 有効期限までの残り時間（分、切り上げ）。本文を出さない・期限を過ぎたときは `nil`
  public let remainingMinutes: Int?
  /// 表示している間に有効期限を過ぎた。挿入・再挿入は出さない
  public let isExpired: Bool

  public init(_ preview: SharedResultPreview, at now: Date) {
    switch preview {
    case .insertable(_, let expiresAt):
      let remaining = Self.minutesRemaining(until: expiresAt, at: now)
      actions = remaining == nil ? [.discard] : [.insert, .discard]
      remainingMinutes = remaining
      isExpired = remaining == nil
    case .needsConfirmation(_, let expiresAt):
      // 期限を過ぎると挿入し直せない（`beginInsertionAfterConfirmation`）が、入っていたかの確認と消すことはできる
      let remaining = Self.minutesRemaining(until: expiresAt, at: now)
      actions =
        remaining == nil ? [.confirmInserted, .discard] : [.confirmInserted, .reinsert, .discard]
      remainingMinutes = remaining
      isExpired = remaining == nil
    case .notFound, .notInsertable:
      actions = []
      remainingMinutes = nil
      isExpired = false
    }
  }

  /// 残り時間を分に切り上げる（作成直後は「あと 10 分」、残り 30 秒なら「あと 1 分」）。期限を過ぎていれば `nil`
  static func minutesRemaining(until expiresAt: Date, at now: Date) -> Int? {
    let remaining = expiresAt.timeIntervalSince(now)
    guard remaining > 0 else {
      return nil
    }
    let minutes = (remaining / 60).rounded(.up)
    // 保存済みの値が壊れて期限が極端に先でも、変換で停止しないよう上限で止める
    return minutes < Double(Int.max) ? Int(minutes) : Int.max
  }
}
