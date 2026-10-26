import UtterCore

/// AX 要素などを不透明な `InsertionTargetID` に対応づける（INS-01）。
///
/// 録音開始時に記録した要素と同じ要素（`isSame` で比べる）には同じ識別子を返し、別の要素には新しい識別子を返す。
/// 持つ要素は、記録した要素と直近に調べた要素の2つだけにする。
struct TargetIdentityRegistry<Element> {
  private let isSame: (Element, Element) -> Bool
  private let makeID: () -> InsertionTargetID
  private var recorded: (element: Element, id: InsertionTargetID)?
  private var latest: (element: Element, id: InsertionTargetID)?

  init(
    isSame: @escaping (Element, Element) -> Bool, makeID: @escaping () -> InsertionTargetID
  ) {
    self.isSame = isSame
    self.makeID = makeID
  }

  /// 録音開始時の要素を記録する。前に記録した要素は忘れる
  mutating func record(_ element: Element) -> InsertionTargetID {
    let id = makeID()
    recorded = (element, id)
    latest = nil
    return id
  }

  /// 記録をやめる（フォーカス中の要素が取れなかった場合など）
  mutating func clear() {
    recorded = nil
    latest = nil
  }

  /// 挿入直前の要素の識別子。記録した要素と同じなら記録時の識別子を返す
  mutating func identify(_ element: Element) -> InsertionTargetID {
    if let recorded, isSame(recorded.element, element) {
      return recorded.id
    }
    if let latest, isSame(latest.element, element) {
      return latest.id
    }
    let id = makeID()
    latest = (element, id)
    return id
  }

  /// 識別子に対応する要素。記録した要素か直近に調べた要素でなければ `nil`
  func element(for id: InsertionTargetID) -> Element? {
    if let recorded, recorded.id == id { return recorded.element }
    if let latest, latest.id == id { return latest.element }
    return nil
  }
}
