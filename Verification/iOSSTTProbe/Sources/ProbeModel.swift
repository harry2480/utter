import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// 画面の状態と、認識の実行・計測・書き出しをまとめる。
@MainActor
@Observable
final class ProbeModel {
  enum Phase: Equatable {
    case idle
    case preparing
    case recording
    case finishing
    case recognizingFiles(current: Int, total: Int)
  }

  static let targetLocale = Locale(identifier: "ja_JP")

  // MARK: 設定

  var engineKind: EngineKind = .speechTranscriber
  var progressiveResults = true
  var retention: ModelRetentionOption = .whileInUse
  /// ファイル認識を繰り返す回数（発熱・メモリの負荷をかけるため）
  var fileRepeatCount = 1

  // MARK: 状態

  private(set) var phase: Phase = .idle
  private(set) var availability: EngineAvailability?
  private(set) var downloadProgress: Progress?
  private(set) var speechAuthorization: SFSpeechRecognizerAuthorizationStatus =
    SFSpeechRecognizer.authorizationStatus()
  private(set) var message: String?
  /// 認識中の確定済みテキストと暫定テキスト（画面表示のみ。ログには出さない）
  private(set) var liveFinalText = ""
  private(set) var liveVolatileText = ""

  // MARK: 評価サンプルと計測

  /// 評価サンプル（取り込んだ評価セット＋このアプリで作ったもの）
  var samples: [EvaluationRecord] = []
  /// マイク録音の対象。nil なら新しいサンプルを作る
  var selectedSampleID: String?
  var newSampleCategory: EvaluationCategoryOption = .japanese
  private(set) var runs: [RunMetrics] = []
  private(set) var exportedFiles: [URL] = []

  let monitor = ResourceMonitor()

  @ObservationIgnored private let microphone = MicrophoneInput()
  @ObservationIgnored private var activeRun: SpeechAnalyzerRun?
  @ObservationIgnored private var activeMetrics: RunMetrics?
  @ObservationIgnored private var activeSampleStartIndex = 0
  @ObservationIgnored private var tapInstant: ContinuousClock.Instant?
  @ObservationIgnored private var inputStartInstant: ContinuousClock.Instant?
  @ObservationIgnored private var nextRunID = 1
  @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

  private let clock = ContinuousClock()

  var isBusy: Bool { phase != .idle }

  var configuration: EngineConfiguration {
    EngineConfiguration(
      kind: engineKind,
      locale: availability?.supportedLocale ?? Self.targetLocale,
      progressiveResults: progressiveResults,
      retention: retention
    )
  }

  func onAppear() async {
    monitor.start()
    observeInterruptions()
    await refreshAvailability()
  }

  // MARK: 対応状況・アセット

  func refreshAvailability() async {
    var base = configuration
    base.locale = Self.targetLocale
    availability = await SpeechEngineInfo.availability(for: base)
    speechAuthorization = SFSpeechRecognizer.authorizationStatus()
  }

  func downloadAssets() async {
    guard availability?.supportedLocale != nil else {
      message = ProbeError.localeUnsupported.localizedDescription
      return
    }
    do {
      if let request = try await SpeechEngineInfo.installationRequest(for: configuration) {
        downloadProgress = request.progress
        try await request.downloadAndInstall()
        message = "アセットのダウンロードが完了しました"
      } else {
        message = "ダウンロードは不要です（導入済み）"
      }
    } catch {
      message = "ダウンロードに失敗しました: \(Self.errorSummary(error))"
    }
    downloadProgress = nil
    await refreshAvailability()
  }

  func releaseReservedLocales() async {
    await SpeechEngineInfo.releaseReservedLocales()
    message = "ロケールの予約を解除しました（アセットの削除時期は OS が決めます）"
    await refreshAvailability()
  }

  func endModelRetention() async {
    await SpeechEngineInfo.endModelRetention()
    message = "保持中のモデルを解放しました"
  }

  // MARK: マイク録音

  func startMicrophoneRun() async {
    guard !isBusy else { return }
    guard availability?.supportedLocale != nil else {
      message = ProbeError.localeUnsupported.localizedDescription
      return
    }
    phase = .preparing
    message = nil
    let tap = clock.now
    tapInstant = tap

    guard await AVAudioApplication.requestRecordPermission() else {
      message = ProbeError.microphoneDenied.localizedDescription
      phase = .idle
      return
    }
    await requestSpeechAuthorizationIfNeeded()
    let sampleID = resolveMicrophoneSampleID()
    beginRun(sampleID: sampleID, source: "microphone")

    do {
      let sessionStart = clock.now
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .default)
      try session.setActive(true)
      activeMetrics?.sessionActivationMilliseconds = milliseconds(clock.now - sessionStart)

      let run = SpeechAnalyzerRun(configuration: configuration)
      activeRun = run
      let prepareStart = clock.now
      let format = try await run.prepare()
      activeMetrics?.analyzerPrepareMilliseconds = milliseconds(clock.now - prepareStart)

      let continuation = try await run.startStreaming { [weak self] text, isFinal in
        self?.handleResult(text: text, isFinal: isFinal)
      }
      try microphone.start(analyzerFormat: format, continuation: continuation)
      let inputStart = clock.now
      inputStartInstant = inputStart
      activeMetrics?.startToInputMilliseconds = milliseconds(inputStart - tap)
      UIApplication.shared.isIdleTimerDisabled = true
      phase = .recording
    } catch {
      microphone.stop()
      await activeRun?.cancel()
      deactivateAudioSession()
      finishRun(error: error)
    }
  }

  func stopMicrophoneRun(interrupted: Bool = false) async {
    guard phase == .recording, let run = activeRun else { return }
    phase = .finishing
    let stop = clock.now
    if let inputStartInstant {
      activeMetrics?.audioDurationSeconds = milliseconds(stop - inputStartInstant) / 1000
    }
    activeMetrics?.interrupted = interrupted
    microphone.stop()
    do {
      try await run.finishStreaming()
      activeMetrics?.stopToFinishMilliseconds = milliseconds(clock.now - stop)
      deactivateAudioSession()
      finishRun(error: nil)
    } catch {
      deactivateAudioSession()
      finishRun(error: error)
    }
  }

  // MARK: ファイル認識

  func recognizeFiles(_ urls: [URL]) async {
    guard !isBusy, !urls.isEmpty else { return }
    guard availability?.supportedLocale != nil else {
      message = ProbeError.localeUnsupported.localizedDescription
      return
    }
    message = nil
    await requestSpeechAuthorizationIfNeeded()
    UIApplication.shared.isIdleTimerDisabled = true
    let total = urls.count * fileRepeatCount
    var index = 0
    for _ in 0..<fileRepeatCount {
      for url in urls {
        index += 1
        phase = .recognizingFiles(current: index, total: total)
        await recognize(file: url)
      }
    }
    UIApplication.shared.isIdleTimerDisabled = false
    phase = .idle
  }

  private func recognize(file url: URL) async {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    let sampleID = resolveFileSampleID(for: url)
    beginRun(sampleID: sampleID, source: "file")
    do {
      let file = try AVAudioFile(forReading: url)
      activeMetrics?.audioDurationSeconds = Double(file.length) / file.fileFormat.sampleRate

      let run = SpeechAnalyzerRun(configuration: configuration)
      activeRun = run
      let prepareStart = clock.now
      _ = try await run.prepare()
      activeMetrics?.analyzerPrepareMilliseconds = milliseconds(clock.now - prepareStart)

      let start = clock.now
      inputStartInstant = start
      try await run.recognize(file: file) { [weak self] text, isFinal in
        self?.handleResult(text: text, isFinal: isFinal)
      }
      let processing = milliseconds(clock.now - start)
      activeMetrics?.processingMilliseconds = processing
      if let duration = activeMetrics?.audioDurationSeconds, duration > 0 {
        activeMetrics?.realTimeFactor = processing / 1000 / duration
      }
      finishRun(error: nil)
    } catch {
      await activeRun?.cancel()
      finishRun(error: error)
    }
  }

  // MARK: 実行の記録

  private func beginRun(sampleID: String, source: String) {
    liveFinalText = ""
    liveVolatileText = ""
    inputStartInstant = nil
    let runID = nextRunID
    nextRunID += 1
    let before = monitor.record()
    monitor.activeRunID = runID
    activeSampleStartIndex = monitor.samples.count
    activeMetrics = RunMetrics(
      id: runID,
      sampleID: sampleID,
      source: source,
      engine: engineKind.rawValue,
      progressiveResults: progressiveResults,
      modelRetention: retention.rawValue,
      locale: configuration.locale.identifier,
      startedAt: Date(),
      speechAuthorization: SFSpeechRecognizer.authorizationStatus().label,
      footprintBeforeMB: megabytes(before.footprintBytes),
      thermalStateStart: before.thermalState.label,
      batteryLevelStart: before.batteryLevel < 0 ? nil : before.batteryLevel,
      lowPowerModeStart: before.lowPowerMode
    )
  }

  private func handleResult(text: String, isFinal: Bool) {
    guard activeMetrics != nil else { return }
    let elapsed = inputStartInstant.map { milliseconds(clock.now - $0) }
    if isFinal {
      liveFinalText += text
      liveVolatileText = ""
      activeMetrics?.finalResultCount += 1
      if activeMetrics?.firstFinalResultMilliseconds == nil {
        activeMetrics?.firstFinalResultMilliseconds = elapsed
      }
    } else {
      liveVolatileText = text
      activeMetrics?.volatileResultCount += 1
      if activeMetrics?.firstVolatileResultMilliseconds == nil {
        activeMetrics?.firstVolatileResultMilliseconds = elapsed
      }
    }
  }

  private func finishRun(error: (any Error)?) {
    guard var metrics = activeMetrics else {
      phase = .idle
      return
    }
    let after = monitor.record()
    monitor.activeRunID = nil
    let during = monitor.samples[min(activeSampleStartIndex, monitor.samples.count)...]
    metrics.footprintPeakSampledMB = megabytes(during.compactMap(\.footprintBytes).max())
    metrics.footprintAfterMB = megabytes(after.footprintBytes)
    metrics.processPeakFootprintMB = megabytes(after.processPeakFootprintBytes)
    metrics.minAvailableMemoryMB = megabytes(during.map(\.availableBytes).min())
    metrics.thermalStateMax =
      during.map(\.thermalState).max(by: { $0.rawValue < $1.rawValue })?
      .label
    metrics.thermalStateEnd = after.thermalState.label
    metrics.batteryLevelEnd = after.batteryLevel < 0 ? nil : after.batteryLevel
    metrics.outputCharacterCount = liveFinalText.count
    if let error {
      metrics.error = Self.errorSummary(error)
      message = "認識に失敗しました: \(Self.errorSummary(error))"
    } else {
      updateSample(id: metrics.sampleID, sttOutput: liveFinalText)
    }
    runs.append(metrics)
    activeMetrics = nil
    activeRun = nil
    tapInstant = nil
    if case .recognizingFiles = phase {
      // 複数ファイルの途中。recognizeFiles が最後に idle へ戻す
    } else {
      UIApplication.shared.isIdleTimerDisabled = false
      phase = .idle
    }
    scheduleSettledMeasurement(runID: metrics.id)
  }

  /// 終了 5 秒後のメモリを記録する（処理後の負荷復帰, 6章）
  private func scheduleSettledMeasurement(runID: Int) {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard let self else { return }
      let sample = self.monitor.record()
      if let index = self.runs.firstIndex(where: { $0.id == runID }) {
        self.runs[index].footprintAfter5sMB = megabytes(sample.footprintBytes)
      }
    }
  }

  private func updateSample(id: String, sttOutput: String) {
    if let index = samples.firstIndex(where: { $0.id == id }) {
      samples[index].sttOutput = sttOutput
    }
  }

  private func resolveMicrophoneSampleID() -> String {
    if let selectedSampleID, samples.contains(where: { $0.id == selectedSampleID }) {
      return selectedSampleID
    }
    return makeSample(baseID: "mic")
  }

  /// ファイル名（拡張子なし）が評価セットの id と一致すれば、そのサンプルに結果を入れる
  private func resolveFileSampleID(for url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    if samples.contains(where: { $0.id == name }) {
      return name
    }
    return makeSample(baseID: name)
  }

  private func makeSample(baseID: String) -> String {
    var number = 1
    var id = String(format: "%@-%03d", baseID, number)
    while samples.contains(where: { $0.id == id }) {
      number += 1
      id = String(format: "%@-%03d", baseID, number)
    }
    samples.append(
      EvaluationRecord(id: id, category: newSampleCategory.rawValue, reference: "")
    )
    return id
  }

  private func requestSpeechAuthorizationIfNeeded() async {
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      speechAuthorization = await SpeechEngineInfo.requestSpeechAuthorization()
    }
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func observeInterruptions() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.stopMicrophoneRun(interrupted: true)
      }
    }
  }

  // MARK: 評価セットの取り込み

  func importSamples(from url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      let imported = try JSONDecoder().decode([EvaluationRecord].self, from: data)
      var merged = samples
      for record in imported {
        if let index = merged.firstIndex(where: { $0.id == record.id }) {
          merged[index] = record
        } else {
          merged.append(record)
        }
      }
      samples = merged
      message = "評価サンプルを \(imported.count) 件取り込みました"
    } catch {
      message = "評価セットを読めませんでした: \(Self.errorSummary(error))"
    }
  }

  func updateSample(_ record: EvaluationRecord) {
    if let index = samples.firstIndex(where: { $0.id == record.id }) {
      samples[index] = record
    }
  }

  // MARK: 書き出し

  /// 書き出し先。アプリの Documents 内のみ（外部送信しない）
  static var outputRoot: URL {
    URL.documentsDirectory.appending(path: "ProbeOutput", directoryHint: .isDirectory)
  }

  func export() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let directory = Self.outputRoot.appending(
      path: formatter.string(from: Date()), directoryHint: .isDirectory)
    let exportable = samples.filter { $0.exportProblem == nil }
    let skipped = samples.count - exportable.count
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601

      let samplesURL = directory.appending(path: "results.json")
      try encoder.encode(exportable).write(to: samplesURL, options: .completeFileProtection)

      let metrics = MetricsExport(
        device: DeviceSummary(
          modelIdentifier: DeviceInfo.modelIdentifier,
          systemVersion: UIDevice.current.systemVersion,
          physicalMemoryMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
          exportedAt: Date()
        ),
        runs: runs
      )
      let metricsURL = directory.appending(path: "metrics.json")
      try encoder.encode(metrics).write(to: metricsURL, options: .completeFileProtection)

      let timelineURL = directory.appending(path: "timeline.csv")
      try Data(monitor.timelineCSV().utf8).write(to: timelineURL, options: .completeFileProtection)

      exportedFiles = [samplesURL, metricsURL, timelineURL]
      message =
        "書き出しました（評価サンプル \(exportable.count) 件"
        + (skipped > 0 ? "、正解が未入力などで除外 \(skipped) 件" : "") + "）"
    } catch {
      message = "書き出しに失敗しました: \(Self.errorSummary(error))"
    }
  }

  /// 書き出したファイルと、メモリ上の認識結果・計測値をすべて消す
  func deleteAllOutputs() {
    try? FileManager.default.removeItem(at: Self.outputRoot)
    exportedFiles = []
    samples = []
    runs = []
    selectedSampleID = nil
    liveFinalText = ""
    liveVolatileText = ""
    monitor.reset()
    message = "書き出したファイルと認識結果を削除しました"
  }

  /// エラーの種類だけを返す（発話本文やファイルパスを含めない）
  static func errorSummary(_ error: any Error) -> String {
    if let probeError = error as? ProbeError {
      return probeError.localizedDescription
    }
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
  }
}
