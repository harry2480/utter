/// クラウド AI へ送る整形・Edit のプロンプト（TXT-04, CTX-03, AC-14）。
///
/// 指示（`system`）と整形対象（`user`）を分ける。`user` には発話と辞書語だけを区切りタグで囲んで入れ、
/// 指示は `system` にだけ書く。プロバイダー実装はこの2つをそれぞれの API の
/// システム指示・ユーザー入力に割り当てる。
/// Edit では `user` に選択テキスト・音声指示・辞書語を入れる。
/// 文脈を勝手に足せないよう、値は `RefinementPromptBuilder` と `EditPromptBuilder` からだけ作る。
public struct RefinementPrompt: Hashable, Sendable {
  /// 整形の指示
  public let system: String
  /// 区切りタグで囲んだ発話と辞書語。指示は含めない
  public let user: String
  /// 区切りタグの名前に付けた、発話と辞書語に含まれない文字列
  public let nonce: String
}

// 発話本文と辞書語をログに出さないよう、文字列表現とリフレクションには文字数だけを出す。
extension RefinementPrompt: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RefinementPrompt(systemLength: \(system.count), userLength: \(user.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["systemLength": system.count, "userLength": user.count])
  }
}
