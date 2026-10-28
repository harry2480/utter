import Foundation
import Observation
import UtterCore
import UtterPersistence
import UtterSpeech

/// マイクの権限を読み、求める口。本番は Apps/iOS の `SystemMicrophonePermission`（AVAudioApplication）。
public protocol MicrophonePermissionAccess: Sendable {
  /// 今の状態。読むだけで求めない
  func status() -> MicrophonePermissionStatus
  /// 権限を求める。利用者の操作を起点にだけ呼ぶ。許可されたら `true`
  func request() async -> Bool
}

/// キーボード拡張からの報告の読み込み口。本番は UtterPersistence の `KeyboardSetupReportStore`（App Group）。
public protocol KeyboardSetupReportReading: Sendable {
  func load() async throws -> KeyboardSetupReport?
}

extension KeyboardSetupReportStore: KeyboardSetupReportReading {}

/// セットアップ画面での操作の記録（`SetupMarks`）の保存先。本体アプリの `UserDefaults` に置く（App Group ではない）。
///
/// `UserDefaults` は `Sendable` でないため、この型も `Sendable` にしない（`AppSettingsStore` と同じ）。
public struct SetupMarksStore {
  /// 記録を保存するキー
  public static let key = "utter.setupMarks"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// 保存済みの記録。未保存・壊れた値なら何もしていない記録を返す
  public func load() -> SetupMarks {
    guard let data = defaults.data(forKey: Self.key),
      let marks = try? JSONDecoder().decode(SetupMarks.self, from: data)
    else {
      return SetupMarks()
    }
    return marks
  }

  public func save(_ marks: SetupMarks) throws {
    defaults.set(try JSONEncoder().encode(marks), forKey: Self.key)
  }
}

/// セットアップ画面の状態と操作（#200）。手順の状態は `SetupChecklist` が決める。
///
/// - キーボード拡張からの報告は App Group を設定したビルドだけ読む（#56）。読めなければ届いていないものとして扱う
/// - マイクは「マイクを許可」を押したときだけ求める
/// - 「済んだ」・整形の実行先を決めた・飛ばした・画面を閉じたことは `SetupMarksStore` に残す。
///   保存できなくても、この起動の間は画面に反映する
@MainActor
@Observable
public final class SetupChecklistModel {
  /// キーボード拡張からの最新の報告。届いていなければ `nil`
  public private(set) var keyboardReport: KeyboardSetupReport?
  public private(set) var marks: SetupMarks
  public private(set) var microphone: MicrophonePermissionStatus
  /// マイクの権限を求めている途中か
  public private(set) var isRequestingMicrophone = false
  /// 共有結果を App Group でキーボードと共有するビルドか
  public let sharesWithKeyboard: Bool

  @ObservationIgnored private let store: SetupMarksStore
  @ObservationIgnored private let reportReader: (any KeyboardSetupReportReading)?
  @ObservationIgnored private let microphoneAccess: any MicrophonePermissionAccess
  @ObservationIgnored private let now: @Sendable () -> Date

  /// - Parameters:
  ///   - store: 操作の記録の保存先
  ///   - reportReader: キーボード拡張からの報告の読み込み口。App Group を設定していなければ `nil`
  ///   - sharesWithKeyboard: 共有結果を App Group でキーボードと共有するか（`SharedResultStorage.sharing`）
  ///   - microphone: マイクの権限
  ///   - now: 操作の時刻（テストでは固定する）
  public init(
    store: SetupMarksStore,
    reportReader: (any KeyboardSetupReportReading)?,
    sharesWithKeyboard: Bool,
    microphone: any MicrophonePermissionAccess,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.reportReader = reportReader
    self.sharesWithKeyboard = sharesWithKeyboard
    self.microphoneAccess = microphone
    self.now = now
    marks = store.load()
    self.microphone = microphone.status()
  }

  /// 起動時にセットアップ画面を出すか。一度も閉じていなければ出す
  public var presentsOnLaunch: Bool {
    marks.dismissedAt == nil
  }

  /// 今の手順の状態
  /// - Parameters:
  ///   - hasSpeechModel: 取得するモデルを持つ STT エンジンか
  ///   - speechModel: モデルの取得状態（`SpeechModelSettingsModel.availability`）
  public func checklist(
    hasSpeechModel: Bool, speechModel: UtterSpeech.SpeechModelAvailability?
  ) -> SetupChecklist {
    SetupChecklist(
      sharesWithKeyboard: sharesWithKeyboard, keyboardReport: keyboardReport, marks: marks,
      microphone: microphone, hasSpeechModel: hasSpeechModel, speechModel: speechModel)
  }

  /// キーボード拡張からの報告とマイクの権限を読み直す。画面を開いたとき・前面に戻ったときに呼ぶ
  public func refresh() async {
    microphone = microphoneAccess.status()
    guard sharesWithKeyboard, let reportReader else {
      keyboardReport = nil
      return
    }
    // 読めない（端末のロック中・壊れた値）ときは届いていないものとして扱い、「済んだ」で進められるようにする
    keyboardReport = try? await reportReader.load()
  }

  /// 利用者の操作でマイクの権限を求める。まだ求めていないときだけ
  public func requestMicrophone() async {
    guard microphone == .undetermined, !isRequestingMicrophone else { return }
    isRequestingMicrophone = true
    defer { isRequestingMicrophone = false }
    _ = await microphoneAccess.request()
    microphone = microphoneAccess.status()
  }

  /// 本体アプリから確かめられない手順（キーボードの追加・フルアクセス）を、利用者の申告で済んだことにする
  public func markDone(_ step: SetupStep) {
    switch step {
    case .addKeyboard: update { $0.keyboardAddedAt = now() }
    case .fullAccess: update { $0.fullAccessAllowedAt = now() }
    case .refinementDestination: update { $0.refinement = .decided }
    // OS の状態で決まる手順は申告で済んだことにしない
    case .microphone, .speechModel: break
    }
  }

  /// 飛ばせる手順（整形の実行先）を飛ばす
  public func skip(_ step: SetupStep) {
    guard step == .refinementDestination else { return }
    update { $0.refinement = .skipped }
  }

  /// 画面を閉じたことを残す。次の起動からは自動では出さない
  public func dismiss() {
    guard marks.dismissedAt == nil else { return }
    update { $0.dismissedAt = now() }
  }

  private func update(_ change: (inout SetupMarks) -> Void) {
    // ほかの起動で残した記録を消さないよう、保存先の最新の値に足す
    var latest = store.load()
    change(&latest)
    // 保存できなくても、この起動の間は画面に反映する（次の起動では同じ手順をもう一度出す）
    try? store.save(latest)
    marks = latest
  }
}
