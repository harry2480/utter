import UtterSpeech

/// 本体アプリの録音の口（12.4節, iOS-PERF-03）。
///
/// AVAudioSession / AVAudioEngine を使う実装は Apps/iOS に置く。音声はチャンクとして渡すだけで、
/// ファイル・ログには出さない。割り込みの通知は実装が受けず、`RecordingSystemSignal` として別に届ける。
/// UtterSpeech にも macOS 用の `AudioRecorder` があるため、両方を import する側では
/// `UtteriOSKit.AudioRecorder` と書く。
@MainActor
public protocol AudioRecorder: AnyObject {
  /// 流すチャンクのサンプリング周波数（Hz）。取得済みの音声の長さの計算に使う
  var sampleRate: Int { get }

  /// マイクの利用を許可されているか確かめる。未決定なら利用者に求める
  func requestPermission() async -> Bool

  /// オーディオセッションを有効にして録音を始める。
  /// - Parameters:
  ///   - onChunk: 録音したチャンク。録音のスレッドから呼ばれる
  ///   - onFailure: 録音を続けられなくなった（経路の変更後にエンジンを再開できないなど）。任意のスレッドから呼ばれる
  /// - Throws: マイクを使えない、またはエンジンを開始できない
  func start(
    onChunk: @escaping @Sendable (AudioChunk) -> Void,
    onFailure: @escaping @Sendable () -> Void
  ) throws

  /// 録音を止め、オーディオセッションを無効にする。止まっていれば何もしない
  func stop()
}
