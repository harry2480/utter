import UtterText

/// ルールベースのローカル整形（Local Basic, AI-03）。
///
/// オフラインで使え、失敗しないため、クラウド整形の退避先にも使う（4.1節）。
/// チャット（`concise`）とターミナル（`command`）では文末の「。」を補わず、
/// ターミナルでは Structured でも箇条書きや段落を作らない。
public struct LocalBasicRefiner: LocalRefiner {
  public init() {}

  public func refine(_ request: RefinementRequest) -> String {
    let formatter = BasicFormatter(
      dictionaryTerms: request.dictionaryTerms,
      options: BasicFormatter.Options(
        addsSentenceEnd: request.style != .concise && request.style != .command))
    switch request.mode {
    case .raw:
      return request.text
    case .natural:
      return formatter.natural(request.text)
    case .structured:
      return request.style == .command
        ? formatter.natural(request.text) : formatter.structured(request.text)
    }
  }
}
