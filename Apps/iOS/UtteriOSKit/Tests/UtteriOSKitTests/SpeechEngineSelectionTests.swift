import Testing
import UtterSpeech

@testable import UtteriOSKit

struct SpeechEngineSelectionTests {
  @Test(
    "4章: 設定がなければ未設定（録音のみ）を使う",
    arguments: [nil, "", "  ", "whisperKit", "SpeechAnalyzer"] as [String?])
  func defaultsToUnconfigured(buildSetting: String?) {
    #expect(
      SpeechEngineSelection.resolve(buildSetting: buildSetting, launchArgument: nil)
        == .unconfigured)
  }

  @Test("4章: ビルド設定で speechAnalyzer を明示したときだけ SpeechAnalyzer を使う")
  func selectsSpeechAnalyzerFromBuildSetting() {
    #expect(
      SpeechEngineSelection.resolve(buildSetting: "speechAnalyzer", launchArgument: nil)
        == .speechAnalyzer)
    #expect(
      SpeechEngineSelection.resolve(buildSetting: " speechAnalyzer\n", launchArgument: nil)
        == .speechAnalyzer)
  }

  @Test("4章: 起動引数はビルド設定より優先し、知らない値ならビルド設定に従う")
  func launchArgumentOverridesBuildSetting() {
    #expect(
      SpeechEngineSelection.resolve(buildSetting: nil, launchArgument: "speechAnalyzer")
        == .speechAnalyzer)
    #expect(
      SpeechEngineSelection.resolve(buildSetting: "speechAnalyzer", launchArgument: "unconfigured")
        == .unconfigured)
    #expect(
      SpeechEngineSelection.resolve(buildSetting: "speechAnalyzer", launchArgument: "unknown")
        == .speechAnalyzer)
  }

  @Test("4章, PERM-01, PERM-03: 未設定なら録音のみの認識で、モデルも音声認識の権限も扱わない")
  func unconfiguredUsesNoEngine() {
    let selection = SpeechEngineSelection.unconfigured
    #expect(selection.makeRecognizer() is UnconfiguredSpeechRecognizer)
    #expect(selection.makeModelAssets() == nil)
    #expect(!selection.requestsSpeechRecognitionPermission)
  }

  @Test("4章, PERM-01, PERM-03: SpeechAnalyzer を選ぶと、その認識・モデル・音声認識の権限を使う")
  func speechAnalyzerUsesItsAdapters() {
    let selection = SpeechEngineSelection.speechAnalyzer
    #expect(selection.makeRecognizer() is SpeechAnalyzerRecognizer)
    #expect(selection.makeModelAssets() is SpeechAnalyzerAssets)
    #expect(selection.requestsSpeechRecognitionPermission)
  }
}
