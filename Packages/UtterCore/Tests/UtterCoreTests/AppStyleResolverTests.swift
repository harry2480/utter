import Testing

@testable import UtterCore

struct AppStyleResolverTests {
  @Test(
    "CTX-01: 既定の対応表で前面アプリからスタイルを選ぶ",
    arguments: [
      ("com.hnc.Discord", RefinementStyle.concise),
      ("com.tinyspeck.slackmacgap", .concise),
      ("com.apple.mail", .polite),
      ("com.apple.dt.Xcode", .technical),
      ("com.microsoft.VSCode", .technical),
      ("com.apple.Terminal", .command),
      ("com.googlecode.iterm2", .command),
      ("com.apple.iWork.Pages", .document),
      ("com.microsoft.Word", .document),
    ])
  func resolvesBuiltInStyles(_ bundleID: String, _ expected: RefinementStyle) {
    #expect(AppStyleResolver().style(forBundleID: bundleID) == expected)
  }

  @Test(
    "CTX-01: 未知のアプリ・前面アプリ不明は standard",
    arguments: ["com.example.unknown", "", nil] as [String?])
  func unknownAppIsStandard(_ bundleID: String?) {
    #expect(AppStyleResolver().style(forBundleID: bundleID) == .standard)
  }

  @Test("CTX-01: bundle ID は大文字・小文字を区別せずに照合する")
  func matchesCaseInsensitively() {
    let resolver = AppStyleResolver()

    #expect(resolver.style(forBundleID: "COM.APPLE.TERMINAL") == .command)
    #expect(resolver.style(forBundleID: "com.hnc.discord") == .concise)
  }

  @Test("CTX-01: 既定の対応表は standard 以外のすべての区分を含み、bundle ID の重複がない")
  func builtInTableIsConsistent() {
    let groups = AppStyleResolver.builtInGroups
    let allIDs = groups.flatMap(\.bundleIDs).map { $0.lowercased() }

    #expect(Set(allIDs).count == allIDs.count)
    #expect(Set(groups.map(\.style)) == Set(RefinementStyle.allCases).subtracting([.standard]))
    #expect(AppStyleResolver.builtInStyles.count == allIDs.count)
    #expect(!AppStyleResolver.builtInStyles.values.contains(.standard))
  }

  @Test("CTX-02: 利用者のアプリ別上書きは既定の対応表より優先される", arguments: RefinementStyle.allCases)
  func overrideTakesPrecedence(_ style: RefinementStyle) {
    var resolver = AppStyleResolver()
    resolver.setOverride(style, forBundleID: "com.apple.Terminal")

    #expect(resolver.style(forBundleID: "com.apple.Terminal") == style)
  }

  @Test("CTX-02: 未知のアプリにも上書きを設定できる")
  func overrideUnknownApp() {
    let resolver = AppStyleResolver(overrides: ["com.example.Notes": .document])

    #expect(resolver.style(forBundleID: "com.example.notes") == .document)
    #expect(resolver.style(forBundleID: "com.example.other") == .standard)
  }

  @Test("CTX-02: 上書きを外すと既定の対応表に戻る")
  func removingOverrideRestoresDefault() {
    var resolver = AppStyleResolver(overrides: ["com.hnc.Discord": .polite])
    #expect(resolver.style(forBundleID: "com.hnc.Discord") == .polite)

    resolver.setOverride(nil, forBundleID: "COM.HNC.DISCORD")

    #expect(resolver.overrides.isEmpty)
    #expect(resolver.style(forBundleID: "com.hnc.Discord") == .concise)
  }

  @Test("CTX-02: 上書きは大文字・小文字を区別せず、最後に設定した値が使われる")
  func overrideIsCaseInsensitive() {
    var resolver = AppStyleResolver()
    resolver.setOverride(.polite, forBundleID: "com.apple.terminal")
    resolver.setOverride(.document, forBundleID: "COM.APPLE.TERMINAL")

    #expect(resolver.overrides == ["com.apple.terminal": .document])
    #expect(resolver.style(forBundleID: "com.apple.Terminal") == .document)
  }

  @Test("CTX-02: 大文字・小文字だけが異なる初期値は辞書順で先のキーを採る")
  func duplicateKeysAreResolvedDeterministically() {
    let resolver = AppStyleResolver(
      defaultStyles: [:], overrides: ["com.example.app": .polite, "COM.EXAMPLE.APP": .command])

    #expect(resolver.style(forBundleID: "com.example.app") == .command)
  }

  @Test("CTX-01: 既定の対応表を差し替えられる")
  func customDefaultStyles() {
    let resolver = AppStyleResolver(defaultStyles: ["com.example.Chat": .concise])

    #expect(resolver.style(forBundleID: "com.example.chat") == .concise)
    #expect(resolver.style(forBundleID: "com.apple.Terminal") == .standard)
  }
}
