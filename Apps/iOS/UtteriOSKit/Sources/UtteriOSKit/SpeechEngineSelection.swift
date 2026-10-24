import Foundation
import UtterSpeech

/// iOS 本体アプリで使う STT エンジンの選択（4章, #61）。
///
/// iOS の STT エンジンは Phase i0（#54）の判定待ちのため、既定は `unconfigured`（録音のみ・認識しない）。
/// Config/Local.xcconfig の `UTTER_IOS_STT_ENGINE`、または Debug ビルドの起動引数 `-UtterSpeechEngine` に
/// `speechAnalyzer` を明示したときだけ SpeechAnalyzer を使う。知らない値・空の値は既定に倒す。
public enum SpeechEngineSelection: String, CaseIterable, Sendable {
  /// 未設定。`UnconfiguredSpeechRecognizer` を使う
  case unconfigured
  /// Apple SpeechAnalyzer（iOS 26 以降）。#54 の判定待ちの先行実装
  case speechAnalyzer

  /// ビルド設定（Info.plist に埋め込んだ値）と起動引数から選ぶ。
  ///
  /// - Parameters:
  ///   - buildSetting: Info.plist の `UtterSpeechEngine`（Config/Local.xcconfig の `UTTER_IOS_STT_ENGINE`）
  ///   - launchArgument: Debug ビルドの起動引数 `-UtterSpeechEngine` の値。Release では渡さない。ビルド設定より優先する
  public static func resolve(buildSetting: String?, launchArgument: String?) -> Self {
    if let value = launchArgument.flatMap(Self.init(configurationValue:)) {
      return value
    }
    return buildSetting.flatMap(Self.init(configurationValue:)) ?? .unconfigured
  }

  /// 設定値から読む。前後の空白は無視し、知らない値は `nil`
  init?(configurationValue: String) {
    let trimmed = configurationValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Self(rawValue: trimmed) else { return nil }
    self = value
  }

  /// 選んだエンジンの音声認識
  public func makeRecognizer() -> any SpeechRecognizer {
    switch self {
    case .unconfigured: UnconfiguredSpeechRecognizer()
    case .speechAnalyzer: SpeechAnalyzerRecognizer()
    }
  }

  /// 利用者の操作で取得するモデル。OS が管理するモデルを使わないエンジンなら `nil`（PERM-03）
  public func makeModelAssets() -> (any SpeechModelAssets)? {
    switch self {
    case .unconfigured: nil
    case .speechAnalyzer: SpeechAnalyzerAssets()
    }
  }

  /// 録音の前に音声認識の権限（`SFSpeechRecognizer`）を求めるか（PERM-01）。
  ///
  /// SpeechAnalyzer に音声認識の権限が要るかは未確認（Verification/SpeechAnalyzerProbe・iOSSTTProbe は求めてから計測している）。
  /// 計測と同じ条件にそろえるため、SpeechAnalyzer を選んだときだけ求める。未使用のエンジンでは求めない
  public var requestsSpeechRecognitionPermission: Bool {
    switch self {
    case .unconfigured: false
    case .speechAnalyzer: true
    }
  }
}
