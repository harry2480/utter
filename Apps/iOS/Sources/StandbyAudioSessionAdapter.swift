import AVFoundation
import UtteriOSKit

/// 待機セッション中のオーディオセッション（iOS-04, iOS-PERF-02, iOS-PERF-03）。
///
/// 利用者が明示的に待機を始めたときだけ、`playAndRecord` のオーディオセッションを保ち、入力を開いたまま
/// `AVAudioApplication` のミュートで音を捨てる（合図まで、マイクの使用表示を出さない）。ミュート中の音は
/// 認識器に渡さず、保存もしない。入力を開いておくのは、バックグラウンドでアプリを動かし続けるため
/// （Verification/iOSKeyboardProbe の mutedMicrophone 方式）。iOS のバックグラウンド実行の制限は迂回しない。
@MainActor
final class StandbyAudioSessionAdapter: StandbyAudioSession {
  /// 待機のためにオーディオセッションを保っているか。録音（`AudioEngineRecorder`）は、保っている間は
  /// カテゴリを変えず、終えたときにセッションを手放さない
  private(set) var isHolding = false

  private var engine: AVAudioEngine?
  private var configurationObserver: (any NSObjectProtocol)?
  private var isMuted = true

  func beginStandby() throws {
    guard !isHolding else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .default,
      options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
    try session.setActive(true)
    do {
      try startEngine()
    } catch {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw error
    }
    isHolding = true
    applyMute()
  }

  func endStandby() {
    guard isHolding else { return }
    isHolding = false
    stopEngine()
    isMuted = true
    try? AVAudioApplication.shared.setInputMuted(false)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func setInputMuted(_ muted: Bool) {
    isMuted = muted
    applyMute()
  }

  /// 割り込みが終わったあとに、待機のオーディオセッションを取り戻す（iOS-PERF-03）
  func resumeAfterInterruption() {
    guard isHolding else { return }
    stopEngine()
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      try startEngine()
      applyMute()
    } catch {
      // 取り戻せなければ、待機は続くが録音を始められない。キーボードは更新の途絶で気づく
    }
  }

  private func applyMute() {
    guard isHolding else { return }
    try? AVAudioApplication.shared.setInputMuted(isMuted)
  }

  private func startEngine() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw AudioEngineRecorder.RecorderError.microphoneUnavailable
    }
    // 待機中に受けた音は読み捨てる。音声認識にもファイルにも渡さない
    input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.discardingTap())
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    self.engine = engine
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] notification in
      let source = (notification.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, let engine = self.engine, source == ObjectIdentifier(engine) else {
          return
        }
        // 経路の変更で止まったエンジンを作り直す。作り直せなければ待機は続けるが入力は止まる
        self.stopEngine()
        try? self.startEngine()
        self.applyMute()
      }
    }
  }

  private func stopEngine() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      self.engine = nil
    }
  }

  /// タップのクロージャは録音のスレッドで呼ばれる。MainActor の文脈で作ると実行時に落ちるため、
  /// 隔離のない static 関数で作る（`AudioEngineRecorder` と同じ）
  private nonisolated static func discardingTap() -> AVAudioNodeTapBlock {
    { _, _ in }
  }
}
