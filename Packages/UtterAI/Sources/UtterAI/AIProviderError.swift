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

extension AIProviderError {
  /// 課金されない失敗か（AI-05）。認証や利用枠で拒否された場合と、予算超過で送信しなかった場合に限る。
  ///
  /// 上限時間の超過・応答の解釈失敗・キャンセルと、ネットワークの失敗は、課金されている可能性があるため `false`。
  /// ネットワークの失敗には応答の途中で切れた場合も含まれ、送信前の失敗と区別できないため、多めに数える側に倒す。
  /// 予算の予約の取り消し（`RefinementRouter`）と、別の送信先への切り替えの可否（`CloudFallbackRouter`）がこの分類に従う。
  var isUnbilled: Bool {
    switch self {
    case .authenticationExpired, .quotaExceeded, .budgetExceeded:
      true
    case .timeout, .invalidResponse, .cancelled, .networkUnavailable:
      false
    }
  }
}
