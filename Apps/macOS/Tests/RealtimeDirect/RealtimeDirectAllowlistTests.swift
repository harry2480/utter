import Testing
import UtterText

/// Realtime Direct の許可リスト（AC-15）。互換性表の判定前は空で、Debug ビルドの起動引数でだけ足せる。
struct RealtimeDirectAllowlistTests {
  @Test("AC-15: 確認済みのアプリはまだなく、既定では全アプリで使えない")
  func verifiedIsEmpty() {
    #expect(RealtimeDirectAllowlist.verified.apps.isEmpty)
    #expect(RealtimeDirectAllowlist.verified.support(for: "com.apple.TextEdit") == .unsupported)
    #expect(RealtimeDirectAllowlist.verified.support(for: nil) == .unsupported)
    #expect(RealtimeDirectAllowlist.launchConfigured(arguments: ["utter"]) == .verified)
  }

  @Test("AC-15: 足したアプリは bundle ID の大文字・小文字によらず範囲追跡と Undo を確認済みとして扱う")
  func addingApps() {
    let allowlist = RealtimeDirectAllowlist.verified.adding(["com.apple.TextEdit"])

    #expect(
      allowlist.support(for: "com.apple.textedit")
        == RealtimeDirectAppSupport(tracksRange: true, supportsUndo: true))
    #expect(allowlist.support(for: "com.apple.Notes") == .unsupported)
  }

  #if DEBUG
    @Test("AC-15: Debug ビルドでは起動引数（カンマ区切り）でアプリを足せる")
    func debugLaunchArguments() {
      let arguments = [
        "utter", "-UtterRealtimeDirectDebugApps", "com.apple.TextEdit, com.apple.Notes,,",
      ]

      #expect(
        RealtimeDirectAllowlist.debugApps(arguments: arguments) == [
          "com.apple.TextEdit", "com.apple.Notes",
        ])
      #expect(
        RealtimeDirectAllowlist.launchConfigured(arguments: arguments).apps == [
          "com.apple.textedit", "com.apple.notes",
        ])
      // 値のない引数・次の引数の名前は足さない
      #expect(
        RealtimeDirectAllowlist.debugApps(arguments: ["-UtterRealtimeDirectDebugApps"]).isEmpty)
      #expect(
        RealtimeDirectAllowlist.debugApps(arguments: ["-UtterRealtimeDirectDebugApps", "-NSFoo"])
          .isEmpty)
    }
  #endif
}
