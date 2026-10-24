import Foundation
import UtterCore
import UtterPersistence
import UtterSpeech

/// 本体アプリの権限の状態を読む口。本番は Apps/iOS の `SystemHostAppPermissionReader`（AVAudioApplication / SFSpeechRecognizer）。
public protocol HostAppPermissionReader: Sendable {
  /// マイクの使用が拒否されているか。まだ求めていなければ `false`
  func isMicrophoneDenied() -> Bool
  /// 音声認識が拒否・制限されているか。まだ求めていなければ `false`
  func isSpeechRecognitionDenied() -> Bool
}

/// 本体アプリの状態の書き込み先。本番は UtterPersistence の `HostAppStatusStore`（App Group）。
public protocol HostAppStatusWriting: Sendable {
  func save(_ status: HostAppStatus) async throws
}

extension HostAppStatusStore: HostAppStatusWriting {}

/// 本体アプリの状態（権限・STT モデル・整形設定）を App Group に書き、キーボード拡張の案内に使わせる（iAC-07）。
///
/// - App Group は Phase i0（#56）の判定待ちのため、`Config/Local.xcconfig` で設定し、そのコンテナを開けたときだけ書く。
///   未設定なら何も書かない（`resolve(appGroupIdentifier:...)` が `nil` を返す）
/// - 書くのは `HostAppStatus` の項目（拒否された権限・モデルの取得状況・クラウド整形の設定・観測時刻）だけで、
///   秘密情報・本文・音声は書かない（iOS-IPC-04, iAC-08）
/// - 起動時・前面に来たとき・権限やモデルの状態が変わりうる操作の後に `publish()` を呼ぶ。
///   書き込みは順に行い、後から観測した状態を先の状態で上書きしない
@MainActor
public final class HostAppStatusPublisher {
  private let writer: any HostAppStatusWriting
  private let permissions: any HostAppPermissionReader
  private let speechEngine: SpeechEngineSelection
  private let speechModel: (any SpeechModelAssets)?
  private let settingsStore: AppSettingsStore
  private let now: @Sendable () -> Date
  /// 直前の書き込み。次の書き込みはこれを待ってから観測する
  private var latest: Task<HostAppStatusPublication, Never>?

  /// - Parameters:
  ///   - writer: 書き込み先（App Group）
  ///   - permissions: 権限の状態
  ///   - speechEngine: 使う STT エンジン（音声認識の権限を求めるか・モデルを持つか）
  ///   - speechModel: エンジンのモデル。OS が管理するモデルを使わないエンジンなら `nil`（`SpeechEngineSelection.makeModelAssets()`）
  ///   - settingsStore: 整形の処理系の設定。クラウド整形と同じ保存先を渡す
  ///   - now: 観測時刻（テストでは固定する）
  public init(
    writer: any HostAppStatusWriting,
    permissions: any HostAppPermissionReader,
    speechEngine: SpeechEngineSelection,
    speechModel: (any SpeechModelAssets)?,
    settingsStore: AppSettingsStore,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.writer = writer
    self.permissions = permissions
    self.speechEngine = speechEngine
    self.speechModel = speechModel
    self.settingsStore = settingsStore
    self.now = now
  }

  /// App Group を設定したときだけ書き込み役を作る。
  /// - Parameters:
  ///   - appGroupIdentifier: Info.plist に埋め込んだ App Group ID。未設定なら空か `nil`。前後の空白は無視する
  ///   - makeWriter: App Group のコンテナを開く。既定は `HostAppStatusStore(groupIdentifier:)`。開けなければ `nil`
  /// - Returns: 未設定、またはコンテナを開けなければ `nil`（状態を書かない）
  public static func resolve(
    appGroupIdentifier: String?,
    permissions: any HostAppPermissionReader,
    speechEngine: SpeechEngineSelection,
    speechModel: (any SpeechModelAssets)?,
    settingsStore: AppSettingsStore,
    now: @escaping @Sendable () -> Date = { Date() },
    makeWriter: (String) -> (any HostAppStatusWriting)? = {
      HostAppStatusStore(groupIdentifier: $0)
    }
  ) -> HostAppStatusPublisher? {
    let identifier = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty, let writer = makeWriter(identifier) else { return nil }
    return HostAppStatusPublisher(
      writer: writer, permissions: permissions, speechEngine: speechEngine,
      speechModel: speechModel, settingsStore: settingsStore, now: now)
  }

  /// 今の状態を観測して書く。前の書き込みが終わってから観測するため、呼んだ順に新しい状態で置き換わる
  @discardableResult
  public func publish() async -> HostAppStatusPublication {
    let previous = latest
    let task = Task { @MainActor [self] in
      _ = await previous?.value
      return await observeAndWrite()
    }
    latest = task
    return await task.value
  }

  private func observeAndWrite() async -> HostAppStatusPublication {
    let modelAvailability = await speechModel?.availability()
    let status = Self.status(
      observedAt: now(),
      microphoneDenied: permissions.isMicrophoneDenied(),
      speechRecognitionDenied: permissions.isSpeechRecognitionDenied(),
      speechEngine: speechEngine,
      modelAvailability: modelAvailability,
      usesCloudRefinement: settingsStore.load().refinementEngine == .cloudAI)
    do {
      try await writer.save(status)
      return .written(status)
    } catch {
      // 端末のロック中などで書けない。次に前面に来たときに書き直す（古い状態はキーボードが鮮度で捨てる）
      return .failed
    }
  }

  /// 観測した値から `HostAppStatus` を組み立てる。
  ///
  /// - 音声認識の権限は、それを求めるエンジン（`requestsSpeechRecognitionPermission`）のときだけ拒否として扱う
  /// - モデルは取得済み（`installed`）のときだけ `ready`、未取得・取得中は `notDownloaded`（本体アプリで取得できる）。
  ///   この端末で使えない（`unsupported`）・STT エンジンが未設定（モデルを持たない）は、取得しても解決しないため `notApplicable`
  nonisolated static func status(
    observedAt: Date,
    microphoneDenied: Bool,
    speechRecognitionDenied: Bool,
    speechEngine: SpeechEngineSelection,
    modelAvailability: UtterSpeech.SpeechModelAvailability?,
    usesCloudRefinement: Bool
  ) -> HostAppStatus {
    var denied: Set<HostAppPermission> = []
    if microphoneDenied { denied.insert(.microphone) }
    if speechEngine.requestsSpeechRecognitionPermission, speechRecognitionDenied {
      denied.insert(.speechRecognition)
    }
    let speechModel: UtterCore.SpeechModelAvailability =
      switch modelAvailability {
      case .installed: .ready
      case .notInstalled, .downloading: .notDownloaded
      case .unsupported, nil: .notApplicable
      }
    return HostAppStatus(
      observedAt: observedAt, deniedPermissions: denied, speechModel: speechModel,
      usesCloudRefinement: usesCloudRefinement)
  }
}

/// 状態の書き込みの結果。
public enum HostAppStatusPublication: Hashable, Sendable {
  case written(HostAppStatus)
  /// 書けなかった（端末のロック中など）
  case failed
}
