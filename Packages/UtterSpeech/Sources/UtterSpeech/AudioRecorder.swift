/// マイクから録音する口（REC-04, REC-05）。
///
/// 本番実装は OS の録音 API を使うため各アプリに置き（macOS: Apps/macOS の `AVAudioEngineRecorder`）、
/// テストは `StubAudioRecorder` を使う。音声は `AudioChunk`（モノラル・16kHz）で流し、
/// ファイルやログには出さない（一時音声の保存は `TemporaryAudioStore` の責務）。
///
/// - 同時に録音するのは1つだけ。録音中や開始の途中で `start` を呼ぶと `.alreadyRecording` を投げる（連打）
/// - 録音を始める前にマイクの使用許可を確かめる。未確認なら要求し、許可がなければ録音を始めない（PERM-01）
/// - 録音の終わりは理由によらず `AudioRecording.ends` に1回だけ流す。OS の都合で録音が止まったとき
///   （入力機器の変化・スリープなど）は `.interrupted(_:)` で知らせ、自動で再開しない
public protocol AudioRecorder: Sendable {
  /// 録音を始める。
  /// - Parameter buffer: 音声バッファの上限（REC-05。最大録音時間）
  /// - Throws: 使用許可がない、録音中、入力機器がない、録音を始められないなど。投げたときは録音していない
  func start(buffer: AudioStreamBuffer) async throws(AudioRecorderError) -> AudioRecording

  /// 録音を終える。それまでの音声は `AudioRecording.chunks` からすべて読める。
  /// 開始の途中なら開始を取りやめる（`start` は `.cancelled` を投げる）。録音していなければ何もしない
  func stop() async
}

/// 録音を始められなかった理由。音声は含めない。
public enum AudioRecorderError: Error, Hashable, Sendable {
  /// マイクの使用が拒否されている（PERM-01, PERM-02。システム設定での再設定を案内する）
  case microphoneAccessDenied
  /// マイクの使用が制限されている（管理者の設定など。利用者は許可を変えられない）
  case microphoneAccessRestricted
  /// すでに録音中か、開始の途中（REC-04 の連打）
  case alreadyRecording
  /// 開始の途中で `stop()` が呼ばれた
  case cancelled
  /// 使える入力機器がない
  case inputDeviceUnavailable
  /// 録音を始められなかった
  case startFailed
}
