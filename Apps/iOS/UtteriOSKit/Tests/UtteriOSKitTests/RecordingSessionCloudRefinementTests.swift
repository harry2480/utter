import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// 録音セッションの整形を、同意・API キーの有無でクラウド整形と Local Basic に振り分ける（iOS-04, iOS-10）。
@MainActor
struct RecordingSessionCloudRefinementTests {
  private let directory = TemporaryDirectory()
  private let temporaryDefaults: TemporaryDefaults
  private let settingsStore: AppSettingsStore
  private let recorder = FakeRecorder()
  private let keyStore = StubAPIKeyStore()
  private let spoken = "えーと明日の会議は10時からです"
  private let cloudText = "明日の会議は10時からです。"
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    temporaryDefaults = try TemporaryDefaults()
    settingsStore = AppSettingsStore(defaults: temporaryDefaults.defaults)
    // 既定は Local Basic。各テストは処理系にクラウド AI を選んだ状態から始める
    try settingsStore.save(AppSettings(refinementEngine: .cloudAI))
  }

  private var store: SharedResultStore { SharedResultStore(directory: directory.url) }

  private var localText: String {
    LocalBasicRefiner().refine(RefinementRequest(text: spoken, mode: .natural))
  }

  private func model(
    provider: StubAIProvider, budget: StubBudgetSource,
    recognizer: (any SpeechRecognizer)? = nil
  ) -> RecordingSessionModel {
    let createdAt = createdAt
    return RecordingSessionModel(
      recorder: recorder,
      recognizer: recognizer ?? StubSpeechRecognizer(steps: [.confirmed(spoken)]),
      cloudRefinement: CloudRefinement(
        settingsStore: settingsStore, apiKeyStore: keyStore, budgetSource: budget,
        makeProvider: { _, _ in provider }, date: { createdAt }),
      storage: SharedResultStorage(store: store, sharing: .appGroup),
      copier: RecordingCopier(),
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      date: { createdAt })
  }

  private func budget() throws -> StubBudgetSource {
    StubBudgetSource(
      budget: try CloudFixtures.generousBudget(month: YearMonth(year: 2027, month: 1)))
  }

  private func record(_ model: RecordingSessionModel) async {
    await model.startRecording()
    recorder.emit(seconds: 1)
    model.stopRecording()
  }

  private func storedTexts() async throws -> [String] {
    var texts: [String] = []
    for sessionID in try await store.storedSessionIDs() {
      if let result = try await store.load(sessionID: sessionID) {
        texts.append(result.text)
      }
    }
    return texts
  }

  private func grantConsent() throws {
    try ConsentSettingsController(store: settingsStore).setGranted(
      true, for: CloudFixtures.claudeConsent)
  }

  @Test("iOS-10, AC-06: 同意していなければ従来どおり Local Basic の結果を保存し、通知も出さない")
  func noConsentSavesLocal() async throws {
    try keyStore.save(APIKey("sk-ant-test"))
    let provider = StubAIProvider(behavior: .respond(cloudText))
    let model = model(provider: provider, budget: try budget())

    await record(model)

    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedTexts() == [localText])
    #expect(await provider.callCount == 0)
    #expect(model.refinementNotice == nil)
  }

  @Test("iOS-10, AC-12: 同意していても API キーが未設定なら Local Basic の結果を保存し、未設定を知らせる")
  func consentWithoutKeySavesLocalWithNotice() async throws {
    try grantConsent()
    let provider = StubAIProvider(behavior: .respond(cloudText))
    let model = model(provider: provider, budget: try budget())

    await record(model)

    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedTexts() == [localText])
    #expect(await provider.callCount == 0)
    #expect(model.refinementNotice == .apiKeyNotSet)
  }

  @Test("iOS-10: 同意と API キーがあればクラウド整形の結果を保存する")
  func consentAndKeySavesCloudResult() async throws {
    try grantConsent()
    try keyStore.save(APIKey("sk-ant-test"))
    let provider = StubAIProvider(behavior: .respond(cloudText))
    let model = model(provider: provider, budget: try budget())

    await record(model)

    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedTexts() == [cloudText])
    #expect(await provider.callCount == 1)
    #expect(model.refinementNotice == nil)
  }

  @Test("4.1節: クラウド整形が退避したら Local Basic の結果を保存し、理由を知らせる")
  func fallbackSavesLocalWithNotice() async throws {
    try grantConsent()
    try keyStore.save(APIKey("sk-ant-test"))
    let provider = StubAIProvider(behavior: .fail(.authenticationExpired))
    let model = model(provider: provider, budget: try budget())

    await record(model)

    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedTexts() == [localText])
    #expect(model.refinementNotice == .authenticationFailed)
    #expect(!model.refinementNotice!.message.contains("sk-ant-test"))
  }

  @Test("REC-01: クラウド整形を待つ間にキャンセルしたら結果を保存せず、推定費用の記録は済ませる")
  func cancelWhileRefiningDiscardsResult() async throws {
    try grantConsent()
    try keyStore.save(APIKey("sk-ant-test"))
    let provider = StubAIProvider(behavior: .respond(cloudText), delay: .seconds(3600))
    let budget = try budget()
    let model = model(provider: provider, budget: budget)

    await record(model)
    #expect(await waitUntil { model.phase == .refining })
    let sent = await waitUntilAsync { await provider.callCount == 1 }
    #expect(sent)
    model.cancel()

    #expect(model.phase == .idle)
    let finished = await waitUntilAsync { await budget.finishCount == 1 }
    #expect(finished)
    #expect(try await storedTexts().isEmpty)
  }
}

/// 非同期の条件を満たすまで待つ
@MainActor
func waitUntilAsync(
  timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !(await condition()) {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return true
}
