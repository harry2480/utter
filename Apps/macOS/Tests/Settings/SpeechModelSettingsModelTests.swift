import Synchronization
import Testing
import UtterSpeech

/// モデルの代わり。取得の回数を数え、取得後の状態を返す
final class StubSpeechModelAssets: SpeechModelAssets {
  struct InstallFailure: Error {}

  private struct State {
    var availability: SpeechModelAvailability
    var availabilityCount = 0
    var installCount = 0
    var releaseCount = 0
  }

  private let state: Mutex<State>
  private let installError: (any Error)?
  private let reserved: Bool

  init(
    availability: SpeechModelAvailability, installError: (any Error)? = nil, reserved: Bool = true
  ) {
    state = Mutex(State(availability: availability))
    self.installError = installError
    self.reserved = reserved
  }

  var availabilityCount: Int { state.withLock { $0.availabilityCount } }
  var installCount: Int { state.withLock { $0.installCount } }
  var releaseCount: Int { state.withLock { $0.releaseCount } }

  func availability() async -> SpeechModelAvailability {
    state.withLock {
      $0.availabilityCount += 1
      return $0.availability
    }
  }

  func install() async throws {
    state.withLock { $0.installCount += 1 }
    if let installError { throw installError }
    state.withLock { $0.availability = .installed }
  }

  /// OS がモデルを消した・取得した、などの状態の変化
  func setAvailability(_ availability: SpeechModelAvailability) {
    state.withLock { $0.availability = availability }
  }

  /// 予約を解除しても、OS がすぐには消さないため取得済みのまま
  func releaseReservation() async -> Bool {
    state.withLock { $0.releaseCount += 1 }
    return reserved
  }
}

@MainActor
struct SpeechModelSettingsModelTests {
  @Test("PERM-03: 作っただけでは状態も確かめず、取得もしない")
  func initDoesNothing() {
    let assets = StubSpeechModelAssets(availability: .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)

    #expect(model.availability == nil)
    #expect(!model.canInstall)
    #expect(assets.availabilityCount == 0)
    #expect(assets.installCount == 0)
  }

  @Test("PERM-03: 状態の確認だけでは取得しない")
  func refreshDoesNotInstall() async {
    let assets = StubSpeechModelAssets(availability: .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)

    await model.refresh()

    #expect(model.availability == .notInstalled)
    #expect(model.canInstall)
    #expect(assets.installCount == 0)
  }

  @Test("PERM-03: 利用者の操作で取得し、終わったら状態を確かめ直す")
  func installsOnUserAction() async {
    let assets = StubSpeechModelAssets(availability: .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.install()

    #expect(assets.installCount == 1)
    #expect(model.availability == .installed)
    #expect(!model.canInstall)
    #expect(!model.installFailed)
    #expect(!model.isInstalling)
  }

  @Test(
    "PERM-03: 未取得でなければ取得を要求しない",
    arguments: [nil, .unsupported, .downloading, .installed] as [SpeechModelAvailability?])
  func doesNotInstallUnlessNotInstalled(availability: SpeechModelAvailability?) async {
    let assets = StubSpeechModelAssets(availability: availability ?? .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)
    if availability != nil {
      await model.refresh()
    }

    await model.install()

    #expect(assets.installCount == 0)
  }

  @Test("PERM-03: 取得に失敗したら失敗を示し、状態を確かめ直す")
  func reportsInstallFailure() async {
    let assets = StubSpeechModelAssets(
      availability: .notInstalled, installError: StubSpeechModelAssets.InstallFailure())
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.install()

    #expect(model.installFailed)
    #expect(model.availability == .notInstalled)
    #expect(model.canInstall)
  }

  @Test("PERM-03: 取得をキャンセルしたときは失敗として出さない")
  func cancellationIsNotFailure() async {
    let assets = StubSpeechModelAssets(
      availability: .notInstalled, installError: CancellationError())
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.install()

    #expect(!model.installFailed)
  }

  @Test("PERM-03, #199: 取得済みなら利用者の操作で予約を解除し、解除したことを示す")
  func releasesReservationOnUserAction() async {
    let assets = StubSpeechModelAssets(availability: .installed)
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()
    #expect(model.canRelease)

    await model.releaseReservation()

    #expect(assets.releaseCount == 1)
    #expect(model.releaseResult == .released)
    #expect(!model.canRelease)
    #expect(!model.isReleasing)
    // 予約の解除だけで、取得の要求はしない
    #expect(assets.installCount == 0)
  }

  @Test("PERM-03, #199: このアプリが予約していなければ、消せないことを示す")
  func reportsNotReserved() async {
    let assets = StubSpeechModelAssets(availability: .installed, reserved: false)
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.releaseReservation()

    #expect(model.releaseResult == .notReserved)
  }

  @Test(
    "PERM-03, #199: 取得済みでなければ予約の解除を要求しない",
    arguments: [nil, .unsupported, .notInstalled, .downloading] as [SpeechModelAvailability?])
  func doesNotReleaseUnlessInstalled(availability: SpeechModelAvailability?) async {
    let assets = StubSpeechModelAssets(availability: availability ?? .installed)
    let model = SpeechModelSettingsModel(assets: assets)
    if availability != nil {
      await model.refresh()
    }

    await model.releaseReservation()

    #expect(assets.releaseCount == 0)
    #expect(model.releaseResult == nil)
  }

  @Test("PERM-03, #199: 予約を解除した後に取得し直したら、解除の表示を消す")
  func installAfterReleaseClearsResult() async {
    let assets = StubSpeechModelAssets(availability: .installed)
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()
    await model.releaseReservation()
    #expect(model.releaseResult == .released)

    // OS がモデルを削除した
    assets.setAvailability(.notInstalled)
    await model.refresh()
    await model.install()

    #expect(model.releaseResult == nil)
    #expect(model.canRelease)
  }
}
