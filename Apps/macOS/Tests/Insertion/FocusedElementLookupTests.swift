import Testing

struct FocusedElementLookupTests {
  /// AX の要素の代わり
  private struct Element: Equatable {
    let name: String
  }

  private let field = Element(name: "field")
  private let app = Element(name: "app")
  private let frontmost = Element(name: "frontmost")
  private let cannotComplete: Int32 = -25204

  private func lookup(
    system: FocusedElementLookup<Element>.Query,
    focusedApplication: FocusedElementLookup<Element>.Query,
    frontmost: Element?,
    focusedElements: [String: FocusedElementLookup<Element>.Query] = [:]
  ) -> FocusedElementLookup<Element> {
    FocusedElementLookup(
      systemFocusedElement: { system },
      systemFocusedApplication: { focusedApplication },
      frontmostApplication: { frontmost },
      focusedElement: { focusedElements[$0.name] ?? .failed(code: -25212) })
  }

  @Test("INS-01: システム全体から入力欄を取れれば、それを使う")
  func systemWide() throws {
    let result = try #require(
      lookup(system: .found(field), focusedApplication: .found(app), frontmost: frontmost)
        .resolve())

    #expect(result.element == field)
    #expect(result.route == .systemWide)
    #expect(result.failureCodes.isEmpty)
  }

  @Test("INS-01: システム全体の入力欄が取れなければ、フォーカス中のアプリから取る")
  func systemWideFocusedApplication() throws {
    let result = try #require(
      lookup(
        system: .failed(code: -25212), focusedApplication: .found(app), frontmost: frontmost,
        focusedElements: ["app": .found(field)]
      ).resolve())

    #expect(result.element == field)
    #expect(result.route == .systemWideFocusedApplication)
  }

  @Test("INS-01, #239: macOS 27 でシステム全体への問い合わせが -25204 で失敗したら、最前面のアプリから取る")
  func frontmostFallback() throws {
    let result = try #require(
      lookup(
        system: .failed(code: cannotComplete), focusedApplication: .failed(code: cannotComplete),
        frontmost: frontmost, focusedElements: ["frontmost": .found(field)]
      ).resolve())

    #expect(result.element == field)
    #expect(result.route == .frontmostApplication)
    #expect(result.failureCodes == [cannotComplete, cannotComplete])
  }

  @Test("INS-01: フォーカス中のアプリから取れなくても、最前面のアプリから取る")
  func focusedApplicationWithoutElement() throws {
    let result = try #require(
      lookup(
        system: .failed(code: cannotComplete), focusedApplication: .found(app),
        frontmost: frontmost,
        focusedElements: ["app": .failed(code: cannotComplete), "frontmost": .found(field)]
      ).resolve())

    #expect(result.route == .frontmostApplication)
    #expect(result.failureCodes == [cannotComplete, cannotComplete])
  }

  @Test("INS-01: どの経路でも取れなければ nil（挿入先がないとして扱う）")
  func notFound() {
    #expect(
      lookup(
        system: .failed(code: cannotComplete), focusedApplication: .failed(code: cannotComplete),
        frontmost: nil
      ).resolve() == nil)
    #expect(
      lookup(
        system: .failed(code: cannotComplete), focusedApplication: .failed(code: cannotComplete),
        frontmost: frontmost, focusedElements: ["frontmost": .failed(code: -25212)]
      ).resolve() == nil)
  }
}
