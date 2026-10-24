import ArgumentParser
import Foundation
import UtterEvaluation
import WhisperKit

/// Phase 0 検証（#49）: WhisperKit のモデル選定・メモリ・安定性を計測する使い捨てのコマンド。
@main
struct WhisperKitProbe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "whisperkit-probe",
    abstract: "WhisperKit のモデル取得・ロード・推論の時間とメモリを計測する（#49）",
    subcommands: [Fetch.self, Bench.self, Eval.self]
  )
}

/// モデルとトークナイザーを取得し、取得直後の初回ロードを計測する。通信するのはこのコマンドだけ。
struct Fetch: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "モデルを取得し、初回ロード時間を計測する（Hugging Face と通信する）")

  @OptionGroup var model: ModelOptions
  @OptionGroup var output: OutputOptions

  func run() async throws {
    let session = try Session(command: "fetch", model: model, output: output)
    defer { session.finish() }

    let progress = ProgressPrinter()
    let download = try await session.measureOrRecordFailure(phase: "download") {
      try await WhisperKit.download(
        variant: model.model,
        downloadBase: model.modelsDirURL,
        from: modelRepository,
        progressCallback: { progress.report($0.fractionCompleted) }
      )
    }
    guard canonicalPath(download.value) == canonicalPath(model.modelFolder) else {
      throw ProbeError.modelNameMismatch(
        requested: model.model, resolved: download.value.lastPathComponent)
    }
    let bytes = directorySize(download.value)
    session.record(
      SummaryRow(
        phase: "download", label: "model_bytes=\(bytes)", wallSeconds: download.wallSeconds,
        memory: download.memory))
    print(
      "取得: \(format(download.wallSeconds, digits: 1)) 秒 / \(megabytes(bytes)) MB → \(download.value.path)"
    )

    // 取得直後のロードが、この端末での初回ロード（Core ML のデバイス向け特化を含む）になる。
    // トークナイザーが手元になければこのロード中に取得するため、tokenizer_load_s に通信時間が入る。
    let kit = try await makeWhisperKit(model)
    try await loadModels(kit, session: session, phase: "load_first")
    await kit.unloadModels()
  }

  private func directorySize(_ url: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
    else { return 0 }
    var total: UInt64 = 0
    for case let file as URL in enumerator {
      guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
      else { continue }
      total += UInt64(values.totalFileAllocatedSize ?? 0)
    }
    return total
  }
}

/// 取得済みのモデルでロードと連続推論を行い、各回の時間とメモリを記録する（通信しない）。
struct Bench: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "ロード時間・推論時間・RTF・メモリを、連続 N 回の推論で計測する（通信しない）")

  @OptionGroup var model: ModelOptions
  @OptionGroup var output: OutputOptions

  @Option(help: "推論する音声ファイル（wav / m4a など。リポジトリに置かない）")
  var audio: String

  @Option(help: "連続して推論する回数")
  var runs: Int = 10

  @Option(help: "各回の推論の間に空ける秒数（0 なら連続）")
  var intervalS: Double = 0

  @Option(help: "全回の推論後に、何もせずメモリと熱状態を記録する秒数")
  var idleAfterS: Double = 10

  @Option(help: "30秒を超える音声の分割方法（none / vad）")
  var chunking: ChunkingChoice = .vad

  func validate() throws {
    guard runs >= 1 else { throw ValidationError("--runs は 1 以上にしてください") }
    guard intervalS >= 0, idleAfterS >= 0 else {
      throw ValidationError("--interval-s と --idle-after-s は 0 以上にしてください")
    }
  }

  func run() async throws {
    try await requireLocalModel(model)
    let session = try Session(command: "bench", model: model, output: output)
    defer { session.finish() }

    let samples = try loadAudio(path: audio)
    let audioSeconds = Double(samples.count) / Double(WhisperKit.sampleRate)
    print("音声: \(format(audioSeconds, digits: 2)) 秒")

    let kit = try await makeWhisperKit(model)
    try await loadModels(kit, session: session, phase: "load")

    let options = decodingOptions(chunking: chunking)
    var firstText: String?
    var successes = 0
    var walls: [Double] = []
    for index in 1...runs {
      if index > 1, intervalS > 0 {
        try await Task.sleep(for: .seconds(intervalS))
      }
      let measured = await session.measure(phase: "transcribe", index: index) {
        try await kit.transcribe(audioArray: samples, decodeOptions: options)
      }
      var row = SummaryRow(
        phase: "transcribe", index: index, wallSeconds: measured.wallSeconds,
        audioSeconds: audioSeconds, memory: measured.memory)
      switch measured.result {
      case .success(let results):
        let text = results.map(\.text).joined()
        if firstText == nil { firstText = text }
        row.outputCharacters = text.count
        row.sameAsFirst = text == firstText
        row.success = !text.isEmpty
        row.error = text.isEmpty ? "empty_output" : ""
      case .failure(let error):
        row.success = false
        row.error = errorLabel(error)
      }
      session.record(row)
      if row.success {
        successes += 1
        walls.append(measured.wallSeconds)
      }
      print(
        "推論 \(index)/\(runs): \(format(measured.wallSeconds, digits: 2)) 秒"
          + " RTF \(format(measured.wallSeconds / audioSeconds, digits: 3))"
          + " / ピーク \(megabytes(measured.memory.peak)) MB / \(thermalStateLabel())"
          + (row.success ? "" : " / 失敗: \(row.error)"))
    }

    if idleAfterS > 0 {
      try await session.idle(phase: "idle_after_runs", seconds: idleAfterS)
    }
    let unload = await session.measure(phase: "unload") {
      await kit.unloadModels()
      // 解放が反映されるまで少し待ってから値を読む
      try await Task.sleep(for: .seconds(2))
    }
    session.record(
      SummaryRow(phase: "unload", wallSeconds: unload.wallSeconds, memory: unload.memory))

    let sorted = walls.sorted()
    print("成功: \(successes)/\(runs)")
    if let median = median(of: sorted), let worst = sorted.last {
      print(
        "推論時間: 中央値 \(format(median, digits: 2)) 秒 / 最大 \(format(worst, digits: 2)) 秒"
          + "（RTF 中央値 \(format(median / audioSeconds, digits: 3))）")
    }
    if let footprint = FootprintReading.read() {
      print(
        "プロセス開始からのピーク: \(megabytes(footprint.lifetimeMax)) MB / アンロード後: \(megabytes(footprint.current)) MB"
      )
    }
  }
}

/// 評価セット（EvaluationSample の JSON）の各発話を推論し、sttOutput を埋めた JSON を書き出す（通信しない）。
struct Eval: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "評価セットの音声を推論し、utter-eval が読める JSON に sttOutput を書き出す（通信しない）")

  @OptionGroup var model: ModelOptions
  @OptionGroup var output: OutputOptions

  @Option(name: .customLong("set"), help: "評価セットの JSON（EvaluationSample の配列。docs/精度評価.md）")
  var evalSet: String

  @Option(help: "音声のディレクトリ。発話ごとに <id>.wav などを置く（既定: eval/audio）")
  var audioDir: String = "eval/audio"

  @Option(help: "書き出す JSON のパス（既定: 出力先ディレクトリの samples.json）")
  var outputJSON: String?

  @Option(help: "30秒を超える音声の分割方法（none / vad）")
  var chunking: ChunkingChoice = .vad

  static let audioExtensions = ["wav", "m4a", "caf", "aiff", "aif", "mp3", "flac"]

  func run() async throws {
    try await requireLocalModel(model)
    let input = try JSONDecoder().decode(
      [EvaluationSample].self, from: Data(contentsOf: URL(fileURLWithPath: evalSet)))
    try EvaluationSample.validate(input)

    let session = try Session(command: "eval", model: model, output: output)
    defer { session.finish() }

    let kit = try await makeWhisperKit(model)
    try await loadModels(kit, session: session, phase: "load")

    let options = decodingOptions(chunking: chunking)
    var results: [EvaluationSample] = []
    var missing = 0
    var failed = 0
    for (offset, sample) in input.enumerated() {
      let index = offset + 1
      guard let audioURL = audioFile(for: sample.id) else {
        missing += 1
        results.append(sttResult(sample, output: nil))
        session.record(
          SummaryRow(
            phase: "eval", index: index, label: sample.id, success: false, error: "audio_not_found")
        )
        continue
      }
      let measured = await session.measure(phase: "eval", index: index) {
        let samples = try loadAudio(path: audioURL.path)
        let transcription = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return (samples.count, transcription.map(\.text).joined())
      }
      var row = SummaryRow(
        phase: "eval", index: index, label: sample.id, wallSeconds: measured.wallSeconds,
        memory: measured.memory)
      switch measured.result {
      case .success(let (count, text)):
        row.audioSeconds = Double(count) / Double(WhisperKit.sampleRate)
        row.outputCharacters = text.count
        if text.isEmpty {
          // 空の出力を sttOutput にすると utter-eval が認識済みとして数えるため、失敗として扱う
          failed += 1
          row.success = false
          row.error = "empty_output"
          results.append(sttResult(sample, output: nil))
        } else {
          results.append(sttResult(sample, output: text))
        }
      case .failure(let error):
        failed += 1
        row.success = false
        row.error = errorLabel(error)
        results.append(sttResult(sample, output: nil))
      }
      session.record(row)
      print("\(index)/\(input.count) \(sample.id): \(row.success ? "完了" : "失敗 \(row.error)")")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let destination =
      outputJSON.map { URL(fileURLWithPath: $0) } ?? session.outDir.appending(path: "samples.json")
    try encoder.encode(results).write(to: destination)
    print("書き出し: \(destination.path)（音声なし \(missing) 件 / 失敗 \(failed) 件は sttOutput なし）")
    print("集計: swift run --package-path Packages/UtterEvaluation utter-eval \(destination.path)")
  }

  /// 発話 ID に対応する音声ファイルを探す。パス区切りを含む ID は扱わない。
  private func audioFile(for id: String) -> URL? {
    guard !id.contains("/"), !id.hasPrefix(".") else { return nil }
    let directory = URL(fileURLWithPath: audioDir, isDirectory: true)
    return Self.audioExtensions.lazy
      .map { directory.appending(path: "\(id).\($0)") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// STT 単体の結果だけを持つ発話にする。整形結果と意味改変の判定は別の STT のものになるため引き継がない。
  private func sttResult(_ sample: EvaluationSample, output: String?) -> EvaluationSample {
    EvaluationSample(
      id: sample.id, category: sample.category, reference: sample.reference, terms: sample.terms,
      sttOutput: output)
  }
}

/// シンボリックリンク（/tmp → /private/tmp など）と末尾の / の違いを除いたパス。
func canonicalPath(_ url: URL) -> String {
  let path = url.resolvingSymlinksInPath().standardizedFileURL.path
  return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}

/// 計測を通信なしで行うため、モデルとトークナイザーが手元にあることを確かめる。
func requireLocalModel(_ options: ModelOptions) async throws {
  let folder = options.modelFolder
  guard FileManager.default.fileExists(atPath: folder.appending(path: "config.json").path) else {
    throw ProbeError.modelNotFound(folder.path)
  }
  guard let repository = tokenizerRepository(modelFolder: folder) else {
    throw ProbeError.tokenizerUnknown(folder.path)
  }
  let hubApi = HubApiWrapper(downloadBase: options.modelsDirURL)
  let tokenizerFolder = hubApi.localRepoLocation(HubApiWrapper.Repo(id: repository))
  // WhisperKit はローカルのトークナイザーを読めないと Hugging Face から取得し直すため、
  // 欠けた・壊れた・中身の合わないファイルはロード前に止めて、計測中に通信しないようにする。
  // tokenizer_config.json が無くてもローカル読み込みは失敗する
  for name in ["tokenizer.json", "tokenizer_config.json"] {
    let file = tokenizerFolder.appending(path: name)
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw ProbeError.tokenizerNotFound(file.path)
    }
  }
  // WhisperKit のローカル読み込みと同じ経路で一度読み、読めなければ止める（通信しない）
  do {
    _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder, hubApi: hubApi)
  } catch {
    throw ProbeError.tokenizerCorrupted(tokenizerFolder.path)
  }
}

/// 昇順に並んだ値の中央値。偶数個のときは中央の2つの平均。
func median(of sorted: [Double]) -> Double? {
  guard !sorted.isEmpty else { return nil }
  let middle = sorted.count / 2
  return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
