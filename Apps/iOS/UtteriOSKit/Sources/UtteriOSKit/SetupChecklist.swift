import Foundation
import UtterCore
import UtterSpeech

/// セットアップ画面の手順（#200）。この順に並べる。
public enum SetupStep: Hashable, Sendable, CaseIterable {
  case addKeyboard
  case fullAccess
  case microphone
  case speechModel
  /// 整形の実行先。飛ばせる（飛ばしても端末内の整形 Local Basic で使える）
  case refinementDestination

  /// 飛ばしてもアプリを使えるか
  public var isSkippable: Bool {
    self == .refinementDestination
  }
}

/// 手順の状態。
public enum SetupStepState: Hashable, Sendable {
  /// 済んだ
  case done(SetupStepConfirmation)
  /// まだ済んでいない
  case pending
  /// 拒否された・オフと報告された。設定アプリで直す
  case needsAttention
  /// 利用者が飛ばした（飛ばせる手順だけ）
  case skipped
  /// このビルド・端末では要らない
  case notApplicable

  /// 先へ進めてよいか（済んだ・飛ばした・要らない）
  public var isSettled: Bool {
    switch self {
    case .done, .skipped, .notApplicable: true
    case .pending, .needsAttention: false
    }
  }
}

/// 済んだことを何で確かめたか。
public enum SetupStepConfirmation: Hashable, Sendable {
  /// キーボード拡張からの報告（App Group）
  case keyboardReport
  /// 利用者が「済んだ」を押した（本体アプリからは確かめられない）
  case user
  /// OS の状態（権限・モデルの取得状態）
  case system
}

/// マイクの権限の状態。
public enum MicrophonePermissionStatus: Hashable, Sendable {
  case undetermined
  case granted
  case denied
}

/// 利用者がセットアップ画面で操作した記録。本体アプリの `UserDefaults` に残す（App Group には置かない）。
/// 秘密情報・本文は持たない。
public struct SetupMarks: Hashable, Sendable, Codable {
  /// 整形の実行先の手順の扱い
  public enum RefinementDecision: Hashable, Sendable, Codable {
    /// 今の実行先で使うと決めた
    case decided
    /// 飛ばした
    case skipped
  }

  /// 「キーボードを追加」を済んだことにした時刻
  public var keyboardAddedAt: Date?
  /// 「フルアクセスを許可」を済んだことにした時刻。キーボードからの報告より後なら、こちらを使う
  public var fullAccessAllowedAt: Date?
  public var refinement: RefinementDecision?
  /// セットアップ画面を一度閉じた時刻。閉じていなければ起動時に画面を出す
  public var dismissedAt: Date?

  public init(
    keyboardAddedAt: Date? = nil, fullAccessAllowedAt: Date? = nil,
    refinement: RefinementDecision? = nil, dismissedAt: Date? = nil
  ) {
    self.keyboardAddedAt = keyboardAddedAt
    self.fullAccessAllowedAt = fullAccessAllowedAt
    self.refinement = refinement
    self.dismissedAt = dismissedAt
  }
}

/// セットアップの各手順の状態を、観測した値と利用者の操作の記録から決める（#200）。
///
/// - キーボードの追加とフルアクセスは本体アプリから確かめられない。App Group を設定したビルドでは、
///   キーボード拡張が表示されたときの報告（`KeyboardSetupReport`）で済んだことにする。報告がなければ利用者の「済んだ」で扱う
/// - App Group を設定していないビルドではキーボードと共有しない（フルアクセスを求めない）ため、フルアクセスは要らない
/// - 音声認識モデルは、取得するモデルがない（STT 未設定・この端末で使えない）なら要らない
/// - 整形の実行先は飛ばせる。飛ばしても、決めていなくても、端末内の整形（Local Basic）で使える
public struct SetupChecklist: Hashable, Sendable {
  public let states: [SetupStep: SetupStepState]

  /// - Parameters:
  ///   - sharesWithKeyboard: 共有結果を App Group でキーボードと共有するビルドか
  ///   - keyboardReport: キーボード拡張からの最新の報告。届いていなければ `nil`
  ///   - marks: 利用者の操作の記録
  ///   - microphone: マイクの権限
  ///   - hasSpeechModel: 取得するモデルを持つ STT エンジンか
  ///   - speechModel: モデルの取得状態。まだ確かめていなければ `nil`
  public init(
    sharesWithKeyboard: Bool,
    keyboardReport: KeyboardSetupReport?,
    marks: SetupMarks,
    microphone: MicrophonePermissionStatus,
    hasSpeechModel: Bool,
    speechModel: UtterSpeech.SpeechModelAvailability?
  ) {
    let report = sharesWithKeyboard ? keyboardReport : nil
    states = [
      .addKeyboard: Self.keyboardState(report: report, marks: marks),
      .fullAccess: Self.fullAccessState(
        sharesWithKeyboard: sharesWithKeyboard, report: report, marks: marks),
      .microphone: Self.microphoneState(microphone),
      .speechModel: Self.speechModelState(hasModel: hasSpeechModel, availability: speechModel),
      .refinementDestination: Self.refinementState(marks.refinement),
    ]
  }

  public func state(of step: SetupStep) -> SetupStepState {
    states[step] ?? .pending
  }

  /// 次に取り組む手順。すべて済んだ・飛ばした・要らないなら `nil`
  public var currentStep: SetupStep? {
    SetupStep.allCases.first { !state(of: $0).isSettled }
  }

  /// 飛ばせない手順がすべて済んだ（または要らない）か。整形の実行先は含めない
  public var isRequiredComplete: Bool {
    SetupStep.allCases.filter { !$0.isSkippable }.allSatisfy { state(of: $0).isSettled }
  }

  /// 済んだ・要らない手順の数と、手順の数（進み具合の表示）
  public var progress: (settled: Int, total: Int) {
    (SetupStep.allCases.filter { state(of: $0).isSettled }.count, SetupStep.allCases.count)
  }

  private static func keyboardState(report: KeyboardSetupReport?, marks: SetupMarks)
    -> SetupStepState
  {
    if report != nil { return .done(.keyboardReport) }
    if marks.keyboardAddedAt != nil { return .done(.user) }
    return .pending
  }

  /// 報告と「済んだ」の新しい方を使う。オフの報告の後に「済んだ」を押したら済んだことにし、
  /// その後にキーボードからオフの報告が届いたら、もう一度オンにするよう求める
  private static func fullAccessState(
    sharesWithKeyboard: Bool, report: KeyboardSetupReport?, marks: SetupMarks
  ) -> SetupStepState {
    guard sharesWithKeyboard else { return .notApplicable }
    if let report {
      if report.hasFullAccess { return .done(.keyboardReport) }
      if let allowedAt = marks.fullAccessAllowedAt, allowedAt > report.observedAt {
        return .done(.user)
      }
      return .needsAttention
    }
    return marks.fullAccessAllowedAt == nil ? .pending : .done(.user)
  }

  private static func microphoneState(_ status: MicrophonePermissionStatus) -> SetupStepState {
    switch status {
    case .granted: .done(.system)
    case .denied: .needsAttention
    case .undetermined: .pending
    }
  }

  private static func speechModelState(
    hasModel: Bool, availability: UtterSpeech.SpeechModelAvailability?
  ) -> SetupStepState {
    guard hasModel else { return .notApplicable }
    switch availability {
    case .installed: return .done(.system)
    // この端末・言語では使えない。取得しても解決しないため、手順から外す
    case .unsupported: return .notApplicable
    case .notInstalled, .downloading, nil: return .pending
    }
  }

  private static func refinementState(_ decision: SetupMarks.RefinementDecision?)
    -> SetupStepState
  {
    switch decision {
    case .decided: .done(.user)
    case .skipped: .skipped
    case nil: .pending
    }
  }
}
