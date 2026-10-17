import Testing

@testable import UtterSpeech

struct ModelRetentionPolicyTests {
  private func policy(
    _ mode: ModelRetentionMode, performanceAllowed: Bool = false
  ) throws -> ModelRetentionPolicy {
    try ModelRetentionPolicy(mode: mode, performanceRetentionAllowed: performanceAllowed)
  }

  @Test(
    "AC-11: メモリ圧迫時は、どのモードでも高負荷モデルのロードを抑止する",
    arguments: ModelRetentionMode.allCases, [MemoryPressure.warning, .critical])
  func defersHeavyModelUnderMemoryPressure(
    _ mode: ModelRetentionMode, _ pressure: MemoryPressure
  ) throws {
    let state = DeviceResourceState(memoryPressure: pressure)
    let policy = try policy(mode, performanceAllowed: true)

    #expect(policy.loadDecision(for: .heavy, in: state) == .deferredForMemoryPressure)
    #expect(policy.loadDecision(for: .light, in: state) == .allowed)
  }

  @Test("AC-11: メモリ圧迫がなければ高負荷モデルもロードできる")
  func allowsHeavyModelWithoutPressure() throws {
    #expect(try policy(.balanced).loadDecision(for: .heavy, in: DeviceResourceState()) == .allowed)
  }

  @Test("6章: 省電力モードは推論後にモデルを解放する")
  func powerSavingReleasesAfterInference() throws {
    #expect(try policy(.powerSaving).retention(in: DeviceResourceState()) == .releaseNow)
  }

  @Test("6章: バランスモードは短時間保持し、メモリ圧迫・低バッテリーで解放する")
  func balancedKeepsBrieflyAndReleasesUnderPressure() throws {
    let balanced = try ModelRetentionPolicy(mode: .balanced, balancedRetention: .seconds(45))

    #expect(balanced.retention(in: DeviceResourceState()) == .keep(for: .seconds(45)))
    #expect(balanced.retention(in: DeviceResourceState(memoryPressure: .warning)) == .releaseNow)
    #expect(balanced.retention(in: DeviceResourceState(isBatteryLow: true)) == .releaseNow)
  }

  @Test("6章: 高速モードは許可があれば、低バッテリーでも保持する")
  func performanceKeepsWithPermission() throws {
    let performance = try policy(.performance, performanceAllowed: true)

    #expect(performance.effectiveMode == .performance)
    #expect(performance.retention(in: DeviceResourceState()) == .keepUntilStateChanges)
    #expect(
      performance.retention(in: DeviceResourceState(isBatteryLow: true)) == .keepUntilStateChanges)
  }

  @Test(
    "6章, AC-11: メモリ圧迫時は、どのモードでもロード済みのモデルを解放する",
    arguments: ModelRetentionMode.allCases, [MemoryPressure.warning, .critical])
  func releasesUnderMemoryPressure(_ mode: ModelRetentionMode, _ pressure: MemoryPressure) throws {
    let policy = try policy(mode, performanceAllowed: true)

    #expect(policy.retention(in: DeviceResourceState(memoryPressure: pressure)) == .releaseNow)
  }

  @Test("6章: 高速モードを許可していなければバランスモードとして扱う")
  func performanceWithoutPermissionActsAsBalanced() throws {
    let performance = try policy(.performance)

    #expect(performance.effectiveMode == .balanced)
    #expect(
      performance.retention(in: DeviceResourceState())
        == .keep(for: ModelRetentionPolicy.defaultBalancedRetention))
  }

  @Test("6章: 保持時間が0以下の設定は拒否する", arguments: [Duration.zero, .seconds(-1)])
  func rejectsNonPositiveRetention(_ retention: Duration) {
    #expect(throws: ModelRetentionPolicyError.nonPositiveRetention) {
      try ModelRetentionPolicy(balancedRetention: retention)
    }
  }
}
