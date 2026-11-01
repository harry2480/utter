import Foundation

/// フォーカス中の入力欄を探す順番（INS-01）。AX の問い合わせを差し替えてテストできるよう、要素の型を問わない。
///
/// 1. システム全体の要素の `AXFocusedUIElement`
/// 2. システム全体の要素の `AXFocusedApplication` の `AXFocusedUIElement`
/// 3. 最前面のアプリ（NSWorkspace）の要素の `AXFocusedUIElement`
///
/// macOS 27.0.1 では、1・2 の問い合わせが `kAXErrorCannotComplete`（-25204）を返し、アプリの要素への問い合わせは
/// 通ることがある（#239, docs/Phase0検証-Accessibility挿入成功率.md）。3 はそのための代わりの経路。
/// どの経路で取った要素も、記録と挿入直前の再検証（`TargetIdentityRegistry`）では同じに扱う。
struct FocusedElementLookup<Element> {
  /// 問い合わせの結果。失敗したときは AX のエラーコードだけを持つ（値の中身は持たない）
  enum Query {
    case found(Element)
    case failed(code: Int32)
  }

  /// どの経路で取れたか
  enum Route: Hashable, Sendable {
    case systemWide
    case systemWideFocusedApplication
    case frontmostApplication
  }

  struct Result {
    let element: Element
    let route: Route
    /// 代わりの経路に進む前に失敗した問い合わせのエラーコード（ログ用）
    let failureCodes: [Int32]
  }

  var systemFocusedElement: () -> Query
  var systemFocusedApplication: () -> Query
  /// 最前面のアプリの要素。取れなければ `nil`
  var frontmostApplication: () -> Element?
  /// アプリの要素の `AXFocusedUIElement`
  var focusedElement: (Element) -> Query

  func resolve() -> Result? {
    var codes: [Int32] = []
    switch systemFocusedElement() {
    case .found(let element):
      return Result(element: element, route: .systemWide, failureCodes: codes)
    case .failed(let code):
      codes.append(code)
    }
    switch systemFocusedApplication() {
    case .found(let app):
      switch focusedElement(app) {
      case .found(let element):
        return Result(element: element, route: .systemWideFocusedApplication, failureCodes: codes)
      case .failed(let code):
        codes.append(code)
      }
    case .failed(let code):
      codes.append(code)
    }
    guard let app = frontmostApplication(), case .found(let element) = focusedElement(app) else {
      return nil
    }
    return Result(element: element, route: .frontmostApplication, failureCodes: codes)
  }
}
