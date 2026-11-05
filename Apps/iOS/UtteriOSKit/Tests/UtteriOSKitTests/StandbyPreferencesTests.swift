import Foundation
import Testing
import UtterPersistence

@testable import UtteriOSKit

struct StandbyPreferencesTests {
  private func preferences() -> StandbyPreferences {
    let suite = "StandbyPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return StandbyPreferences(defaults: defaults)
  }

  @Test("iOS-04・iOS-05: 既定は自動挿入・無操作5分")
  func defaults() {
    let preferences = preferences()
    #expect(preferences.insertionMode == .automatic)
    #expect(preferences.idleTimeoutMinutes == 5)
    #expect(preferences.sessionConfiguration.idleTimeout == .seconds(300))
  }

  @Test("iOS-05: 挿入のしかたを保存して読める")
  func insertionModeRoundTrip() {
    let preferences = preferences()
    preferences.insertionMode = .preview
    #expect(preferences.insertionMode == .preview)
  }

  @Test("iOS-04: 無操作で終える時間を変えられる")
  func idleTimeoutRoundTrip() {
    let preferences = preferences()
    preferences.idleTimeoutMinutes = 15
    #expect(preferences.sessionConfiguration.idleTimeout == .seconds(900))
  }

  @Test("iOS-04: 無期限にはできない。以前の「終えない」（0）が保存されていても既定に戻す")
  func neverIsNotAllowed() {
    let suite = "StandbyPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(0, forKey: "standby.idleTimeoutMinutes")
    #expect(StandbyPreferences(defaults: defaults).idleTimeoutMinutes == 5)
    defaults.removePersistentDomain(forName: suite)
  }

  @Test("選択肢にない値が保存されていたら既定に戻す")
  func unknownIdleTimeoutFallsBack() {
    let suite = "StandbyPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(7, forKey: "standby.idleTimeoutMinutes")
    #expect(StandbyPreferences(defaults: defaults).idleTimeoutMinutes == 5)
    defaults.removePersistentDomain(forName: suite)
  }
}
