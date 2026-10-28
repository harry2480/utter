import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// iOS ホームの文体の切り替えと、整形先・認識先の表示（TXT-01, AC-06, #201）。
@MainActor
struct HomeSettingsModelTests {
  private let temporaryDefaults: TemporaryDefaults

  init() throws {
    temporaryDefaults = try TemporaryDefaults()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: temporaryDefaults.defaults) }

  @Test("TXT-01: 文体の既定は Natural")
  func defaultStyleIsNatural() {
    let home = HomeSettingsModel(store: store, speechEngine: .unconfigured)

    #expect(home.style == .natural)
  }

  @Test("TXT-01: 選んだ文体を保存し、次に開いたときも使う")
  func selectedStyleIsSaved() {
    let home = HomeSettingsModel(store: store, speechEngine: .unconfigured)

    home.select(.structured)

    #expect(home.style == .structured)
    #expect(!home.saveFailed)
    #expect(store.load().refinementMode == .structured)
    #expect(HomeSettingsModel(store: store, speechEngine: .unconfigured).style == .structured)
  }

  @Test("AC-06: 文体を保存しても、ほかの画面で変えた同意と処理系を残す")
  func selectKeepsOtherSettings() throws {
    let home = HomeSettingsModel(store: store, speechEngine: .unconfigured)
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    try store.save(AppSettings(refinementEngine: .cloudAI, consentState: consent))

    home.select(.raw)

    let saved = store.load()
    #expect(saved.refinementMode == .raw)
    #expect(saved.refinementEngine == .cloudAI)
    #expect(saved.consentState.allows(.textRefinement(.claude)))
  }

  @Test("AC-06: 処理系と同意を読み直して整形先を出し、送る先には「文字を送信」と示す")
  func reloadShowsRefinementDestination() throws {
    let home = HomeSettingsModel(store: store, speechEngine: .speechAnalyzer)
    #expect(!home.refinementDestination.sendsText)

    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    try store.save(AppSettings(refinementEngine: .cloudAI, consentState: consent))
    home.reload()

    #expect(home.refinementDestination.name == "Claude")
    #expect(home.refinementDestination.sendsText)
    // 録音中のチップは、録音を始めたときの文体で出す
    #expect(!home.refinementDestination(for: .raw).sendsText)
    #expect(home.speechDestination.name == "SpeechAnalyzer（端末内）")
  }

  @Test("TXT-01: ほかの経路で保存された文体を読み直す")
  func reloadReadsStyle() throws {
    let home = HomeSettingsModel(store: store, speechEngine: .unconfigured)
    try store.save(AppSettings(refinementMode: .raw))

    home.reload()

    #expect(home.style == .raw)
  }
}
