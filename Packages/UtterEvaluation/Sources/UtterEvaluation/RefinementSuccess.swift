/// 自己訂正の注釈（9章）。言い直す前の語と、言い直した後の語。
///
/// どちらも正解（`EvaluationSample.reference`）に含まれる表記で書く。
public struct SelfCorrection: Codable, Hashable, Sendable {
  /// 言い直す前の語。整形結果に残ってはいけない（「いや」などの言い直しの合図を含めてもよい）
  public let retracted: String
  /// 言い直した後の語。整形結果に残っていなければならない
  public let corrected: String

  public init(retracted: String, corrected: String) {
    self.retracted = retracted
    self.corrected = corrected
  }
}

/// 整形結果のフィラー除去・自己訂正の成否（9章、TXT-02）。1発話の注釈について発話単位で判定する。
///
/// 正解・整形結果・注釈の語には、CER と同じ正規化（`TextNormalizer`）を適用してから照合する。
/// 注釈の語どうしが重なる場合（「えー」と「えーと」、「四時」と「四時半」）に短い語を二重に数えないよう、
/// 発話内のすべての注釈の語を長い順に照合し、照合した箇所は短い語の照合に使わない。
/// 規則は docs/精度評価.md の「フィラー除去成功率・自己訂正成功率」と一致させる。
public struct RefinementSuccess: Sendable {
  /// 正規化後のフィラー
  private let fillers: Set<String>
  /// 正規化後の言い直す前の語
  private let retracted: Set<String>
  /// 正規化後の語ごとの、除くべき件数（フィラーと言い直す前の語）
  private let removals: [String: Int]
  /// 正規化後の語ごとの、残すべき件数。言い直した後の語の件数から、同じ語を言い直す前の語とした件数を引く
  /// （「赤、じゃなくて青、いや緑」の「青」は、さらに言い直されたので残さなくてよい）
  private let keeps: [String: Int]
  /// 照合する語（長い順）
  private let words: [String]
  private let normalizer: TextNormalizer

  public init(
    fillers: [String], selfCorrections: [SelfCorrection],
    normalizer: TextNormalizer = TextNormalizer()
  ) {
    let normalizedFillers = fillers.map(normalizer.normalize)
    let normalizedRetracted = selfCorrections.map { normalizer.normalize($0.retracted) }
    let normalizedCorrected = selfCorrections.map { normalizer.normalize($0.corrected) }
    let removals = Self.tally(normalizedFillers + normalizedRetracted)
    self.fillers = Set(normalizedFillers)
    self.retracted = Set(normalizedRetracted)
    self.removals = removals
    self.keeps = Self.tally(normalizedCorrected).reduce(into: [:]) { keeps, entry in
      let remaining = entry.value - removals[entry.key, default: 0]
      if remaining > 0 { keeps[entry.key] = remaining }
    }
    self.words = Set(normalizedFillers + normalizedRetracted + normalizedCorrected)
      .filter { !$0.isEmpty }
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    self.normalizer = normalizer
  }

  /// 注釈したフィラーがすべて整形結果から除かれたか。
  ///
  /// 各フィラーの整形結果での出現回数が「正解での出現回数 − 除くべき件数」以下なら成功。
  public func fillersRemoved(reference: String, refined: String) -> Bool {
    let inReference = occurrences(in: reference)
    let inRefined = occurrences(in: refined)
    return fillers.allSatisfy { isRemoved($0, inReference: inReference, inRefined: inRefined) }
  }

  /// 言い直す前の語が整形結果に残らず、言い直した後の語が残ったか。
  ///
  /// 言い直す前の語はフィラーと同じ基準で除かれていること、言い直した後の語は
  /// 整形結果に残すべき件数以上現れることを成功とする。
  public func selfCorrected(reference: String, refined: String) -> Bool {
    let inReference = occurrences(in: reference)
    let inRefined = occurrences(in: refined)
    return retracted.allSatisfy { isRemoved($0, inReference: inReference, inRefined: inRefined) }
      && keeps.allSatisfy { word, count in inRefined[word, default: 0] >= count }
  }

  /// 正解に注釈の件数だけ含まれていない語。フィラー・言い直す前の語・言い直した後の語の区別つき。
  ///
  /// 除くべき件数と残すべき件数の合計が、正解での出現回数を超える語を不備とする。
  func missingWords(in reference: String) -> (fillers: Bool, selfCorrections: Bool) {
    let inReference = occurrences(in: reference)
    var missing = (fillers: false, selfCorrections: false)
    for word in Set(removals.keys).union(keeps.keys)
    where inReference[word, default: 0] < removals[word, default: 0] + keeps[word, default: 0] {
      if fillers.contains(word) && !retracted.contains(word) && keeps[word] == nil {
        missing.fillers = true
      } else {
        missing.selfCorrections = true
      }
    }
    return missing
  }

  private func isRemoved(_ word: String, inReference: [String: Int], inRefined: [String: Int])
    -> Bool
  {
    inRefined[word, default: 0] <= inReference[word, default: 0] - removals[word, default: 0]
  }

  /// 正規化した文字列での、注釈の語ごとの出現回数。長い語から重ならずに照合し、照合済みの箇所は以降の語に使わない。
  func occurrences(in text: String) -> [String: Int] {
    var characters = Array(normalizer.normalize(text)).map(Optional.some)
    var counts: [String: Int] = [:]
    for word in words {
      let needle = Array(word)
      guard characters.count >= needle.count else { continue }
      var index = 0
      while index <= characters.count - needle.count {
        let range = index..<index + needle.count
        if characters[range].elementsEqual(needle, by: { $0 == $1 }) {
          counts[word, default: 0] += 1
          for position in range { characters[position] = nil }
          index += needle.count
        } else {
          index += 1
        }
      }
    }
    return counts
  }

  private static func tally(_ words: [String]) -> [String: Int] {
    words.reduce(into: [:]) { counts, word in counts[word, default: 0] += 1 }
  }
}
