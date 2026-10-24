import Foundation
import Testing

@testable import UtterCore

struct SiteHostTests {
  @Test(
    "CTX-02: ホスト名は小文字・末尾ドットなし・先頭の www. なしにそろえる",
    arguments: [
      ("example.com", "example.com"),
      ("Example.COM", "example.com"),
      ("example.com.", "example.com"),
      ("www.example.com", "example.com"),
      ("WWW.Example.Com.", "example.com"),
      ("  docs.example.com\n", "docs.example.com"),
      ("mail.example.com", "mail.example.com"),
      ("www.www.example.com", "www.example.com"),
      ("www.com", "www.com"),
      ("localhost", "localhost"),
      ("192.168.0.1", "192.168.0.1"),
      ("xn--wgv71a119e.jp", "xn--wgv71a119e.jp"),
    ])
  func normalizesHost(_ input: String, _ expected: String) {
    #expect(SiteHost(host: input)?.rawValue == expected)
  }

  @Test(
    "CTX-02: ホスト名として判定できない値からは作らない",
    arguments: [
      "", " ", ".", "..", "a..b", ".example.com", "example.com..",
      "example.com:8080", "https://example.com", "example.com/path", "example.com?q=1",
      "user@example.com", "[::1]", "::1", "exa mple.com", "exa%41mple.com", "exa_mple.com",
      "-example.com", "example-.com",
      "日本語.jp", "ex\u{212A}ample.com",  // ケルビン記号は小文字化で k になるため通さない
      String(repeating: "a", count: 64) + ".com",
    ])
  func rejectsInvalidHost(_ input: String) {
    #expect(SiteHost(host: input) == nil)
  }

  @Test("CTX-02: ラベルは63文字、名前は253文字まで")
  func lengthLimits() {
    let label63 = String(repeating: "a", count: 63)
    #expect(SiteHost(host: label63 + ".com") != nil)

    let name253 = [label63, label63, label63, String(repeating: "b", count: 61)].joined(
      separator: ".")
    #expect(name253.count == 253)
    #expect(SiteHost(host: name253) != nil)
    #expect(SiteHost(host: name253 + ".") != nil)
    #expect(SiteHost(host: name253 + "c") == nil)
  }

  @Test(
    "CTX-02 / CTX-03: URL からはホスト名だけを取り、ポート・パス・クエリ・利用者情報は捨てる",
    arguments: [
      ("https://www.Example.com:8443/inbox/123?token=secret#frag", "example.com"),
      ("http://user:password@mail.example.com/", "mail.example.com"),
      ("https://example.com./", "example.com"),
      ("HTTPS://EXAMPLE.COM", "example.com"),
    ])
  func extractsHostFromURL(_ urlString: String, _ expected: String) throws {
    let url = try #require(URL(string: urlString))
    let host = try #require(SiteHost(url: url))

    #expect(host.rawValue == expected)
  }

  @Test("CTX-02: 国際化ドメイン名は Punycode の形で扱う")
  func internationalizedDomainFromURL() throws {
    let url = try #require(URL(string: "https://日本語.jp/path"))

    #expect(SiteHost(url: url)?.rawValue == "xn--wgv71a119e.jp")
  }

  @Test(
    "CTX-02: http / https 以外とホスト名のない URL からは作らない",
    arguments: [
      "about:blank", "file:///tmp/a.html", "chrome://settings", "ftp://example.com/",
      "https://[::1]:8080/", "data:text/plain,hello",
    ])
  func rejectsNonWebURL(_ urlString: String) throws {
    let url = try #require(URL(string: urlString))

    #expect(SiteHost(url: url) == nil)
  }

  @Test("CTX-03: 文字列表現とリフレクションにホスト名を含めない")
  func doesNotExposeHost() throws {
    let host = try #require(SiteHost(host: "secret-site.example.com"))

    for text in [
      String(describing: host), String(reflecting: host), "\(host)",
      String(describing: Optional(host)),
    ] {
      #expect(!text.contains("secret-site"))
    }
    #expect(Mirror(reflecting: host).children.isEmpty)
  }
}

struct SiteStyleResolverTests {
  private static let host = SiteHost(host: "chat.example.com")!

  @Test("CTX-02: サイト単位の識別は既定で許可しない")
  func disallowedByDefault() {
    let resolver = SiteStyleResolver(overrides: ["chat.example.com": .concise])

    #expect(!resolver.isSiteIdentificationAllowed)
    #expect(!resolver.needsSiteHost)
    #expect(resolver.style(forSiteHost: Self.host) == nil)
  }

  @Test("CTX-02: 許可がなければホスト名を受け取ってもサイト別の上書きを使わない")
  func ignoresHostWithoutPermission() {
    let context = ContextStyleResolver(
      site: SiteStyleResolver(overrides: ["chat.example.com": .concise]))

    #expect(
      context.style(forBundleID: "com.apple.Safari", siteHost: Self.host) == .standard)
    #expect(context.style(forBundleID: "com.apple.mail", siteHost: Self.host) == .polite)
  }

  @Test("CTX-02: 許可があれば一致するサイトの上書きを使う", arguments: RefinementStyle.allCases)
  func matchesWithPermission(_ style: RefinementStyle) {
    let resolver = SiteStyleResolver(
      isSiteIdentificationAllowed: true, overrides: ["chat.example.com": style])

    #expect(resolver.needsSiteHost)
    #expect(resolver.style(forSiteHost: Self.host) == style)
    #expect(resolver.style(forSiteHost: SiteHost(host: "other.example.com")) == nil)
    #expect(resolver.style(forSiteHost: nil) == nil)
  }

  @Test("CTX-02: 許可を外すと使わなくなり、上書きの一覧は残る")
  func revokingPermissionKeepsOverrides() {
    var resolver = SiteStyleResolver(
      isSiteIdentificationAllowed: true, overrides: ["chat.example.com": .concise])
    resolver.isSiteIdentificationAllowed = false

    #expect(resolver.style(forSiteHost: Self.host) == nil)
    #expect(resolver.overrides == [Self.host: .concise])

    resolver.isSiteIdentificationAllowed = true
    #expect(resolver.style(forSiteHost: Self.host) == .concise)
  }

  @Test("CTX-02: 上書きが1件もなければホスト名を取り出す必要はない")
  func noOverridesNeedsNoHost() {
    #expect(!SiteStyleResolver(isSiteIdentificationAllowed: true).needsSiteHost)
  }

  @Test("CTX-02: 上書きのキーも同じ規則で正規化し、URL と照合する")
  func normalizesOverrideKeys() throws {
    let resolver = SiteStyleResolver(
      isSiteIdentificationAllowed: true,
      overrides: ["WWW.Docs.Example.COM.": .document, "bad host": .command, "": .polite])
    let url = try #require(URL(string: "https://docs.example.com:443/d/abc?usp=sharing"))

    #expect(resolver.overrides.count == 1)
    #expect(resolver.style(forSiteHost: SiteHost(url: url)) == .document)
  }

  @Test("CTX-02: 正規化後に重なるキーは Unicode スカラー順で先のキーを採る")
  func duplicateKeysAreResolvedDeterministically() {
    // "EXAMPLE.COM" < "example.com" < "www.example.com" の順。
    let resolver = SiteStyleResolver(
      isSiteIdentificationAllowed: true,
      overrides: ["www.example.com": .polite, "example.com": .concise, "EXAMPLE.COM": .command])

    #expect(resolver.overrides == [SiteHost(host: "example.com")!: .command])
  }

  @Test("CTX-02: サブドメインには親ドメインの上書きを当てない")
  func subdomainIsDistinctSite() {
    let resolver = SiteStyleResolver(
      isSiteIdentificationAllowed: true, overrides: ["example.com": .polite])

    #expect(resolver.style(forSiteHost: SiteHost(host: "www.example.com")) == .polite)
    #expect(resolver.style(forSiteHost: SiteHost(host: "mail.example.com")) == nil)
    #expect(resolver.style(forSiteHost: SiteHost(host: "example.com.evil.test")) == nil)
  }

  @Test("CTX-02: 上書きを設定・解除できる")
  func setAndRemoveOverride() {
    var resolver = SiteStyleResolver(isSiteIdentificationAllowed: true)
    resolver.setOverride(.technical, forSiteHost: Self.host)
    #expect(resolver.style(forSiteHost: Self.host) == .technical)

    resolver.setOverride(nil, forSiteHost: Self.host)
    #expect(resolver.overrides.isEmpty)
    #expect(resolver.style(forSiteHost: Self.host) == nil)
  }

  @Test("CTX-03: 文字列表現とリフレクションにホスト名を含めない")
  func doesNotExposeHosts() {
    let site = SiteStyleResolver(
      isSiteIdentificationAllowed: true, overrides: ["secret-site.example.com": .polite])
    let context = ContextStyleResolver(
      app: AppStyleResolver(overrides: ["com.example.secret-app": .command]), site: site)

    for value in [site, context] as [Any] {
      for text in [String(describing: value), String(reflecting: value), "\(value)"] {
        #expect(!text.contains("secret"))
        #expect(!text.contains("example"))
      }
      let mirrored = Mirror(reflecting: value).children.map { String(describing: $0.value) }
      #expect(mirrored.allSatisfy { !$0.contains("secret") && !$0.contains("example") })
    }
  }
}

struct ContextStyleResolverTests {
  private static let host = SiteHost(host: "mail.example.com")!

  @Test("CTX-01 / CTX-02: サイト別の上書き → アプリ別の上書き → 既定の対応表 → standard の順に判定する")
  func precedence() {
    let site = SiteStyleResolver(
      isSiteIdentificationAllowed: true, overrides: ["mail.example.com": .polite])
    let app = AppStyleResolver(overrides: ["com.apple.Safari": .document])
    let context = ContextStyleResolver(app: app, site: site)
    let otherHost = SiteHost(host: "news.example.com")

    // サイト別の上書きがアプリ別の上書きより優先される
    #expect(context.style(forBundleID: "com.apple.Safari", siteHost: Self.host) == .polite)
    // サイトに上書きがなければアプリ別の上書き
    #expect(context.style(forBundleID: "com.apple.Safari", siteHost: otherHost) == .document)
    // アプリ別の上書きもなければ既定の対応表
    #expect(context.style(forBundleID: "com.apple.Terminal", siteHost: otherHost) == .command)
    // どれにも当たらなければ standard
    #expect(context.style(forBundleID: "com.example.unknown", siteHost: otherHost) == .standard)
    #expect(context.style(forBundleID: nil, siteHost: nil) == .standard)
  }

  @Test("CTX-02: ホスト名を渡さなければアプリ単位の判定と同じ")
  func withoutHostMatchesAppResolver() {
    let app = AppStyleResolver(overrides: ["com.hnc.Discord": .polite])
    let context = ContextStyleResolver(
      app: app, site: SiteStyleResolver(isSiteIdentificationAllowed: true))

    for bundleID in ["com.hnc.Discord", "com.apple.mail", "com.example.unknown", nil] as [String?] {
      #expect(context.style(forBundleID: bundleID) == app.style(forBundleID: bundleID))
    }
  }
}
