import Foundation

/// CER を計算する前に正解と認識結果へ同じように適用する正規化（9章）。
///
/// 規則は docs/精度評価.md の「CER の正規化規則」と一致させる。
/// 1. Unicode NFKC で全角英数字・記号を半角に、半角カナを全角にそろえる
/// 2. 英字を小文字にそろえる
/// 3. 数字の表記をアラビア数字にそろえる（`NumeralNormalizer`）
/// 4. 句読点・括弧・引用符・ダッシュ類・空白・不可視の書式文字を除く。数字に挟まれた `.` `:` と、
///    `%` `#` `&` `@` `*` `/` `\` は意味を持つため残す
public struct TextNormalizer: Sendable {
  /// 約物でも残す記号
  static let keptPunctuation: Set<Character> = ["%", "#", "&", "@", "*", "/", "\\"]
  /// 数字に挟まれたときだけ残す記号（小数点・時刻）
  static let keptBetweenDigits: Set<Character> = [".", ":"]
  /// 約物ではないが除く記号（全角チルダ `～` は NFKC で `~` になるため、波ダッシュ `〜` とそろえる）
  static let removedSymbols: Set<Character> = ["~"]

  public init() {}

  public func normalize(_ text: String) -> String {
    let widthNormalized = text.precomposedStringWithCompatibilityMapping.lowercased()
    let characters = Array(NumeralNormalizer.convert(widthNormalized))
    var result = ""
    for index in characters.indices where !Self.isIgnored(at: index, in: characters) {
      result.append(characters[index])
    }
    return result
  }

  private static func isIgnored(at index: Int, in characters: [Character]) -> Bool {
    let character = characters[index]
    if keptBetweenDigits.contains(character), index > 0, index + 1 < characters.count,
      characters[index - 1].isNumber, characters[index + 1].isNumber
    {
      return false
    }
    if keptPunctuation.contains(character) {
      return false
    }
    if removedSymbols.contains(character) || character.isWhitespace {
      return true
    }
    return character.unicodeScalars.allSatisfy(isIgnored)
  }

  private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation, .format:
      return true
    default:
      return scalar.properties.isWhitespace
    }
  }
}
