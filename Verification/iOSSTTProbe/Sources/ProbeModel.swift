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
  /// ファイルごとに 5 秒待ち、終了 5 秒後のメモリを測ってから次へ進む。
  /// オフにすると連続負荷はかけられるが、終了 5 秒後のメモリは記録しない（次の実行と重なるため）
  var waitAfterEachFile = true

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
  @ObservationIgnored private var tapHostTime: UInt64 = 0
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
    await runAutoInputIfPresent()
  }

  // MARK: 自動実行（Mac から入れた音声をまとめて認識する）

  static var autoInputRoot: URL {
    URL.documentsDirectory.appending(path: "AutoInput", directoryHint: .isDirectory)
  }

  /// Mac から `devicectl device copy to` で Documents/AutoInput/ に置いた評価セットと音声を、起動時に認識して書き出す。
  ///
  /// - `set.json`: 評価セット（`importSamples` と同じ形）。`autorun.json`: `{"repeat": 回数, "wait": 真偽}`（省略可）
  /// - 音声は `<サンプルの id>.wav`。評価セットにある id の音声だけを名前順に認識する
  /// - すべての実行がエラーなく終わったときだけ `ProbeOutput/auto-done.txt` を、そうでなければ `auto-failed.txt` に理由を置く
  /// - 評価セットを読めない・対象の音声がないときは、入力を消さずに残して `auto-failed.txt` を置く（直して再実行できるように）
  /// - 認識を始めたら、成否にかかわらず最後に AutoInput を音声ごと消す（音声を端末に残さない）
  private func runAutoInputIfPresent() async {
    let input = Self.autoInputRoot
    let setURL = input.appending(path: "set.json")
    guard FileManager.default.fileExists(atPath: setURL.path) else { return }
    try? FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
    for name in ["auto-done.txt", "auto-failed.txt"] {
      try? FileManager.default.removeItem(at: Self.outputRoot.appending(path: name))
    }
    func fail(_ reason: String) {
      message = reason
      try? Data(reason.utf8).write(to: Self.outputRoot.appending(path: "auto-failed.txt"))
    }

    struct AutoRun: Decodable {
      var repeatCount: Int?
      var wait: Bool?
      enum CodingKeys: String, CodingKey {
        case repeatCount = "repeat"
        case wait
      }
    }
    let autorunURL = input.appending(path: "autorun.json")
    let autorun = (try? Data(contentsOf: autorunURL)).flatMap {
      try? JSONDecoder().decode(AutoRun.self, from: $0)
    }
    let set: [EvaluationRecord]
    do {
      set = try JSONDecoder().decode([EvaluationRecord].self, from: Data(contentsOf: setURL))
    } catch {
      fail("評価セットを読めませんでした: \(Self.errorSummary(error))")
      return
    }
    let ids = Set(set.map(\.id))
    let files =
      ((try? FileManager.default.contentsOfDirectory(
        at: input, includingPropertiesForKeys: nil)) ?? [])
      .filter {
        $0.pathExtension == "wav" && ids.contains($0.deletingPathExtension().lastPathComponent)
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else {
      fail("評価セットの id と同じ名前の音声（<id>.wav）がありません")
      return
    }

    // ここから先は入力を消費する。二重に実行しないよう設定を先に取り除き、最後に音声ごと消す
    defer { try? FileManager.default.removeItem(at: input) }
    try? FileManager.default.removeItem(at: setURL)
    try? FileManager.default.removeItem(at: autorunURL)
    mergeSamples(set)
    fileRepeatCount = max(1, autorun?.repeatCount ?? 1)
    waitAfterEachFile = autorun?.wait ?? true

    // 導入済みなら何もしない（installationRequest が nil を返す）
    await downloadAssets()
    guard await SpeechEngineInfo.assetStatus(for: configuration) == "installed" else {
      fail("アセットを導入できませんでした: \(message ?? "-")")
      return
    }

    let firstRunIndex = runs.count
    await recognizeFiles(files)
    let newRuns = runs[firstRunIndex...]
    let expected = files.count * fileRepeatCount
    let failed = newRuns.filter { $0.error != nil || $0.interrupted }.count
    export()
    if newRuns.count == expected, failed == 0, !exportedFiles.isEmpty {
      try? Data((message ?? "").utf8).write(to: Self.outputRoot.appending(path: "auto-done.txt"))
    } else {
      fail("実行 \(newRuns.count) / \(expected) 回、失敗 \(failed) 回（\(message ?? "-")）")
    }
  }

  // MARK: 対応状況・アセット

  /// 今の設定で実行できない理由。実行できるなら nil
  private var unavailableReason: ProbeError? {
    if availability?.deviceSupported == false { return .deviceUnsupported }
    if availability?.supportedLocale == nil { return .localeUnsupported }
    return nil
  }

  func refreshAvailability() async {
    var base = configuration
    base.locale = Self.targetLocale
    availability = await SpeechEngineInfo.availability(for: base)
    speechAuthorization = SFSpeechRecognizer.authorizationStatus()
  }

  func downloadAssets() async {
    if let problem = unavailableReason {
      message = problem.localizedDescription
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
    if let problem = unavailableReason {
      message = problem.localizedDescription
      return
    }
    phase = .preparing
    message = nil

    guard await AVAudioApplication.requestRecordPermission() else {
      message = ProbeError.microphoneDenied.localizedDescription
      phase = .idle
      return
    }
    await requestSpeechAuthorizationIfNeeded()
    let assetStatus = await SpeechEngineInfo.assetStatus(for: configuration)
    // 初回の許可ダイアログの時間を録音開始遅延に含めないよう、許可の確認後から測る
    let tap = clock.now
    tapInstant = tap
    tapHostTime = mach_absolute_time()
    let sampleID = resolveMicrophoneSampleID()
    beginRun(sampleID: sampleID, source: "microphone", assetStatus: assetStatus)

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
      let runID = activeMetrics?.id
      try microphone.start(
        analyzerFormat: format,
        continuation: continuation,
        tapHostTime: tapHostTime,
        onFirstBuffer: { [weak self] milliseconds in
          Task { @MainActor in self?.recordFirstBuffer(milliseconds, runID: runID) }
        },
        onConfigurationChange: { [weak self] in
          Task { @MainActor in
            await self?.stopMicrophoneRun(interruption: "engineConfigurationChange")
          }
        }
      )
      let inputStart = clock.now
      inputStartInstant = inputStart
      activeMetrics?.startToEngineStartedMilliseconds = milliseconds(inputStart - tap)
      UIApplication.shared.isIdleTimerDisabled = true
      phase = .recording
    } catch {
      microphone.stop()
      await activeRun?.cancel()
      deactivateAudioSession()
      finishRun(error: error)
    }
  }

  /// - Parameter interruption: 割り込みで止めた場合の理由。nil ならユーザーの停止
  func stopMicrophoneRun(interruption: String? = nil) async {
    guard phase == .recording, let run = activeRun else { return }
    phase = .finishing
    let stop = clock.now
    if let inputStartInstant {
      activeMetrics?.audioDurationSeconds = milliseconds(stop - inputStartInstant) / 1000
    }
    activeMetrics?.interrupted = interruption != nil
    activeMetrics?.interruptionReason = interruption
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
    if let problem = unavailableReason {
      message = problem.localizedDescription
      return
    }
    message = nil
    await requestSpeechAuthorizationIfNeeded()
    UIApplication.shared.isIdleTimerDisabled = true
    // 繰り返しで新しいサンプルが増えないよう、URL ごとの id を先に決めて使い回す
    let sampleIDs = urls.map { resolveFileSampleID(for: $0) }
    let total = urls.count * fileRepeatCount
    var index = 0
    for _ in 0..<fileRepeatCount {
      for (url, sampleID) in zip(urls, sampleIDs) {
        index += 1
        phase = .recognizingFiles(current: index, total: total)
        await recognize(file: url, sampleID: sampleID)
        if waitAfterEachFile, let runID = runs.last?.id {
          try? await Task.sleep(for: .seconds(5))
          recordSettledFootprint(runID: runID)
        }
      }
    }
    UIApplication.shared.isIdleTimerDisabled = false
    phase = .idle
  }

  private func recognize(file url: URL, sampleID: String) async {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    let assetStatus = await SpeechEngineInfo.assetStatus(for: configuration)
    beginRun(sampleID: sampleID, source: "file", assetStatus: assetStatus)
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

  private func beginRun(sampleID: String, source: String, assetStatus: String?) {
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
      assetStatusAtStart: assetStatus,
      footprintBeforeMB: megabytes(before.footprintBytes),
      thermalStateStart: before.thermalState.label,
      batteryLevelStart: before.batteryLevel < 0 ? nil : before.batteryLevel,
      lowPowerModeStart: before.lowPowerMode
    )
  }

  private func recordFirstBuffer(_ value: Double, runID: Int?) {
    guard let runID, activeMetrics?.id == runID,
      activeMetrics?.startToFirstBufferMilliseconds == nil
    else { return }
    activeMetrics?.startToFirstBufferMilliseconds = value
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
    } else if metrics.interrupted {
      // 途中までのテキストで評価結果（既存の正常な結果を含む）を上書きしない
      message = "割り込みで録音が止まったため、評価サンプルには結果を入れませんでした"
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
    autosaveMetrics()
    if metrics.source == "microphone" {
      scheduleSettledMeasurement(runID: metrics.id)
    }
  }

  /// 終了 5 秒後のメモリを記録する（処理後の負荷復帰, 6章）。
  /// その時点で次の実行が始まっていれば、その実行の値になるため記録しない
  private func scheduleSettledMeasurement(runID: Int) {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      self?.recordSettledFootprint(runID: runID)
    }
  }

  private func recordSettledFootprint(runID: Int) {
    guard activeMetrics == nil,
      let index = runs.firstIndex(where: { $0.id == runID })
    else { return }
    runs[index].footprintAfter5sMB = megabytes(monitor.record().footprintBytes)
    autosaveMetrics()
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
    ) { [weak self] notification in
      // 割り込みの開始（.began）のときだけ止める。終了（.ended）は無視する
      guard
        let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: rawValue) == .began
      else { return }
      Task { @MainActor in
        await self?.stopMicrophoneRun(interruption: "audioSessionInterruption")
      }
    }
  }

  // MARK: 評価セットの取り込み

  /// 読み込み済みの評価サンプルを、取り込みと同じ規則（同じ id は置き換え）で加える
  private func mergeSamples(_ imported: [EvaluationRecord]) {
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
  }

  func importSamples(from url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      mergeSamples(try JSONDecoder().decode([EvaluationRecord].self, from: data))
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

  /// 計測値（発話本文なし）を実行ごとに自動保存する。jetsam などで強制終了しても、それまでの値が残る
  private func autosaveMetrics() {
    do {
      try FileManager.default.createDirectory(
        at: Self.outputRoot, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(makeMetricsExport()).write(
        to: Self.outputRoot.appending(path: "autosave-metrics.json"),
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      message = "計測値の自動保存に失敗しました: \(Self.errorSummary(error))"
    }
  }

  private func makeMetricsExport() -> MetricsExport {
    MetricsExport(
      device: DeviceSummary(
        modelIdentifier: DeviceInfo.modelIdentifier,
        systemVersion: UIDevice.current.systemVersion,
        physicalMemoryMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
        exportedAt: Date()
      ),
      runs: runs
    )
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

      let metrics = makeMetricsExport()
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
    // 自動実行で置かれたまま残った音声も消す（認識を始める前に止まった場合など）
    try? FileManager.default.removeItem(at: Self.autoInputRoot)
    do {
      try FileManager.default.removeItem(at: Self.outputRoot)
    } catch CocoaError.fileNoSuchFile {
      // まだ何も書き出していない
    } catch {
      // ファイルが残ったまま「削除した」と表示しないよう、メモリ上の値も残して知らせる
      message = "削除に失敗しました: \(Self.errorSummary(error))"
      return
    }
    exportedFiles = []
    samples = []
    runs = []
    selectedSampleID = nil
    liveFinalText = ""
    liveVolatileText = ""
    monitor.reset()
    message = "書き出したファイルと認識結果・計測値を削除しました（資源の記録はここから記録し直します）"
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
