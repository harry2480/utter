import Synchronization
import Testing
import UtterSpeech

@testable import UtteriOSKit

/// モデルの代わり。取得の回数を数え、取得後の状態を返す
final class FakeSpeechModelAssets: SpeechModelAssets {
  struct InstallFailure: Error {}

  private struct State {
    var availability: SpeechModelAvailability
    var installCount = 0
  }

  private let state: Mutex<State>
  private let installError: (any Error)?

  init(availability: SpeechModelAvailability, installError: (any Error)? = nil) {
    state = Mutex(State(availability: availability))
    self.installError = installError
  }

  var installCount: Int { state.withLock { $0.installCount } }

  func availability() async -> SpeechModelAvailability {
    state.withLock { $0.availability }
  }

  func install() async throws {
    state.withLock { $0.installCount += 1 }
    if let installError { throw installError }
    state.withLock { $0.availability = .installed }
  }
}

@MainActor
struct SpeechModelSettingsModelTests {
  @Test("PERM-03: 状態の確認だけでは取得しない")
  func refreshDoesNotInstall() async {
    let assets = FakeSpeechModelAssets(availability: .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)

    await model.refresh()

    #expect(model.availability == .notInstalled)
    #expect(model.canInstall)
    #expect(assets.installCount == 0)
  }

  @Test("PERM-03: 利用者の操作で取得し、終わったら状態を確かめ直す")
  func installsOnUserAction() async {
    let assets = FakeSpeechModelAssets(availability: .notInstalled)
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
    let assets = FakeSpeechModelAssets(availability: availability ?? .notInstalled)
    let model = SpeechModelSettingsModel(assets: assets)
    if availability != nil {
      await model.refresh()
    }

    await model.install()

    #expect(assets.installCount == 0)
  }

  @Test("PERM-03: 取得に失敗したら失敗を示し、状態を確かめ直す")
  func reportsInstallFailure() async {
    let assets = FakeSpeechModelAssets(
      availability: .notInstalled, installError: FakeSpeechModelAssets.InstallFailure())
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.install()

    #expect(model.installFailed)
    #expect(model.availability == .notInstalled)
    #expect(model.canInstall)
  }

  @Test("PERM-03: 取得をキャンセルしたときは失敗として出さない")
  func cancellationIsNotFailure() async {
    let assets = FakeSpeechModelAssets(
      availability: .notInstalled, installError: CancellationError())
    let model = SpeechModelSettingsModel(assets: assets)
    await model.refresh()

    await model.install()

    #expect(!model.installFailed)
  }
}
