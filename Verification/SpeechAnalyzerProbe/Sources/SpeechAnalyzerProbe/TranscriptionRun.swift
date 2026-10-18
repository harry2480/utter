import AVFoundation
import Speech

/// 入力の種類
enum AudioSource: Sendable {
  case file(URL)
  case microphone(seconds: Double)

  var label: String {
    switch self {
    // パスには個人のディレクトリ名が入りうるため、ファイル名だけを記録する
    case .file(let url): "file:\(url.lastPathComponent)"
    case .microphone(let seconds): "mic:\(fixed(seconds, digits: 1))s"
    }
  }
}

// MARK: - ログに書くイベント

struct RunStartEvent: Encodable {
  let type = "run"
  let sampleID: String?
  let source: String
  /// 指定したロケール
  let requestedLocale: String
  /// `supportedLocale(equivalentTo:)` で解決した、実際に使うロケール
  let locale: String
  let preset: String
  let reportingOptions: [String]
  let pace: String
  let retention: String
  let analyzerFormat: String
  let machine: MachineInfo
  let baselinePhysFootprintMB: Double?
}

struct ResultEvent: Encodable {
  let type = "result"
  let sampleID: String?
  /// `volatile`（暫定）/ `final`（確定）
  let kind: String
  let audioStart: Double
  let audioEnd: Double
  let resultsFinalizationTime: Double
  /// 音声時刻 0 からの壁時計の経過秒
  let wallTime: Double?
  /// 受信時刻 − 結果の音声終了時刻（pace=realtime / mic のときだけ）
  let latency: Double?
  let text: String
}

struct MemoryEvent: Encodable {
  let type = "memory"
  let sampleID: String?
  /// 実行開始からの壁時計の経過秒
  let elapsed: Double
  let physFootprintMB: Double
  let lifetimeMaxPhysFootprintMB: Double
}

struct RunSummary: Codable, Sendable {
  var type = "summary"
  var sampleID: String?
  var audioSeconds = 0.0
  /// `prepareToAnalyze` にかかった秒（モデルのロードを含む）
  var prepareSeconds = 0.0
  var volatileCount = 0
  var finalCount = 0
  /// 音声時刻 0 から最初の結果（暫定・確定とも）を受け取るまでの秒（無音の区間を含む）
  var firstResultWallTime: Double?
  var volatileLatency: LatencyStats?
  var finalLatency: LatencyStats?
  /// 入力の終わり → 最後の確定結果の受信（pace=realtime / mic のときだけ）
  var stopToLastFinalSeconds: Double?
  /// 入力の終わり → `finalizeAndFinishThroughEndOfInput()` の完了（pace=realtime / mic のときだけ）
  var stopToFinishSeconds: Double?
  /// 処理時間 ÷ 音声の長さ（音声時刻 0 から結果のストリームの終了まで）。pace=fast のときの処理速度の目安
  var realTimeFactor: Double?
  var cancel: CancelSummary?
  var baselinePhysFootprintMB: Double?
  var peakSampledPhysFootprintMB: Double?
  var lifetimeMaxPhysFootprintMB: Double?
  var error: String?
}

struct LatencyStats: Codable, Sendable {
  let count: Int
  let p50: Double
  let p95: Double
  let max: Double

  init?(_ values: [Double]) {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double {
      sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }
    count = sorted.count
    p50 = percentile(0.5)
    p95 = percentile(0.95)
    max = sorted[sorted.count - 1]
  }
}

struct CancelSummary: Codable, Sendable {
  /// 音声時刻 0 から `cancelAndFinishNow()` を呼ぶまでの秒
  let calledAt: Double
  /// `cancelAndFinishNow()` の呼び出し → 戻り
  let returnSeconds: Double
  /// 呼び出し → 結果のストリームの終了
  let resultsEndSeconds: Double?
  /// 呼び出し後に届いた結果の数（0 が期待値）
  let resultsAfterCancel: Int
}

// MARK: - 結果の集計

actor ResultRecorder {
  private let sampleID: String?
  private let origin: AudioOrigin
  private let measuresLatency: Bool
  private let printsText: Bool
  private let log: EventLog
  private(set) var finalText = ""
  private(set) var summary = RunSummary()
  private var volatileLatencies: [Double] = []
  private var finalLatencies: [Double] = []
  private(set) var lastFinalReceived: ContinuousClock.Instant?
  private var cancelCalled: ContinuousClock.Instant?
  private(set) var resultsAfterCancel = 0

  init(
    sampleID: String?, origin: AudioOrigin, measuresLatency: Bool, printsText: Bool, log: EventLog
  ) {
    self.sampleID = sampleID
    self.origin = origin
    self.measuresLatency = measuresLatency
    self.printsText = printsText
    self.log = log
    summary.sampleID = sampleID
  }

  func record(_ result: SpeechTranscriber.Result, receivedAt received: ContinuousClock.Instant)
    async
  {
    let text = String(result.text.characters)
    let audioStart = result.range.start.seconds
    let audioEnd = result.range.end.seconds
    let wallTime = origin.value.map { toSeconds(received - $0) }
    let latency = measuresLatency ? wallTime.map { $0 - audioEnd } : nil
    let kind = result.isFinal ? "final" : "volatile"

    if summary.firstResultWallTime == nil { summary.firstResultWallTime = wallTime }
    if cancelCalled != nil { resultsAfterCancel += 1 }
    if result.isFinal {
      summary.finalCount += 1
      finalText += text
      lastFinalReceived = received
      if let latency { finalLatencies.append(latency) }
    } else {
      summary.volatileCount += 1
      if let latency { volatileLatencies.append(latency) }
    }

    if printsText {
      print(
        "\(fixed(wallTime))s  \(kind.padding(toLength: 8, withPad: " ", startingAt: 0))"
          + "  audio \(fixed(audioStart, digits: 2))-\(fixed(audioEnd, digits: 2))s"
          + "  lag \(fixed(latency))s  | \(text)"
      )
    }
    await log.write(
      ResultEvent(
        sampleID: sampleID, kind: kind, audioStart: audioStart, audioEnd: audioEnd,
        resultsFinalizationTime: result.resultsFinalizationTime.seconds, wallTime: wallTime,
        latency: latency, text: text))
  }

  func markCancel(_ instant: ContinuousClock.Instant) { cancelCalled = instant }

  func finish(_ update: (inout RunSummary) -> Void) -> RunSummary {
    summary.volatileLatency = LatencyStats(volatileLatencies)
    summary.finalLatency = LatencyStats(finalLatencies)
    update(&summary)
    return summary
  }
}

// MARK: - 実行

struct RunOutput {
  let summary: RunSummary
  let finalText: String
}

/// 1つの音声を SpeechAnalyzer に流し、暫定・確定の結果とメモリを記録する。
func transcribe(
  source: AudioSource, options: RunOptions, sampleID: String? = nil, log: EventLog
) async throws -> RunOutput {
  // status / install と同じく、対応ロケールへ解決してから使う
  guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.locale) else {
    throw ProbeError("\(options.locale.identifier) は SpeechTranscriber の対応ロケールではありません")
  }
  let transcriber = SpeechTranscriber(locale: locale, preset: options.preset.preset)
  let status = await AssetInventory.status(forModules: [transcriber])
  guard status == .installed else {
    throw ProbeError(
      "\(locale.identifier) の SpeechTranscriber のアセットが使えません（状態: \(describe(status))）。"
        + "status で対応を確認し、install でダウンロードしてください")
  }
  guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
  else { throw ProbeError("SpeechAnalyzer が受け付ける音声形式を取得できません") }

  let runStart = ContinuousClock.now
  let baseline = MemoryUsage.current()
  await log.write(
    RunStartEvent(
      sampleID: sampleID, source: source.label, requestedLocale: options.locale.identifier,
      locale: locale.identifier,
      preset: options.preset.rawValue,
      reportingOptions: describe(options.preset.preset.reportingOptions),
      pace: options.pace.rawValue, retention: options.retentionName,
      analyzerFormat: describe(format), machine: MachineInfo.current(),
      baselinePhysFootprintMB: baseline.map { megabytes($0.physFootprint) }))

  // メモリを一定間隔で記録する
  let interval = options.memoryInterval
  let sampler = Task<UInt64, Never> {
    var peak: UInt64 = 0
    while !Task.isCancelled {
      if let usage = MemoryUsage.current() {
        peak = max(peak, usage.physFootprint)
        await log.write(
          MemoryEvent(
            sampleID: sampleID, elapsed: toSeconds(ContinuousClock.now - runStart),
            physFootprintMB: megabytes(usage.physFootprint),
            lifetimeMaxPhysFootprintMB: megabytes(usage.lifetimeMaxPhysFootprint)))
      }
      try? await Task.sleep(for: .seconds(interval))
    }
    return peak
  }
  // 準備や開始で失敗しても、記録を止める（batch で次の発話に混ざらないように）
  defer { sampler.cancel() }

  // 比べるのはモデル保持だけにするため、優先度は常に同じ値を明示する
  let analyzerOptions = SpeechAnalyzer.Options(
    priority: .userInitiated, modelRetention: options.retention)
  let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
  let prepareStart = ContinuousClock.now
  try await analyzer.prepareToAnalyze(in: format)
  let prepareSeconds = toSeconds(ContinuousClock.now - prepareStart)

  let origin = AudioOrigin()
  let recorder = ResultRecorder(
    sampleID: sampleID, origin: origin, measuresLatency: options.pace == .realtime,
    printsText: options.printsText, log: log)
  let resultsTask = Task<ContinuousClock.Instant, any Error> {
    do {
      for try await result in transcriber.results {
        await recorder.record(result, receivedAt: .now)
      }
    } catch is CancellationError {
      // cancelAndFinishNow() 後に CancellationError で終わる場合も、正常な終了として扱う
    }
    return .now
  }

  let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
  do {
    try await analyzer.start(inputSequence: stream)
  } catch {
    // 結果の待ち受けと解析器を残さない（batch で次の発話に影響しないように）
    continuation.finish()
    await analyzer.cancelAndFinishNow()
    resultsTask.cancel()
    throw error
  }

  let feedTask = Task {
    switch source {
    case .file(let url):
      try await feedFile(
        url: url, pace: options.pace, format: format, origin: origin, continuation: continuation)
    case .microphone(let seconds):
      try await feedMicrophone(
        seconds: seconds, format: format, origin: origin, continuation: continuation)
    }
  }

  // --cancel-after: 入力の途中で cancelAndFinishNow() を呼ぶ。
  // マイクの起動やファイルの準備の時間を含めないよう、最初の音声が入った時刻（音声時刻 0）から数える
  let cancelTask = options.cancelAfter.map { after in
    Task<(called: ContinuousClock.Instant, returned: ContinuousClock.Instant)?, Never> {
      do {
        var inputStart = origin.value
        while inputStart == nil {
          try await Task.sleep(for: .milliseconds(5))
          inputStart = origin.value
        }
        guard let inputStart else { return nil }
        try await Task.sleep(until: inputStart + .seconds(after), clock: .continuous)
      } catch {
        return nil
      }
      let called = ContinuousClock.now
      await recorder.markCancel(called)
      feedTask.cancel()
      await analyzer.cancelAndFinishNow()
      return (called, ContinuousClock.now)
    }
  }

  var runError: (any Error)?
  var audioSeconds = 0.0
  do {
    audioSeconds = try await feedTask.value
  } catch {
    runError = error
  }
  continuation.finish()
  let inputEnd = ContinuousClock.now

  cancelTask?.cancel()
  let cancelled = await cancelTask?.value ?? nil
  if options.cancelAfter != nil, cancelled == nil {
    printError("--cancel-after の前に入力が終わったため、キャンセルは計測していません（音声を長くしてください）")
  }
  var finishReturned: ContinuousClock.Instant?
  if cancelled == nil {
    do {
      if runError == nil {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        finishReturned = .now
      } else {
        await analyzer.cancelAndFinishNow()
      }
    } catch {
      runError = runError ?? error
    }
  }

  var resultsEnded: ContinuousClock.Instant?
  do {
    resultsEnded = try await resultsTask.value
  } catch {
    runError = runError ?? error
  }
  sampler.cancel()
  let peak = await sampler.value
  let lifetimeMax = MemoryUsage.current()?.lifetimeMaxPhysFootprint
  let lastFinal = await recorder.lastFinalReceived
  let afterCancel = await recorder.resultsAfterCancel
  let originInstant = origin.value

  let summary = await recorder.finish { summary in
    summary.audioSeconds = audioSeconds
    summary.prepareSeconds = prepareSeconds
    // pace=fast では入力が一瞬で終わるため、入力終了からの時間は意味を持たない
    if cancelled == nil, options.pace == .realtime {
      summary.stopToLastFinalSeconds = lastFinal.map { max(0, toSeconds($0 - inputEnd)) }
      summary.stopToFinishSeconds = finishReturned.map { toSeconds($0 - inputEnd) }
    }
    // 終点は結果のストリームの終了（すべての結果を受け取った時刻）。finish の戻りより後になりうるため
    if let originInstant, finishReturned != nil, let resultsEnded, runError == nil, audioSeconds > 0
    {
      summary.realTimeFactor = toSeconds(resultsEnded - originInstant) / audioSeconds
    }
    if let cancelled {
      summary.cancel = CancelSummary(
        calledAt: originInstant.map { toSeconds(cancelled.called - $0) } ?? 0,
        returnSeconds: toSeconds(cancelled.returned - cancelled.called),
        resultsEndSeconds: resultsEnded.map { toSeconds($0 - cancelled.called) },
        resultsAfterCancel: afterCancel)
    }
    summary.baselinePhysFootprintMB = baseline.map { megabytes($0.physFootprint) }
    summary.peakSampledPhysFootprintMB = peak > 0 ? megabytes(peak) : nil
    summary.lifetimeMaxPhysFootprintMB = lifetimeMax.map(megabytes)
    // エラーの本文に発話が入ることはないが、念のため型と説明だけを記録する
    summary.error = runError.map { "\(type(of: $0)): \($0.localizedDescription)" }
  }
  await log.write(summary)
  let finalText = await recorder.finalText
  return RunOutput(summary: summary, finalText: finalText)
}

// MARK: - 表示

func describe(_ status: AssetInventory.Status) -> String {
  switch status {
  case .unsupported: "unsupported（非対応）"
  case .supported: "supported（対応・未インストール）"
  case .downloading: "downloading（ダウンロード中）"
  case .installed: "installed（インストール済み）"
  @unknown default: "unknown"
  }
}

func describe(_ options: Set<SpeechTranscriber.ReportingOption>) -> [String] {
  options.map { option in
    switch option {
    case .volatileResults: "volatileResults"
    case .alternativeTranscriptions: "alternativeTranscriptions"
    case .fastResults: "fastResults"
    @unknown default: "unknown"
    }
  }.sorted()
}

func describe(_ format: AVAudioFormat) -> String {
  let kind =
    switch format.commonFormat {
    case .pcmFormatInt16: "Int16"
    case .pcmFormatInt32: "Int32"
    case .pcmFormatFloat32: "Float32"
    case .pcmFormatFloat64: "Float64"
    default: "other"
    }
  return "\(Int(format.sampleRate))Hz \(format.channelCount)ch \(kind)"
    + (format.isInterleaved ? " interleaved" : "")
}

func printSummary(_ summary: RunSummary) {
  func stats(_ value: LatencyStats?) -> String {
    guard let value else { return "-" }
    return
      "n=\(value.count) p50=\(fixed(value.p50))s p95=\(fixed(value.p95))s max=\(fixed(value.max))s"
  }
  print(
    """
    --- summary\(summary.sampleID.map { " [\($0)]" } ?? "")
    音声の長さ            : \(fixed(summary.audioSeconds, digits: 2))s
    prepareToAnalyze      : \(fixed(summary.prepareSeconds))s
    結果の数              : volatile \(summary.volatileCount) / final \(summary.finalCount)
    最初の結果（音声0から）: \(fixed(summary.firstResultWallTime))s
    遅延 volatile         : \(stats(summary.volatileLatency))
    遅延 final            : \(stats(summary.finalLatency))
    入力終了→最後の確定    : \(fixed(summary.stopToLastFinalSeconds))s
    入力終了→finish 完了   : \(fixed(summary.stopToFinishSeconds))s
    実時間比              : \(fixed(summary.realTimeFactor))
    phys_footprint        : 開始時 \(fixed(summary.baselinePhysFootprintMB, digits: 1))MB / 計測中の最大 \(fixed(summary.peakSampledPhysFootprintMB, digits: 1))MB / プロセス生涯の最大 \(fixed(summary.lifetimeMaxPhysFootprintMB, digits: 1))MB
    """)
  if let cancel = summary.cancel {
    print(
      "キャンセル            : \(fixed(cancel.calledAt))s で呼び出し → 戻り \(fixed(cancel.returnSeconds))s"
        + " / 結果の終了 \(fixed(cancel.resultsEndSeconds))s / 呼び出し後の結果 \(cancel.resultsAfterCancel) 件")
  }
  if let error = summary.error {
    print("エラー                : \(error)")
  }
}
