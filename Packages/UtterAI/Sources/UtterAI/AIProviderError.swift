/// 整形プロバイダーの失敗（AI-06）。
///
/// 呼び出し側が種類ごとに通知・退避を分けられるよう、原因ごとに別のケースにする。
/// 入力テキスト・応答本文・認証情報は持たない。
public enum AIProviderError: Error, Hashable, Sendable, CaseIterable {
  /// 応答待ちが上限時間を超えた
  case timeout
  /// API キーや OAuth トークンが失効・無効になった
  case authenticationExpired
  /// プロバイダー側の利用枠（レート制限・クォータ）が不足している
  case quotaExceeded
  /// 利用者が設定した予算上限を超える（AI-04）
  case budgetExceeded
  /// ネットワークに接続できない
  case networkUnavailable
  /// 応答を解釈できない
  case invalidResponse
  /// 呼び出し元の Task がキャンセルされた。キャンセルされたセッションの結果は使わないため、
  /// 呼び出し元がキャンセルした場合はローカル整形への退避や HUD 通知の対象にしない
  case cancelled
}
