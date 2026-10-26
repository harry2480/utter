import Testing
import UtterCore

@testable import UtterSpeech

struct STTWorkerResourceForwarderTests {
  private func resources(
    _ policy: ModelRetentionPolicy, _ state: DeviceResourceState = DeviceResourceState()
  ) -> STTWorkerResources {
    STTWorkerResources(policy: policy, deviceState: state)
  }

  @Test("6章: 監視を始めたら現在の値を1回送る")
  func sendsInitialResources() async throws {
    let policy = try ModelRetentionPolicy()
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(
      policy: policy, receiver: receiver)

    forwarder.finish()
    await forwarder.run(from: DeviceResourceObservation(isLowPowerModeEnabled: true))

    #expect(await receiver.received == [resources(policy, DeviceResourceState(isBatteryLow: true))])
  }

  @Test("AC-11: 端末の状態が変わったときだけ送る")
  func sendsOnlyOnChange() async throws {
    let policy = try ModelRetentionPolicy()
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(
      policy: policy, receiver: receiver)

    forwarder.send(.memoryPressure(.normal))
    forwarder.send(.memoryPressure(.warning))
    forwarder.send(.memoryPressure(.warning))
    forwarder.send(.memoryPressure(.critical))
    forwarder.send(.memoryPressure(.normal))
    forwarder.finish()
    await forwarder.run(from: DeviceResourceObservation())

    #expect(
      await receiver.received == [
        resources(policy),
        resources(policy, DeviceResourceState(memoryPressure: .warning)),
        resources(policy, DeviceResourceState(memoryPressure: .critical)),
        resources(policy),
      ])
  }

  @Test("6章: 判定に使う値が変わらない変化は送らない")
  func ignoresChangesWithoutEffect() async throws {
    let policy = try ModelRetentionPolicy()
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(
      policy: policy, receiver: receiver)

    // 低電力モードのまま電源が変わっても、低バッテリーのまま
    forwarder.send(.power(source: .battery, batteryWarning: .early))
    forwarder.send(.power(source: .externalPower, batteryWarning: .none))
    // 外部電源のまま低電力モードを切ると低バッテリーでなくなる
    forwarder.send(.lowPowerMode(isEnabled: false))
    forwarder.finish()
    await forwarder.run(from: DeviceResourceObservation(isLowPowerModeEnabled: true))

    #expect(
      await receiver.received == [
        resources(policy, DeviceResourceState(isBatteryLow: true)),
        resources(policy),
      ])
  }

  @Test("6章: 保持の設定が変わったときだけ送る")
  func sendsOnPolicyChange() async throws {
    let balanced = try ModelRetentionPolicy()
    let powerSaving = try ModelRetentionPolicy(mode: .powerSaving)
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(
      policy: balanced, receiver: receiver)

    forwarder.updatePolicy(balanced)
    forwarder.updatePolicy(powerSaving)
    forwarder.send(.memoryPressure(.warning))
    forwarder.updatePolicy(powerSaving)
    forwarder.finish()
    await forwarder.run(from: DeviceResourceObservation())

    #expect(
      await receiver.received == [
        resources(balanced),
        resources(powerSaving),
        resources(powerSaving, DeviceResourceState(memoryPressure: .warning)),
      ])
  }

  @Test("AC-11: メモリ圧迫を送った後は、Worker が高負荷モデルをロードしない")
  func deferredHeavyLoadThroughWorker() async throws {
    let policy = try ModelRetentionPolicy()
    let loader = StubSpeechModelLoader(weight: .heavy, steps: [.confirmed("明日は")])
    let connector = StubSTTWorkerConnector { STTWorkerService(loaders: [.stub: loader]) }
    let recognizer = STTWorkerSpeechRecognizer(engine: .stub, connector: connector)
    let forwarder = STTWorkerResourceForwarder(
      policy: policy, receiver: recognizer)

    forwarder.send(.memoryPressure(.warning))
    forwarder.finish()
    await forwarder.run(from: DeviceResourceObservation())
    // Worker は最初の認識で起動し、そのときに最後に受け取った値を送る
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    input.finish()
    var kinds: [RecognitionEvent.Kind] = []
    for await event in recognizer.recognize(audio, session: SessionID()) {
      kinds.append(event.kind)
    }

    #expect(kinds == [.failed(.resourceLimited)])
    #expect(loader.loadCount == 0)
    let connection = try #require(connector.connections.first)
    #expect(
      connection.sentRequests.first
        == .updateResources(resources(policy, DeviceResourceState(memoryPressure: .warning))))
  }

  @Test("AC-11: 送信中に届いた変化も、届いた順に送る")
  func sendsChangesWhileRunning() async throws {
    let policy = try ModelRetentionPolicy()
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(policy: policy, receiver: receiver)
    let run = Task { await forwarder.run(from: DeviceResourceObservation()) }

    #expect(await eventually { await receiver.received.count == 1 })
    forwarder.send(.memoryPressure(.critical))
    #expect(await eventually { await receiver.received.count == 2 })
    forwarder.send(.lowPowerMode(isEnabled: true))
    forwarder.finish()
    await run.value

    #expect(
      await receiver.received == [
        resources(policy),
        resources(policy, DeviceResourceState(memoryPressure: .critical)),
        resources(policy, DeviceResourceState(memoryPressure: .critical, isBatteryLow: true)),
      ])
  }

  @Test("6章: 受け取りを終えた後の変化は送らない")
  func ignoresSignalsAfterFinish() async throws {
    let policy = try ModelRetentionPolicy()
    let receiver = StubSTTWorkerResourceReceiver()
    let forwarder = STTWorkerResourceForwarder(policy: policy, receiver: receiver)

    forwarder.finish()
    forwarder.send(.memoryPressure(.warning))
    await forwarder.run(from: DeviceResourceObservation())

    #expect(await receiver.received == [resources(policy)])
  }
}
