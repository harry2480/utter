import UtterCore
import UtterText

/// STT テキストから整形プロバイダーへの入力を組み立てる（TXT-03, CTX-01, CTX-02, CTX-03）。
///
/// ユーザー辞書の置換ルールを適用し、辞書語を添え、前面アプリの bundle ID からスタイル区分を決める。
/// bundle ID はスタイルの判定にだけ使い、組み立てた `RefinementRequest` には含めない（CTX-03）。
/// クラウド整形でもローカルへの退避でも、同じ置換後の本文が使われる。
public struct RefinementRequestPreparer: Sendable {
  public let dictionary: UserDictionary
  public let styleResolver: AppStyleResolver
  /// 定義順に重複を除いた辞書語
  private let dictionaryTerms: [String]

  public init(dictionary: UserDictionary, styleResolver: AppStyleResolver) {
    self.dictionary = dictionary
    self.styleResolver = styleResolver
    var seen: Set<String> = []
    dictionaryTerms = dictionary.terms.map(\.spelling).filter { seen.insert($0).inserted }
  }

  /// 整形の入力を組み立てる。
  ///
  /// - Raw モードでは置換ルールを適用せず、STT 結果をそのまま使う。要件に明記がないため、
  ///   整形しないモードとして手を加えない側に倒した判断。Natural / Structured から Raw の結果へ退避する場合は、置換後の本文になる
  /// - 辞書語は定義順に、重複を除いて入れる
  ///
  /// - Parameters:
  ///   - transcript: STT テキスト
  ///   - mode: 整形モード
  ///   - frontmostBundleID: 前面アプリの bundle ID。特定できなければ `nil`（スタイルは `standard`）
  public func prepare(
    transcript: String, mode: RefinementMode, frontmostBundleID: String?
  ) -> RefinementRequest {
    let text = mode == .raw ? transcript : dictionary.applyingReplacements(to: transcript)
    return RefinementRequest(
      text: text,
      mode: mode,
      style: styleResolver.style(forBundleID: frontmostBundleID),
      dictionaryTerms: dictionaryTerms)
  }
}
