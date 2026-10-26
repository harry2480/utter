/// Edit の応答が編集案として使えるかを判定する（AC-14, TXT-04）。
///
/// 編集では指示に応じて数字・URL・語の数が変わるのが正当なため、整形の検証（`RefinementValidator`）のうち
/// 保護対象の保持・文字数比・文字の重なり・質問への回答は判定しない。編集案は差分プレビューで利用者が確認してから
/// 確定するため（2.2節）、ここでは編集案として明らかに使えない応答だけを除く。
public struct EditValidator: Sendable {
  /// 整形の前置きの句に、編集で現れうる前置きの句を足したもの
  public static let defaultPreamblePhrases =
    RefinementValidationConfiguration.defaultPreamblePhrases + [
      "編集しました", "書き換えました", "編集後の文章", "書き換えた文章", "書き換え後の文章", "Here's the edited",
      "Here's the revised",
    ]

  /// 選択テキストと音声指示になく、応答の先頭にあれば編集以外の出力とみなす前置きの句
  public let preamblePhrases: [String]
  /// 選択テキストと音声指示になく、応答のどこかにあれば編集以外の出力とみなす拒否の句
  public let refusalPhrases: [String]

  public init(
    preamblePhrases: [String] = EditValidator.defaultPreamblePhrases,
    refusalPhrases: [String] = RefinementValidationConfiguration.defaultRefusalPhrases
  ) throws(RefinementValidationConfigurationError) {
    guard !preamblePhrases.contains(where: \.isEmpty), !refusalPhrases.contains(where: \.isEmpty)
    else {
      throw .emptyPhrase
    }
    self.preamblePhrases = preamblePhrases
    self.refusalPhrases = refusalPhrases
  }

  public init() {
    preamblePhrases = Self.defaultPreamblePhrases
    refusalPhrases = RefinementValidationConfiguration.defaultRefusalPhrases
  }

  /// 応答に問題があれば最初に見つかった理由を返し、問題がなければ `nil` を返す。
  public func validate(_ edited: String, for request: EditRequest) -> EditValidationFailure? {
    // 空の編集案は削除として扱えるが、打ち切り・拒否の応答も空になる（ClaudeProvider）ため区別できない。
    // 選択テキストの削除に AI は要らないため、空応答は使わない
    if edited.allSatisfy(\.isWhitespace) {
      return .empty
    }
    let source = request.selection + "\n" + request.instruction
    if RefinementValidator.containsAddedPhrase(
      preamblePhrases, in: edited, original: source, prefixOnly: true)
      || RefinementValidator.containsAddedPhrase(
        refusalPhrases, in: edited, original: source, prefixOnly: false)
    {
      return .preambleOrRefusal
    }
    // 編集案と同じく前後の改行だけを除いて比べ、インデントだけの変更は変更として扱う
    if EditRouter.trimmingNewlines(edited) == EditRouter.trimmingNewlines(request.selection) {
      return .unchanged
    }
    return nil
  }
}

/// Edit の応答を編集案として使えないと判定した理由。本文は持たない。
public enum EditValidationFailure: Hashable, Sendable, CaseIterable {
  /// 空応答
  case empty
  /// 前置き・拒否文などの編集以外の出力
  case preambleOrRefusal
  /// 選択テキストから変わっていない。書き換えではない音声指示には選択テキストをそのまま返させるため、
  /// 指示を実行しなかった場合もここに入る（TXT-04）
  case unchanged
}
