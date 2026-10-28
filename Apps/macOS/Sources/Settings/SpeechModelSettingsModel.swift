import Observation
import UtterSpeech

/// OS が管理する音声認識モデルの状態の確認と取得の口（PERM-03）。本番は `SpeechAnalyzerAssets`。
///
/// iOS（UtteriOSKit の同名の型）と同じ振る舞いにする。モデルは OS 全体で共有するため、
/// アプリのプロセスで取得したモデルを STT Worker の認識（`SpeechAnalyzerModelLoader`）がそのまま使う。
protocol SpeechModelAssets: Sendable {
  /// 現在の取得状態。ネットワークは使わない
  func availability() async -> SpeechModelAvailability
  /// モデルを取得する。利用者の明示的な操作を起点にだけ呼ぶ（ネットワークを使う）
  func install() async throws
  /// このアプリのモデルの予約を解除する。消すのは OS で、すぐには消えないことがある。解除したら `true`
  func releaseReservation() async -> Bool
}

extension SpeechAnalyzerAssets: SpeechModelAssets {}

/// 設定画面の「認識モデルと省電力」タブのモデルの表示と「取得」操作（PERM-03）。
///
/// - 状態の確認（`refresh()`）はネットワークを使わず、取得はしない
/// - 取得（`install()`）は画面のボタンからだけ呼び、未取得のときだけ `SpeechModelAssets.install()` を呼ぶ
/// - 取得の失敗は理由の区分だけを持ち、エラーの詳細は画面に出さない
/// - 削除（`releaseReservation()`, #199）は画面のボタンからだけ呼び、取得済みのときだけ予約の解除を求める。
///   公開 API ではモデルをアプリからすぐに削除できないため、予約を解除して OS の削除に任せ、そのことを画面に示す
@MainActor
@Observable
final class SpeechModelSettingsModel {
  /// 直近に確かめた取得状態。まだ確かめていなければ `nil`
  private(set) var availability: SpeechModelAvailability?
  /// 取得を要求中か
  private(set) var isInstalling = false
  /// 直近の取得に失敗したか
  private(set) var installFailed = false
  /// 予約の解除を要求中か
  private(set) var isReleasing = false
  /// 直近の予約の解除の結果。解除していない・その後に取得し直したら `nil`
  private(set) var releaseResult: ReleaseResult?

  /// 予約の解除の結果
  enum ReleaseResult: Hashable, Sendable {
    /// 予約を解除した。OS が後で削除する
    case released
    /// このアプリは予約していなかった（OS が管理しているため、アプリからは消せない）
    case notReserved
  }

  @ObservationIgnored private let assets: any SpeechModelAssets
  /// 状態の確認の世代。後から始めた確認の結果だけを反映する
  @ObservationIgnored private var refreshGeneration = 0

  init(assets: any SpeechModelAssets) {
    self.assets = assets
  }

  /// 取得のボタンを出すか。未取得のときだけ
  var canInstall: Bool {
    availability == .notInstalled && !isInstalling
  }

  /// 削除（予約の解除）のボタンを出すか。取得済みで、まだ解除していないときだけ
  var canRelease: Bool {
    availability == .installed && !isInstalling && !isReleasing && releaseResult == nil
  }

  /// 取得状態を確かめ直す。取得はしない
  func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    let value = await assets.availability()
    guard generation == refreshGeneration else { return }
    availability = value
  }

  /// 利用者の操作でモデルを取得する。未取得のときだけ要求し、終わったら状態を確かめ直す
  func install() async {
    guard canInstall else { return }
    isInstalling = true
    installFailed = false
    defer { isInstalling = false }
    do {
      try await assets.install()
      // 取得し直したら予約もし直している
      releaseResult = nil
    } catch is CancellationError {
      // キャンセルされたときは失敗として出さない（今の画面からはキャンセルしない。画面を閉じても取得は続ける）
    } catch {
      installFailed = true
    }
    await refresh()
  }

  /// 利用者の操作でモデルの予約を解除する（#199）。取得済みのときだけ要求し、終わったら状態を確かめ直す
  func releaseReservation() async {
    guard canRelease else { return }
    isReleasing = true
    defer { isReleasing = false }
    releaseResult = await assets.releaseReservation() ? .released : .notReserved
    await refresh()
  }
}
