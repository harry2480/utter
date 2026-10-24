import Observation
import UtterSpeech

/// OS が管理する音声認識モデルの状態の確認と取得の口（PERM-03）。本番は `SpeechAnalyzerAssets`。
public protocol SpeechModelAssets: Sendable {
  /// 現在の取得状態。ネットワークは使わない
  func availability() async -> SpeechModelAvailability
  /// モデルを取得する。利用者の明示的な操作を起点にだけ呼ぶ（ネットワークを使う）
  func install() async throws
}

extension SpeechAnalyzerAssets: SpeechModelAssets {}

/// 設定画面の音声認識モデルの表示と「取得」操作（PERM-03）。
///
/// - 状態の確認（`refresh()`）はネットワークを使わず、取得はしない
/// - 取得（`install()`）は画面のボタンからだけ呼び、未取得のときだけ `SpeechModelAssets.install()` を呼ぶ
/// - 取得の失敗は理由の区分だけを持ち、エラーの詳細は画面に出さない
@MainActor
@Observable
public final class SpeechModelSettingsModel {
  /// 直近に確かめた取得状態。まだ確かめていなければ `nil`
  public private(set) var availability: SpeechModelAvailability?
  /// 取得を要求中か
  public private(set) var isInstalling = false
  /// 直近の取得に失敗したか
  public private(set) var installFailed = false

  @ObservationIgnored private let assets: any SpeechModelAssets
  /// 状態の確認の世代。後から始めた確認の結果だけを反映する
  @ObservationIgnored private var refreshGeneration = 0

  public init(assets: any SpeechModelAssets) {
    self.assets = assets
  }

  /// 取得のボタンを出すか。未取得のときだけ
  public var canInstall: Bool {
    availability == .notInstalled && !isInstalling
  }

  /// 取得状態を確かめ直す。取得はしない
  public func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    let value = await assets.availability()
    guard generation == refreshGeneration else { return }
    availability = value
  }

  /// 利用者の操作でモデルを取得する。未取得のときだけ要求し、終わったら状態を確かめ直す
  public func install() async {
    guard canInstall else { return }
    isInstalling = true
    installFailed = false
    defer { isInstalling = false }
    do {
      try await assets.install()
    } catch is CancellationError {
      // キャンセルされたときは失敗として出さない（今の画面からはキャンセルしない。画面を閉じても取得は続ける）
    } catch {
      installFailed = true
    }
    await refresh()
  }
}
