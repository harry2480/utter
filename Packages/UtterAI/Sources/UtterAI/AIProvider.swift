import UtterCore

/// AI 整形プロバイダーの共通インターフェース（AI-01, AI-06）。
///
/// クラウド AI（Claude / ChatGPT）の各実装と `StubAIProvider` がこれに準拠し、呼び出し側から差し替えられる。
/// 送信しないローカル整形（Raw / Local Basic）は `LocalRefiner` で扱う。
/// 実装は `request.text` を整形対象のデータとして扱い、指示として実行しない（TXT-04）。
public protocol AIProvider: Sendable {
  /// 送信先。`RefinementRouter` が送信前に、この送信先への整形の同意を確認する（AC-06）。
  /// 実際の通信先と必ず一致させる。違うと、別の送信先への同意で送信してしまう
  var destination: CloudAIProviderKind { get }

  /// STT テキストを整形して返す。応答の検証（空応答・保護対象など）は呼び出し側が行う。
  ///
  /// 同意と予算はここでは確認しない。アプリからは直接呼ばず、必ず `RefinementRouter` を通す（AC-06, AI-04）。
  ///
  /// 呼び出し元の Task がキャンセルされた場合は、送信中の通信も止めて速やかに `AIProviderError.cancelled` を投げる。
  /// `RefinementRouter` は上限時間を過ぎるとキャンセルして待たずに戻るため、キャンセルに応じない実装では
  /// 処理が裏で続き、上限時間を超えるたびに同時に動く処理が増える。
  ///
  /// - Note: Swift 6.4 では `Task { () throws(AIProviderError) -> T in ... }` のように Task のクロージャへ
  ///   typed throws を書くと、別のケースが返ったりクラッシュしたりする。Task の中では型指定なしの `throws` にするか、
  ///   `do throws(AIProviderError) { ... } catch { ... }` でエラーを値として受け取る。
  func refine(_ request: RefinementRequest) async throws(AIProviderError) -> RefinementResponse
}
