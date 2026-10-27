import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// 前面のブラウザで表示中のホスト名を返す Stub。呼ばれた回数と、渡された前面アプリを記録する
@MainActor
final class StubFrontmostSiteHostReader: FrontmostSiteHostReading {
  private let host: SiteHost?
  private(set) var requestedApps: [String] = []

  init(host: SiteHost?) {
    self.host = host
  }

  func siteHost(inFrontmostApp bundleID: String) -> SiteHost? {
    requestedApps.append(bundleID)
    return host
  }
}

/// サイト別のスタイル（CTX-02, CTX-03）の結線。整形はローカル（Local Basic）だけで、ネットワークに出ない。
@MainActor
struct SessionSiteStyleTests {
  private static let transcript = "了解です"
  private static let browser = "com.example.browser"
  private static let safeInput = SensitiveInputContext(
    secureField: .off, secureEventInput: .off, app: browser)

  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  /// Local Basic で整形し、サイト別に `concise` を上書きした設定
  private static func settings(allowed: Bool) -> AppSettings {
    AppSettings(
      refinementMode: .natural, refinementEngine: .localBasic,
      siteIdentificationAllowed: allowed, siteStyleOverrides: ["example.com": .concise])
  }

  private func refine(
    _ settings: AppSettings, reader: StubFrontmostSiteHostReader, app: String? = browser
  ) async throws -> SessionRefinementResult {
    try store.save(settings)
    let database = database
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: StubAPIKeyStore(), database: { database },
      siteHostReader: reader)
    return try await pipeline.refine(
      Self.transcript, frontmostApp: app, sensitivity: { Self.safeInput })
  }

  private static func localBasic(_ style: RefinementStyle) -> String {
    LocalBasicRefiner().refine(RefinementRequest(text: transcript, mode: .natural, style: style))
  }

  // MARK: ホスト名の取り出し

  @Test("CTX-02, CTX-03: AX の URL からホスト名だけを取り出す（パス・ポート・クエリ・www. を捨てる）")
  func extractsHostFromURL() throws {
    let url = try #require(URL(string: "https://www.Example.com:8443/inbox?id=1#top"))

    #expect(
      AccessibilitySiteHostReader.siteHost(fromURLValue: url) == SiteHost(host: "example.com"))
    #expect(
      AccessibilitySiteHostReader.siteHost(fromURLValue: url as NSURL)
        == SiteHost(host: "example.com"))
    #expect(
      AccessibilitySiteHostReader.siteHost(fromURLValue: "https://mail.example.com/u/0")
        == SiteHost(host: "mail.example.com"))
  }

  @Test("CTX-02: http / https 以外・ホスト名のない値・URL でない値からは作らない")
  func rejectsNonWebURLs() throws {
    let file = try #require(URL(string: "file:///Users/example/index.html"))

    #expect(AccessibilitySiteHostReader.siteHost(fromURLValue: file) == nil)
    #expect(AccessibilitySiteHostReader.siteHost(fromURLValue: "about:blank") == nil)
    #expect(AccessibilitySiteHostReader.siteHost(fromURLValue: nil) == nil)
    #expect(AccessibilitySiteHostReader.siteHost(fromURLValue: 42) == nil)
  }

  // MARK: 取得の口を呼ぶ条件

  @Test("CTX-02: サイト単位の識別を許可していなければ、上書きがあってもホスト名を読まない")
  func doesNotReadWithoutPermission() async throws {
    let reader = StubFrontmostSiteHostReader(host: SiteHost(host: "example.com"))

    let result = try await refine(Self.settings(allowed: false), reader: reader)

    #expect(reader.requestedApps.isEmpty)
    #expect(result.text == Self.localBasic(.standard))
  }

  @Test("CTX-02: 許可していてもサイト別の上書きがなければ、ホスト名を読まない")
  func doesNotReadWithoutOverrides() async throws {
    let reader = StubFrontmostSiteHostReader(host: SiteHost(host: "example.com"))
    var settings = Self.settings(allowed: true)
    settings.siteStyleOverrides = [:]

    _ = try await refine(settings, reader: reader)

    #expect(reader.requestedApps.isEmpty)
  }

  @Test("CTX-02: 前面アプリを特定できなければ、ホスト名を読まない")
  func doesNotReadWithoutFrontmostApp() async throws {
    let reader = StubFrontmostSiteHostReader(host: SiteHost(host: "example.com"))

    _ = try await refine(Self.settings(allowed: true), reader: reader, app: nil)

    #expect(reader.requestedApps.isEmpty)
  }

  @Test("TXT-01: Raw モードはスタイルを使わないため、ホスト名を読まない")
  func rawDoesNotRead() async throws {
    let reader = StubFrontmostSiteHostReader(host: SiteHost(host: "example.com"))
    var settings = Self.settings(allowed: true)
    settings.refinementMode = .raw

    let result = try await refine(settings, reader: reader)

    #expect(reader.requestedApps.isEmpty)
    #expect(result.text == Self.transcript)
  }

  // MARK: スタイルの選択

  @Test("CTX-02: 許可していれば、録音開始時の前面アプリのホスト名でサイト別のスタイルを選ぶ")
  func usesSiteStyleWhenAllowed() async throws {
    // concise と standard でローカル整形の結果が違うこと（この検査が意味を持つこと）を先に確かめる
    #expect(Self.localBasic(.concise) != Self.localBasic(.standard))
    let reader = StubFrontmostSiteHostReader(host: SiteHost(host: "example.com"))

    let result = try await refine(Self.settings(allowed: true), reader: reader)

    #expect(reader.requestedApps == [Self.browser])
    #expect(result.text == Self.localBasic(.concise))
  }

  @Test("CTX-02: ホスト名を読めない・上書きのないサイトなら、アプリ別のスタイルに戻る")
  func fallsBackToAppStyle() async throws {
    var settings = Self.settings(allowed: true)
    settings.appStyleOverrides = [Self.browser: .polite]
    let unreadable = StubFrontmostSiteHostReader(host: nil)
    let otherSite = StubFrontmostSiteHostReader(host: SiteHost(host: "other.example.org"))

    let unread = try await refine(settings, reader: unreadable)
    let other = try await refine(settings, reader: otherSite)

    #expect(unreadable.requestedApps == [Self.browser])
    #expect(unread.text == Self.localBasic(.polite))
    #expect(other.text == Self.localBasic(.polite))
  }
}
