import UtterSpeech

/// 端末の状態の監視と、STT Worker への送信の結線（6章, AC-11）。
///
/// アプリの起動から終了まで、録音・認識の有無に関わらず動かす。OS の通知だけで動くため待機中の負荷はほとんどない（6章）。
/// Worker が未起動のあいだは `STTWorkerSpeechRecognizer` が最後の値を持ち、起動したときに送る。
/// `stop()` の後は再開しない（送信のストリームを閉じるため）。もう一度始めるときは作り直す
@MainActor
final class DeviceResourceMonitoring {
  private let monitor = SystemDeviceResourceMonitor()
  private let forwarder: STTWorkerResourceForwarder
  private var task: Task<Void, Never>?
  private var isStopped = false

  init(policy: ModelRetentionPolicy, receiver: any STTWorkerResourceReceiving) {
    forwarder = STTWorkerResourceForwarder(policy: policy, receiver: receiver)
  }

  func start() {
    guard task == nil, !isStopped else { return }
    let forwarder = forwarder
    let observation = monitor.start { forwarder.send($0) }
    task = Task { await forwarder.run(from: observation) }
  }

  /// 保持の設定（6章）が変わったときに呼ぶ。設定画面の結線（Phase 1）で使う
  func updatePolicy(_ policy: ModelRetentionPolicy) {
    forwarder.updatePolicy(policy)
  }

  func stop() {
    isStopped = true
    monitor.stop()
    forwarder.finish()
    task = nil
  }
}
