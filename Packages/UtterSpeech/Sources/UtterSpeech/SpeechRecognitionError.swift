/// 音声認識の失敗の種類。認識テキストや音声は持たない。
///
/// クラウド STT（#60 の先行実装）の失敗は、呼び出し側が通知や対処（同意・認証の再設定、ローカル STT での再認識）を
/// 分けられるよう、原因ごとに別のケースにする（AI-06 と同じ分け方）。
public enum SpeechRecognitionError: Error, Hashable, Sendable, CaseIterable, Codable {
  /// モデルが未取得、またはロードできない
  case modelUnavailable
  /// 音声の形式（サンプリング周波数など）に対応していない
  case unsupportedAudioFormat
  /// 認識エンジンが異常終了した（STT Worker の終了など）
  case engineFailed
  /// メモリ不足などでロード・推論を抑止した
  case resourceLimited
  /// クラウド STT への音声送信に同意していない（AC-06）。送信していない
  case consentNotGranted
  /// クラウド STT へ送れる音声の上限（長さ・サイズ）を超えた。送信していない
  case audioLimitExceeded
  /// 利用者が設定した予算上限を超える（AI-04）。送信していない
  case budgetExceeded
  /// クラウド STT の応答待ちが上限時間を超えた
  case timeout
  /// クラウド STT の API キーが失効・無効になった
  case authenticationExpired
  /// クラウド STT 側の利用枠（レート制限・クォータ）が不足している
  case quotaExceeded
  /// クラウド STT へ接続できない、またはサービス側の一時的な障害
  case networkUnavailable
  /// クラウド STT の応答を解釈できない
  case invalidResponse
}
