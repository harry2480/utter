#if DEBUG
  import Observation
  import UtterSpeech

  /// 実機でマイクの録音を確かめるための、Debug ビルドだけのメニュー項目のモデル（REC-04, REC-05）。
  ///
  /// 録音・ホットキー・HUD を結線するまでの確認用。音声は読み捨て、終わった理由と長さだけを表示する。
  @MainActor
  @Observable
  final class RecordingCheck {
    private(set) var status = "未録音"
    /// 開始の途中（使用許可を待っている間）を含めて録音中なら `true`
    private(set) var isRecording = false
    private let recorder: any AudioRecorder

    init(recorder: any AudioRecorder) {
      self.recorder = recorder
    }

    func toggle() async {
      guard !isRecording else {
        await recorder.stop()
        return
      }
      // 許可を待つ間にもう一度押したら、開始を取りやめる
      isRecording = true
      status = "開始中"
      do {
        let recording = try await recorder.start(buffer: AudioStreamBuffer())
        status = "録音中"
        // 音声認識の代わりに音声を読み捨てる（読まないとストリームに溜まる）
        Task.detached {
          for await _ in recording.chunks {}
        }
        for await end in recording.ends {
          status =
            "前回: \(Self.label(end.reason))・\(end.capturedDuration.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))"
        }
      } catch {
        status = "開始できない: \(Self.label(error))"
      }
      isRecording = false
    }

    private static func label(_ reason: AudioRecordingEndReason) -> String {
      switch reason {
      case .finished: "停止"
      case .limitReached: "上限に到達"
      case .cancelled: "受け手が破棄"
      case .interrupted(let interruption): "割り込み（\(interruption)）"
      }
    }

    private static func label(_ error: AudioRecorderError) -> String {
      switch error {
      case .microphoneAccessDenied: "マイクが拒否されている"
      case .microphoneAccessRestricted: "マイクが制限されている"
      case .alreadyRecording: "録音中"
      case .cancelled: "取りやめた"
      case .inputDeviceUnavailable: "入力機器がない"
      case .startFailed: "録音を始められない"
      }
    }
  }
#endif
