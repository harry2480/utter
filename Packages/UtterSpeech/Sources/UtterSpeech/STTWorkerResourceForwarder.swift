/// モデル保持の設定と端末の状態を受け取る側（6章, AC-11）。本番は `STTWorkerSpeechRecognizer`、テストは `StubSTTWorkerResourceReceiver`
public protocol STTWorkerResourceReceiving: Sendable {
  func updateResources(_ resources: STTWorkerResources) async
}

extension STTWorkerSpeechRecognizer: STTWorkerResourceReceiving {}

/// 端末の状態の変化と保持の設定を受け取り、STT Worker へ送る値（`STTWorkerResources`）が変わったときだけ送る（6章, AC-11）。
///
/// 監視（OS の通知）からは `send(_:)`、設定の変更からは `updatePolicy(_:)` を同期的に呼ぶ。届いた順に `run(from:)` で1件ずつ処理するため、
/// 送る順が入れ替わらない。`run(from:)` は最初に監視を始めた時点の値を1回送り、以後は値が変わったときだけ送る。
/// `run(from:)` より前に届いた変化は捨てずに、始めた時点の値に続けて処理する。
/// 端末の状態がどう変わっても、判定に使う値（`DeviceResourceState`）が同じなら送らない
public final class STTWorkerResourceForwarder: Sendable {
  private enum Input: Sendable {
    case signal(DeviceResourceSignal)
    case policy(ModelRetentionPolicy)
  }

  private let initialPolicy: ModelRetentionPolicy
  private let receiver: any STTWorkerResourceReceiving
  private let inputs: AsyncStream<Input>
  private let continuation: AsyncStream<Input>.Continuation

  /// - Parameters:
  ///   - policy: 保持の設定
  ///   - receiver: 送り先
  public init(policy: ModelRetentionPolicy, receiver: any STTWorkerResourceReceiving) {
    initialPolicy = policy
    self.receiver = receiver
    (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
  }

  /// 端末の状態の変化を受け取る。どのスレッドから呼んでもよい
  public func send(_ signal: DeviceResourceSignal) {
    continuation.yield(.signal(signal))
  }

  /// 保持の設定の変更を受け取る。どのスレッドから呼んでもよい
  public func updatePolicy(_ policy: ModelRetentionPolicy) {
    continuation.yield(.policy(policy))
  }

  /// 受け取りを終える。`run(from:)` は残りを処理してから戻る
  public func finish() {
    continuation.finish()
  }

  /// 受け取った変化を順に処理して送る。`finish()` まで戻らない。1回だけ呼ぶ
  /// - Parameter observation: 監視を始めた時点の端末の状態
  public func run(from observation: DeviceResourceObservation) async {
    var policy = initialPolicy
    var observation = observation
    var sent = STTWorkerResources(policy: policy, deviceState: observation.deviceState)
    await receiver.updateResources(sent)
    for await input in inputs {
      switch input {
      case .signal(let signal):
        observation.apply(signal)
      case .policy(let newPolicy):
        policy = newPolicy
      }
      let resources = STTWorkerResources(policy: policy, deviceState: observation.deviceState)
      guard resources != sent else { continue }
      sent = resources
      await receiver.updateResources(resources)
    }
  }
}

/// 受け取った `STTWorkerResources` を記録するテスト用の受け手
public actor StubSTTWorkerResourceReceiver: STTWorkerResourceReceiving {
  /// 受け取った値（受け取った順）
  public private(set) var received: [STTWorkerResources] = []

  public init() {}

  public func updateResources(_ resources: STTWorkerResources) {
    received.append(resources)
  }
}
