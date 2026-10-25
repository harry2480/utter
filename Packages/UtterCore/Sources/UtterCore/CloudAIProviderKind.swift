/// 文章の送信先となるクラウド AI プロバイダーの種類（AI-01）。
///
/// `AIProvider` の実装ではなく、同意や設定で送信先を指す識別子。
///
/// 同意は送信先ごとに取得するため、プロバイダーを区別する（AI-04, 7章）。
public enum CloudAIProviderKind: Hashable, Sendable, CaseIterable, Codable {
  /// Claude API
  case claude
  /// ChatGPT（OpenAI）。Sign in with ChatGPT と、その代替の OpenAI API キー方式（要件定義 11章）の両方を指す。
  /// どちらも OpenAI へ送るため、同意は同じ送信先として扱う
  case chatGPT
}
