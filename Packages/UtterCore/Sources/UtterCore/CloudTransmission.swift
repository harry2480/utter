/// 端末の外へ送信する内容と送信先の組み合わせ（7章, 2.2節）。
///
/// それぞれ別の同意を必要とする。値には送信する本文を持たない。
public enum CloudTransmission: Hashable, Sendable, CaseIterable {
  /// AI 整形のため、STT テキストをクラウド AI へ送信する
  case textRefinement(CloudAIProvider)
  /// クラウド STT へ音声を送信する
  case speechRecognition
  /// Edit のため、選択テキストをクラウド AI へ送信する（v1.1）
  case editSelection(CloudAIProvider)

  public static var allCases: [CloudTransmission] {
    CloudAIProvider.allCases.map(Self.textRefinement)
      + [.speechRecognition]
      + CloudAIProvider.allCases.map(Self.editSelection)
  }
}
