import Foundation
import Synchronization
import Testing
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// 権限の状態の代わり。テストから変えられる
final class FakePermissionReader: HostAppPermissionReader {
  private let state = Mutex((microphone: false, speechRecognition: false))

  func set(microphoneDenied: Bool = false, speechRecognitionDenied: Bool = false) {
    state.withLock { $0 = (microphoneDenied, speechRecognitionDenied) }
  }

  func isMicrophoneDenied() -> Bool { state.withLock { $0.microphone } }
  func isSpeechRecognitionDenied() -> Bool { state.withLock { $0.speechRecognition } }
}

/// 書き込み先の代わり。書いた状態を順に記録する。`failure` を設定すると書けない
final class RecordingStatusWriter: HostAppStatusWriting {
  struct WriteFailure: Error {}

  private let state = Mutex((saved: [HostAppStatus](), fails: false))

  var saved: [HostAppStatus] { state.withLock { $0.saved } }

  func setFails(_ fails: Bool) {
    state.withLock { $0.fails = fails }
  }

  func save(_ status: HostAppStatus) async throws {
    try state.withLock {
      if $0.fails { throw WriteFailure() }
      $0.saved.append(status)
    }
  }
}

/// 状態の確認を、テストが進めるまで止められるモデル
final class GatedSpeechModelAssets: SpeechModelAssets {
  private struct State {
    var availability: UtterSpeech.SpeechModelAvailability
    var held: [CheckedContinuation<Void, Never>] = []
    var holds = false
  }

  private let state: Mutex<State>

  init(availability: UtterSpeech.SpeechModelAvailability) {
    state = Mutex(State(availability: availability))
  }

  func set(_ availability: UtterSpeech.SpeechModelAvailability, holds: Bool = false) {
    state.withLock {
      $0.availability = availability
      $0.holds = holds
    }
  }

  var heldCount: Int { state.withLock { $0.held.count } }

  /// 止めている確認を1つ進める
  func releaseOne() {
    let continuation: CheckedContinuation<Void, Never>? = state.withLock {
      $0.held.isEmpty ? nil : $0.held.removeFirst()
    }
    continuation?.resume()
  }

  func availability() async -> UtterSpeech.SpeechModelAvailability {
    let (holds, value) = state.withLock { ($0.holds, $0.availability) }
    if holds {
      await withCheckedContinuation { continuation in
        state.withLock { $0.held.append(continuation) }
      }
    }
    return value
  }

  func install() async throws {}
}

@MainActor
struct HostAppStatusPublisherTests {
  private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let defaults: UserDefaults
  private let settingsStore: AppSettingsStore
  private let directory = TemporaryDirectory()

  init() {
    let suiteName = "utter-host-status-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    settingsStore = AppSettingsStore(defaults: defaults)
  }

  private func publisher(
    writer: any HostAppStatusWriting,
    permissions: any HostAppPermissionReader = FakePermissionReader(),
    engine: SpeechEngineSelection = .speechAnalyzer,
    model: (any SpeechModelAssets)? = FakeSpeechModelAssets(availability: .installed)
  ) -> HostAppStatusPublisher {
    let observedAt = observedAt
    return HostAppStatusPublisher(
      writer: writer, permissions: permissions, speechEngine: engine, speechModel: model,
      settingsStore: settingsStore, now: { observedAt })
  }

  // MARK: 状態の組み立て

  @Test("iAC-07: 拒否されたマイクの権限を書く。音声認識の権限は、それを求めるエンジンのときだけ")
  func deniedPermissions() {
    let both = HostAppStatusPublisher.status(
      observedAt: observedAt, microphoneDenied: true, speechRecognitionDenied: true,
      speechEngine: .speechAnalyzer, modelAvailability: .installed, usesCloudRefinement: false)
    #expect(both.deniedPermissions == [.microphone, .speechRecognition])

    let unconfigured = HostAppStatusPublisher.status(
      observedAt: observedAt, microphoneDenied: false, speechRecognitionDenied: true,
      speechEngine: .unconfigured, modelAvailability: nil, usesCloudRefinement: false)
    #expect(unconfigured.deniedPermissions.isEmpty)

    let none = HostAppStatusPublisher.status(
      observedAt: observedAt, microphoneDenied: false, speechRecognitionDenied: false,
      speechEngine: .speechAnalyzer, modelAvailability: .installed, usesCloudRefinement: false)
    #expect(none.deniedPermissions.isEmpty)
  }

  @Test(
    "iAC-07: モデルは取得済みなら ready、未取得・取得中は notDownloaded、使えない・STT 未設定は notApplicable",
    arguments: [
      (
        SpeechEngineSelection.speechAnalyzer, UtterSpeech.SpeechModelAvailability?.some(.installed),
        UtterCore.SpeechModelAvailability.ready
      ),
      (.speechAnalyzer, .some(.notInstalled), .notDownloaded),
      (.speechAnalyzer, .some(.downloading), .notDownloaded),
      (.speechAnalyzer, .some(.unsupported), .notApplicable),
      (.unconfigured, nil, .notApplicable),
    ])
  func speechModel(
    engine: SpeechEngineSelection, availability: UtterSpeech.SpeechModelAvailability?,
    expected: UtterCore.SpeechModelAvailability
  ) {
    let status = HostAppStatusPublisher.status(
      observedAt: observedAt, microphoneDenied: false, speechRecognitionDenied: false,
      speechEngine: engine, modelAvailability: availability, usesCloudRefinement: false)
    #expect(status.speechModel == expected)
  }

  @Test("iAC-07: 整形の処理系にクラウド AI を選んでいるかと観測時刻を書く")
  func cloudRefinementAndObservedAt() async throws {
    let writer = RecordingStatusWriter()
    let publisher = publisher(writer: writer)

    await publisher.publish()
    var settings = settingsStore.load()
    settings.refinementEngine = .cloudAI
    try settingsStore.save(settings)
    await publisher.publish()

    #expect(writer.saved.map(\.usesCloudRefinement) == [false, true])
    #expect(writer.saved.allSatisfy { $0.observedAt == observedAt })
  }

  @Test("iAC-07: 権限・モデルの状態が変わった後に書き直すと、新しい状態で置き換わる")
  func republishesChangedState() async throws {
    let permissions = FakePermissionReader()
    let model = GatedSpeechModelAssets(availability: .notInstalled)
    let store = HostAppStatusStore(directory: directory.url)
    let publisher = publisher(writer: store, permissions: permissions, model: model)

    await publisher.publish()
    let first = try await store.load()
    #expect(first?.deniedPermissions == [])
    #expect(first?.speechModel == .notDownloaded)

    permissions.set(microphoneDenied: true)
    model.set(.installed)
    await publisher.publish()
    let second = try await store.load()
    #expect(second?.deniedPermissions == [.microphone])
    #expect(second?.speechModel == .ready)
  }

  @Test("iAC-07: 続けて書くと呼んだ順に書き、先に観測した状態で後の状態を上書きしない")
  func writesInOrder() async {
    let writer = RecordingStatusWriter()
    let model = GatedSpeechModelAssets(availability: .notInstalled)
    model.set(.notInstalled, holds: true)
    let publisher = publisher(writer: writer, model: model)

    let first = Task { await publisher.publish() }
    #expect(await waitUntil { model.heldCount == 1 })
    let second = Task { await publisher.publish() }
    // 後の書き込みは前の書き込みが終わるまで観測しない
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.heldCount == 1)

    model.set(.installed, holds: true)
    model.releaseOne()
    #expect(await waitUntil { model.heldCount == 1 })
    model.releaseOne()
    _ = await (first.value, second.value)

    #expect(writer.saved.map(\.speechModel) == [.notDownloaded, .ready])
  }

  @Test("iAC-07: 書けなければ失敗を返し、次の書き込みで書き直せる")
  func writeFailure() async {
    let writer = RecordingStatusWriter()
    writer.setFails(true)
    let publisher = publisher(writer: writer)

    #expect(await publisher.publish() == .failed)

    writer.setFails(false)
    let result = await publisher.publish()
    #expect(result == .written(writer.saved[0]))
  }

  @Test("iOS-IPC-04, iAC-08: 書くのは権限・モデル・整形の設定・観測時刻だけで、API キーや本文を含まない")
  func writesNoSecrets() async throws {
    var settings = settingsStore.load()
    settings.refinementEngine = .cloudAI
    try settingsStore.save(settings)
    let store = HostAppStatusStore(directory: directory.url)
    await publisher(writer: store).publish()

    let data = try Data(contentsOf: directory.url.appendingPathComponent("status.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(object.keys) == ["observedAt", "deniedPermissions", "speechModel", "usesCloudRefinement"])
  }

  // MARK: App Group の設定

  @Test(
    "iAC-07, #56: App Group ID が未設定なら書き込み役を作らず、何も書かない", arguments: [nil, "", "  \n"] as [String?])
  func notConfigured(_ identifier: String?) {
    var opened: [String] = []
    let publisher = HostAppStatusPublisher.resolve(
      appGroupIdentifier: identifier, permissions: FakePermissionReader(),
      speechEngine: .unconfigured, speechModel: nil, settingsStore: settingsStore,
      makeWriter: {
        opened.append($0)
        return RecordingStatusWriter()
      })

    #expect(publisher == nil)
    #expect(opened.isEmpty)
  }

  @Test("iAC-07, #56: App Group のコンテナを開けなければ書かない")
  func appGroupUnavailable() {
    let publisher = HostAppStatusPublisher.resolve(
      appGroupIdentifier: "group.example.utter", permissions: FakePermissionReader(),
      speechEngine: .unconfigured, speechModel: nil, settingsStore: settingsStore,
      makeWriter: { _ in nil })

    #expect(publisher == nil)
  }

  @Test("iAC-07, #56: App Group ID を設定すると、前後の空白を除いた ID のコンテナに書く")
  func appGroup() async throws {
    var opened: [String] = []
    let store = HostAppStatusStore(directory: directory.url)
    let publisher = try #require(
      HostAppStatusPublisher.resolve(
        appGroupIdentifier: " group.example.utter ", permissions: FakePermissionReader(),
        speechEngine: .unconfigured, speechModel: nil, settingsStore: settingsStore,
        makeWriter: {
          opened.append($0)
          return store
        }))

    await publisher.publish()

    #expect(opened == ["group.example.utter"])
    #expect(try await store.load() != nil)
  }
}
