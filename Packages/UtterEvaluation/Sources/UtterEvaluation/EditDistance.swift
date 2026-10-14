/// 文字（書記素クラスター）単位の編集距離（置換・挿入・削除の最小回数）。
enum EditDistance {
  static func between(_ reference: String, _ hypothesis: String) -> Int {
    let source = Array(reference)
    let target = Array(hypothesis)
    guard !source.isEmpty else { return target.count }
    guard !target.isEmpty else { return source.count }

    var previous = Array(0...target.count)
    var current = [Int](repeating: 0, count: target.count + 1)
    for i in 1...source.count {
      current[0] = i
      for j in 1...target.count {
        let substitution = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
        current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
      }
      swap(&previous, &current)
    }
    return previous[target.count]
  }
}
