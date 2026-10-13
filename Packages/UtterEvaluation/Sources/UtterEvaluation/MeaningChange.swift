/// 「重大な意味改変」の種類（9章）。判定は人が docs/精度評価.md の手順で行い、結果を記録する。
public enum MeaningChange: String, Codable, Hashable, Sendable, CaseIterable {
  /// 肯定と否定が入れ替わった
  case negationFlipped
  /// 数値・日時・金額・数量が変わった
  case numberChanged
  /// 人名・製品名・地名・コード上の識別子などの固有名詞が別の語に変わった
  case properNounChanged
  /// 発話にない内容（回答・補足・指示の実行結果など）が加わった
  case contentAdded
  /// 発話の内容が欠落した（フィラー・言い直し前の語の除去を除く）
  case contentOmitted
  /// 主語・目的語・依頼と報告などの関係が入れ替わった
  case relationChanged
}
