import Testing
import UtterSpeech

struct STTEngineSettingTests {
  /// `allowsStub: true` は Debug ビルド、`false` は Release ビルドの判定
  private func resolve(
    _ buildSetting: String?, launchArgument: String? = nil, allowsStub: Bool
  ) -> STTEngineKind? {
    STTEngineSetting.resolve(
      buildSetting: buildSetting, launchArgument: launchArgument, allowsStub: allowsStub)
  }

  @Test(
    "4章: 設定がない・知らない値・Worker に未登録のエンジンなら選ばない（既定のエンジンは持たない）",
    arguments: [nil, "", "  ", "unknown", "SpeechAnalyzer", "whisperKit"] as [String?])
  func defaultsToNoEngine(buildSetting: String?) {
    #expect(resolve(buildSetting, allowsStub: true) == nil)
    #expect(resolve(buildSetting, allowsStub: false) == nil)
  }

  @Test("4章: ビルド設定で speechAnalyzer を明示したときだけ SpeechAnalyzer を使う（Release でも）")
  func selectsSpeechAnalyzerFromBuildSetting() {
    #expect(resolve("speechAnalyzer", allowsStub: false) == .speechAnalyzer)
    #expect(resolve(" speechAnalyzer\n", allowsStub: false) == .speechAnalyzer)
    #expect(resolve("speechAnalyzer", allowsStub: true) == .speechAnalyzer)
  }

  @Test("4章: 開発用の stub は Debug ビルドでだけ受け付ける")
  func acceptsStubOnlyInDebug() {
    #expect(resolve("stub", allowsStub: true) == .stub)
    #expect(resolve(nil, launchArgument: "stub", allowsStub: true) == .stub)
    #expect(resolve("stub", allowsStub: false) == nil)
    #expect(resolve("speechAnalyzer", launchArgument: "stub", allowsStub: false) == .speechAnalyzer)
  }

  @Test("4章: 起動引数はビルド設定より優先し、使えない値ならビルド設定に従う")
  func launchArgumentOverridesBuildSetting() {
    #expect(resolve(nil, launchArgument: "speechAnalyzer", allowsStub: true) == .speechAnalyzer)
    #expect(resolve("speechAnalyzer", launchArgument: "stub", allowsStub: true) == .stub)
    #expect(resolve("speechAnalyzer", launchArgument: "none", allowsStub: true) == .speechAnalyzer)
    #expect(resolve("speechAnalyzer", launchArgument: "", allowsStub: true) == .speechAnalyzer)
    #expect(resolve(nil, launchArgument: "whisperKit", allowsStub: true) == nil)
  }

  @Test("PERM-03: OS が管理するモデルを扱うのは SpeechAnalyzer を選んだときだけ")
  func modelAssetsOnlyForSpeechAnalyzer() {
    #expect(STTEngineSetting.makeModelAssets(for: .speechAnalyzer) is SpeechAnalyzerAssets)
    #expect(STTEngineSetting.makeModelAssets(for: nil) == nil)
    #expect(STTEngineSetting.makeModelAssets(for: .stub) == nil)
    #expect(STTEngineSetting.makeModelAssets(for: .whisperKit) == nil)
  }
}
