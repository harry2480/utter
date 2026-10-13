import Foundation

/// CER を計算する前に正解と認識結果へ同じように適用する正規化（9章）。
///
/// 規則は docs/精度評価.md の「CER の正規化規則」と一致させる。
/// 1. Unicode NFKC で全角英数字・記号を半角に、半角カナを全角にそろえる
/// 2. 英字を小文字にそろえる
/// 3. 漢数字をアラビア数字にそろえる（`KanjiNumeralConverter`）
/// 4. 句読点・括弧などの約物と空白を除く
public struct TextNormalizer: Sendable {
  public init() {}

  public func normalize(_ text: String) -> String {
    let widthNormalized = text.precomposedStringWithCompatibilityMapping.lowercased()
    let numeralNormalized = KanjiNumeralConverter.convert(widthNormalized)
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: numeralNormalized.unicodeScalars.filter { !Self.isIgnored($0) })
    return String(scalars)
  }

  private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isWhitespace {
      return true
    }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation:
      return true
    default:
      return false
    }
  }
}
