import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

/// テストごとに専用の suite を使い、終わったら消す
private final class TestDefaults {
  let suiteName: String
  let defaults: UserDefaults

  init(_ name: String) throws {
    suiteName = "utter.tests.ConsentSettingsController.\(name)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

struct ConsentSettingsControllerTests {
  @Test("AC-06: 未保存なら画面はすべて未同意")
  func loadsNotGrantedByDefault() throws {
    let suite = try TestDefaults("empty")
    let controller = ConsentSettingsController(store: AppSettingsStore(defaults: suite.defaults))

    let screen = controller.load()

    #expect(screen.consent == ConsentState())
    #expect(screen.rows.allSatisfy { $0.status == .notGranted })
  }

  @Test("AC-06, AC-12: 同意を保存し、別のインスタンスから復元できる")
  func savesAndRestoresConsent() throws {
    let suite = try TestDefaults("roundTrip")
    let controller = ConsentSettingsController(store: AppSettingsStore(defaults: suite.defaults))

    let screen = try controller.setGranted(true, for: .transmission(.textRefinement(.claude)))
    let restored = ConsentSettingsController(store: AppSettingsStore(defaults: suite.defaults))
      .load()

    #expect(restored == screen)
    #expect(restored.consent.allows(.textRefinement(.claude)))
    #expect(!restored.consent.allows(.textRefinement(.chatGPT)))
  }

  @Test("AC-06: 撤回は保存した時点で、保存済みの同意状態から送信不可になる")
  func revokeIsPersistedImmediately() throws {
    let suite = try TestDefaults("revoke")
    let store = AppSettingsStore(defaults: suite.defaults)
    let controller = ConsentSettingsController(store: store)
    try controller.setGranted(true, for: .transmission(.textRefinement(.claude)))
    #expect(controller.currentConsent().allows(.textRefinement(.claude)))

    let screen = try controller.setGranted(false, for: .transmission(.textRefinement(.claude)))

    #expect(!controller.currentConsent().allows(.textRefinement(.claude)))
    #expect(!store.load().consentState.allows(.textRefinement(.claude)))
    #expect(
      screen.rows.first { $0.scope == .transmission(.textRefinement(.claude)) }?.status
        == .revoked)
  }

  @Test("2.3節: 同意の操作はほかの設定項目を保存済みの値のまま残す")
  func keepsOtherSettings() throws {
    let suite = try TestDefaults("otherSettings")
    let store = AppSettingsStore(defaults: suite.defaults)
    let controller = ConsentSettingsController(store: store)
    // 画面を開いた後に、ほかの画面で設定が変わった場合
    _ = controller.load()
    let other = AppSettings(
      maxRecordingDuration: 90, refinementEngine: .cloudAI, historyEnabled: true,
      excludedApps: ["com.example.secret"])
    try store.save(other)

    try controller.setGranted(true, for: .crossProviderFallback)

    var expected = other
    expected.consentState.grant(.crossProviderFallback)
    #expect(store.load() == expected)
  }

  @Test("AC-06: 保存値が壊れていれば未同意で表示し、操作すると読める形で保存し直す")
  func corruptedConsentFallsBackToNotGranted() throws {
    let suite = try TestDefaults("corrupted")
    suite.defaults.set(
      Data(#"{"version": 1, "consentState": "granted"}"#.utf8), forKey: AppSettingsStore.key)
    let controller = ConsentSettingsController(store: AppSettingsStore(defaults: suite.defaults))

    #expect(controller.load().consent == ConsentState())

    try controller.setGranted(true, for: .transmission(.textRefinement(.claude)))
    #expect(controller.currentConsent().allows(.textRefinement(.claude)))
  }

  @Test("AC-06, CTX-03: 画面の文言に保存済みの設定の値（除外アプリ・モデル名など）が入らない")
  func screenTextContainsNoSettingValues() throws {
    let suite = try TestDefaults("noUserData")
    let store = AppSettingsStore(defaults: suite.defaults)
    let marker = "MARKER-secret-本文"
    try store.save(
      AppSettings(
        appStyleOverrides: ["com.example.\(marker)": .polite],
        refinementModel: "model-\(marker)",
        excludedApps: ["com.example.\(marker)"]))
    let controller = ConsentSettingsController(store: store)
    var consent = ConsentState()
    for scope in ConsentScope.allCases { consent.grant(scope) }
    var settings = store.load()
    settings.consentState = consent
    try store.save(settings)

    let screen = controller.load()

    let texts =
      [ConsentScreenState.summary]
      + screen.rows.flatMap { row in
        [
          row.statusLabel, row.disclosure.title, row.disclosure.content,
          row.disclosure.destination, row.disclosure.note ?? "",
        ] + row.disclosure.notSent
      }
    #expect(screen.rows.count == ConsentScope.allCases.count)
    #expect(texts.allSatisfy { !$0.contains("MARKER") && !$0.contains("example") })
  }
}
