import UtterCore

/// Edit Mode で、選択テキストを音声指示に従って書き換えるクラウド AI の共通インターフェース（AC-14, AI-01）。
///
/// 送信しないローカルでは音声指示による編集ができないため、退避先のローカル実装は持たない。
/// 実装は `request.selection` を編集対象のデータとして扱い、その中の指示を実行しない（TXT-04）。
public protocol AIEditProvider: Sendable {
  /// 送信先。`EditRouter` が送信前に、この送信先への選択テキストの送信の同意を確認する（AC-06）。
  /// 実際の通信先と必ず一致させる
  var destination: CloudAIProviderKind { get }

  /// 選択テキストを書き換えた文章を返す。応答の検証は呼び出し側が行う。
  ///
  /// 同意と予算はここでは確認しない。アプリからは直接呼ばず、必ず `EditRouter` を通す（AC-06, AI-04）。
  /// キャンセルへの応じ方は `AIProvider.refine(_:)` と同じ。
  func edit(_ request: EditRequest) async throws(AIProviderError) -> RefinementResponse
}
