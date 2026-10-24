import ArgumentParser
import Foundation
import Synchronization
import WhisperKit

/// 検証で固定している WhisperKit のバージョン（Package.swift と合わせる）
let whisperKitVersion = "1.1.1"
/// モデルの取得元（Hugging Face のリポジトリ）
let modelRepository = "argmaxinc/whisperkit-coreml"

enum ProbePaths {
  /// 既定の作業ディレクトリ。リポジトリの外（ユーザーごとの一時ディレクトリ）に置く
  static let root = FileManager.default.temporaryDirectory.appending(
    path: "utter-whisperkit-probe", directoryHint: .isDirectory)
  static let defaultModelsDir = root.appending(path: "models", directoryHint: .isDirectory)

  static func defaultOutDir(command: String, model: String) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return root.appending(path: "out", directoryHint: .isDirectory)
      .appending(path: "\(command)-\(model)-\(formatter.string(from: Date()))")
  }
}

/// Core ML の計算ユニットの指定。`default` は WhisperKit の既定（エンコーダー・デコーダーとも ANE）。
enum ComputeChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
  case `default`
  case ane
  case gpu
  case cpu

  var options: ModelComputeOptions? {
    switch self {
    case .default: nil
    case .ane:
      ModelComputeOptions(
        audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
    case .gpu: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
    case .cpu:
      ModelComputeOptions(
        melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
    }
  }
}

struct ModelOptions: ParsableArguments {
  @Option(help: "モデル名（\(modelRepository) のフォルダ名。例: openai_whisper-base）")
  var model: String

  @Option(help: "モデルとトークナイザーの保存先（リポジトリの外に置く）")
  var modelsDir: String = ProbePaths.defaultModelsDir.path

  @Option(help: "Core ML の計算ユニット（default / ane / gpu / cpu）")
  var compute: ComputeChoice = .default

  var modelsDirURL: URL { URL(fileURLWithPath: modelsDir, isDirectory: true) }

  /// WhisperKit.download が保存するフォルダ（<models-dir>/models/argmaxinc/whisperkit-coreml/<model>）
  var modelFolder: URL {
    HubApiWrapper(downloadBase: modelsDirURL)
      .localRepoLocation(HubApiWrapper.Repo(id: modelRepository))
      .appending(path: model, directoryHint: .isDirectory)
  }
}

struct OutputOptions: ParsableArguments {
  @Option(help: "計測結果の出力先ディレクトリ（既定: 一時ディレクトリ配下に日時つきで作成）")
  var out: String?

  @Option(help: "メモリを記録する間隔（ミリ秒）")
  var intervalMs: Int = 100

  func validate() throws {
    guard intervalMs >= 10 else { throw ValidationError("--interval-ms は 10 以上にしてください") }
  }
}

/// summary.csv の1行。区間ごとの時間とメモリを記録する。発話本文は含めない。
struct SummaryRow {
  var phase: String
  var index: Int = 0
  var label: String = ""
  var wallSeconds: Double?
  var audioSeconds: Double?
  var timings: TranscriptionTimings?
  var memory: MemorySampler.PhaseResult?
  var outputCharacters: Int?
  var sameAsFirst: Bool?
  var success = true
  var error: String = ""
}

/// 1回の実行で使う出力先と計測器。
final class Session: Sendable {
  static let summaryHeader = [
    "command", "model", "compute", "phase", "index", "label", "wall_s", "audio_s", "rtf",
    "encoder_load_s", "decoder_load_s", "tokenizer_load_s", "footprint_before_mb",
    "footprint_after_mb", "footprint_peak_mb", "lifetime_max_mb", "thermal_state",
    "output_chars", "same_as_first", "success", "error",
  ]

  let command: String
  let model: String
  let compute: ComputeChoice
  let outDir: URL
  let sampler: MemorySampler
  private let summary: CSVFile
  private let memory: CSVFile

  init(command: String, model: ModelOptions, output: OutputOptions) throws {
    self.command = command
    self.model = model.model
    compute = model.compute
    outDir =
      output.out.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? ProbePaths.defaultOutDir(command: command, model: model.model)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let environment =
      [
        "command: \(command)",
        "arguments: \(CommandLine.arguments.dropFirst().joined(separator: " "))",
        "date: \(Date().ISO8601Format())",
        "whisperkit_version: \(whisperKitVersion)",
        "model_repository: \(modelRepository)",
        "model: \(model.model)",
        "model_folder: \(model.modelFolder.path)",
        "compute: \(model.compute.rawValue)",
        "memory_interval_ms: \(output.intervalMs)",
      ] + MachineInfo.lines()
    try (environment.joined(separator: "\n") + "\n").write(
      to: outDir.appending(path: "environment.txt"), atomically: true, encoding: .utf8)

    summary = try CSVFile(url: outDir.appending(path: "summary.csv"), header: Self.summaryHeader)
    memory = try CSVFile(
      url: outDir.appending(path: "memory.csv"),
      header: ["elapsed_s", "phase", "index", "footprint_mb", "lifetime_max_mb", "thermal_state"])
    sampler = MemorySampler(csv: memory, intervalMilliseconds: output.intervalMs)
    sampler.start()
    print("出力先: \(outDir.path)")
  }

  func record(_ row: SummaryRow) {
    let timings = row.timings
    let rtf: Double? =
      if let wall = row.wallSeconds, let audio = row.audioSeconds, audio > 0 { wall / audio } else {
        nil
      }
    summary.append([
      command, model, compute.rawValue, row.phase, String(row.index), row.label,
      row.wallSeconds.map { format($0, digits: 3) } ?? "",
      row.audioSeconds.map { format($0, digits: 3) } ?? "",
      rtf.map { format($0, digits: 3) } ?? "",
      timings.map { format($0.encoderLoadTime, digits: 3) } ?? "",
      timings.map { format($0.decoderLoadTime, digits: 3) } ?? "",
      timings.map { format($0.tokenizerLoadTime, digits: 3) } ?? "",
      row.memory.map { megabytes($0.before) } ?? "",
      row.memory.map { megabytes($0.after) } ?? "",
      row.memory.map { megabytes($0.peak) } ?? "",
      row.memory.map { megabytes($0.lifetimeMax) } ?? "",
      thermalStateLabel(),
      row.outputCharacters.map(String.init) ?? "",
      row.sameAsFirst.map { $0 ? "true" : "false" } ?? "",
      row.success ? "true" : "false",
      row.error,
    ])
  }

  /// 区間を計測する。`body` の結果（失敗を含む）と実行時間、区間中のメモリを返す。
  func measure<T>(
    phase: String, index: Int = 0, _ body: () async throws -> T
  ) async -> (result: Result<T, any Error>, wallSeconds: Double, memory: MemorySampler.PhaseResult)
  {
    sampler.begin(phase: phase, index: index)
    let start = ContinuousClock.now
    let result: Result<T, any Error>
    do {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    let wall = (ContinuousClock.now - start).seconds
    return (result, wall, sampler.end())
  }

  /// 区間を計測し、失敗したら summary.csv に記録してエラーを投げ直す。
  func measureOrRecordFailure<T>(
    phase: String, index: Int = 0, _ body: () async throws -> T
  ) async throws -> (value: T, wallSeconds: Double, memory: MemorySampler.PhaseResult) {
    let measured = await measure(phase: phase, index: index, body)
    switch measured.result {
    case .success(let value):
      return (value, measured.wallSeconds, measured.memory)
    case .failure(let error):
      record(
        SummaryRow(
          phase: phase, index: index, wallSeconds: measured.wallSeconds, memory: measured.memory,
          success: false, error: errorLabel(error)))
      throw error
    }
  }

  /// 何もしない区間を一定時間記録する（推論後のメモリ解放・負荷復帰の確認用）。
  func idle(phase: String, seconds: Double) async throws {
    let result = try await measureOrRecordFailure(phase: phase) {
      try await Task.sleep(for: .seconds(seconds))
    }
    record(SummaryRow(phase: phase, wallSeconds: result.wallSeconds, memory: result.memory))
  }

  func finish() {
    sampler.stop()
    summary.close()
    memory.close()
  }
}

/// エラーを記録用の文字列にする。発話本文やパスが混ざらないよう、型名だけにする。
func errorLabel(_ error: any Error) -> String {
  String(describing: type(of: error))
}

/// ダウンロードの進捗を10%刻みで表示する。
final class ProgressPrinter: Sendable {
  private let lastDecile = Mutex(-1)

  func report(_ fraction: Double) {
    let decile = Int((fraction * 10).rounded(.down))
    let shouldPrint = lastDecile.withLock {
      guard decile > $0 else { return false }
      $0 = decile
      return true
    }
    if shouldPrint {
      FileHandle.standardError.write(Data("取得中: \(decile * 10)%\n".utf8))
    }
  }
}

/// モデルの config.json から、WhisperKit が使うトークナイザーのリポジトリ名を求める。
///
/// WhisperKit 1.1.1 の `ModelUtilities.detectVariant` / `tokenizerNameForVariant`（internal）と同じ対応。
/// ロード時にトークナイザーが手元になければ WhisperKit は通信して取得するため、計測前に存在を確かめる。
func tokenizerRepository(modelFolder: URL) -> String? {
  struct Config: Decodable {
    let vocabSize: Int
    let dModel: Int
    enum CodingKeys: String, CodingKey {
      case vocabSize = "vocab_size"
      case dModel = "d_model"
    }
  }
  guard let data = try? Data(contentsOf: modelFolder.appending(path: "config.json")),
    let config = try? JSONDecoder().decode(Config.self, from: data)
  else { return nil }
  let sizes = [384: "tiny", 512: "base", 768: "small", 1024: "medium"]
  switch config.vocabSize {
  case 51865:
    return "openai/whisper-" + (config.dModel == 1280 ? "large-v2" : sizes[config.dModel] ?? "base")
  case 51864: return "openai/whisper-" + (sizes[config.dModel] ?? "base") + ".en"
  case 51866: return "openai/whisper-large-v3"
  default: return nil
  }
}

/// WhisperKit を作る。モデルはまだロードしない（ロード時間を別に計測するため）。
func makeWhisperKit(_ options: ModelOptions) async throws -> WhisperKit {
  let config = WhisperKitConfig(
    modelFolder: options.modelFolder.path,
    tokenizerFolder: options.modelsDirURL,
    computeOptions: options.compute.options,
    // ログに発話本文を出さない
    verbose: false,
    logLevel: .none,
    prewarm: false,
    load: false,
    download: false
  )
  return try await WhisperKit(config)
}

/// モデルをロードし、時間とメモリを記録する。
func loadModels(_ kit: WhisperKit, session: Session, phase: String) async throws {
  let result = try await session.measureOrRecordFailure(phase: phase) {
    try await kit.loadModels()
  }
  session.record(
    SummaryRow(
      phase: phase, wallSeconds: result.wallSeconds, timings: kit.currentTimings,
      memory: result.memory))
  print(
    "\(phase): \(format(result.wallSeconds, digits: 2)) 秒"
      + "（トークナイザー \(format(kit.currentTimings.tokenizerLoadTime, digits: 2)) 秒を含む）"
      + " / ピーク \(megabytes(result.memory.peak)) MB")
}

/// 推論の設定。日本語を指定し、言語判定はしない。
func decodingOptions(chunking: ChunkingChoice) -> DecodingOptions {
  DecodingOptions(
    verbose: false,
    task: .transcribe,
    language: "ja",
    usePrefillPrompt: true,
    detectLanguage: false,
    skipSpecialTokens: true,
    chunkingStrategy: chunking.strategy
  )
}

/// 音声を 16kHz モノラルの配列として読み込む。推論時間に音声の読み込みを含めないため事前に行う。
func loadAudio(path: String) throws -> [Float] {
  guard FileManager.default.fileExists(atPath: path) else { throw ProbeError.audioNotFound(path) }
  let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
  guard !samples.isEmpty else { throw ProbeError.emptyAudio }
  return samples
}

/// 30秒を超える音声の分割方法。
enum ChunkingChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
  case none
  case vad

  var strategy: ChunkingStrategy {
    switch self {
    case .none: .none
    case .vad: .vad
    }
  }
}
