import Darwin
import Foundation
import Synchronization

/// プロセスの物理フットプリント（phys_footprint）。アクティビティモニタの「メモリ」列と同じ指標。
///
/// Core ML が GPU 用に確保した領域の一部はこのプロセスに計上されるが、
/// ANE のコンパイル・実行を担うシステムプロセス（ANECompilerService など）の使用量は含まれない。
struct FootprintReading: Sendable {
  /// 現在の phys_footprint（バイト）
  let current: UInt64
  /// プロセス開始からの phys_footprint の最大値（バイト）。サンプリング間隔に依存しないピーク
  let lifetimeMax: UInt64

  static func read() -> FootprintReading? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard status == 0 else { return nil }
    return FootprintReading(
      current: info.ri_phys_footprint, lifetimeMax: info.ri_lifetime_max_phys_footprint)
  }
}

/// 熱状態を CSV 用の文字列にする。
func thermalStateLabel(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState)
  -> String
{
  switch state {
  case .nominal: "nominal"
  case .fair: "fair"
  case .serious: "serious"
  case .critical: "critical"
  @unknown default: "unknown"
  }
}

/// 行ごとに書き込む CSV。プロセスが異常終了しても、そこまでの行が残るように都度書き込む。
final class CSVFile: Sendable {
  private let handle: Mutex<FileHandle>

  init(url: URL, header: [String]) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw ProbeError.cannotCreateFile(url.path)
    }
    handle = Mutex(try FileHandle(forWritingTo: url))
    append(header)
  }

  func append(_ fields: [String]) {
    let line = fields.map(Self.escape).joined(separator: ",") + "\n"
    handle.withLock { $0.write(Data(line.utf8)) }
  }

  func close() {
    handle.withLock { try? $0.synchronize() }
  }

  private static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// phys_footprint を一定間隔で記録し、区間（ロード・各回の推論など）ごとのピークを求める。
///
/// 推論中は Swift Concurrency の協調スレッドが埋まることがあるため、専用スレッドで計測する。
final class MemorySampler: Sendable {
  struct PhaseResult: Sendable {
    let before: UInt64
    let after: UInt64
    /// 区間中のサンプルと区間の開始・終了時点の最大値
    let peak: UInt64
    /// 区間終了時点のプロセス開始からの最大値
    let lifetimeMax: UInt64
  }

  private struct State {
    var phase = "start"
    var index = 0
    var phaseBefore: UInt64 = 0
    var phasePeak: UInt64 = 0
  }

  private let state = Mutex(State())
  private let stopped = Atomic<Bool>(false)
  private let csv: CSVFile
  private let interval: TimeInterval
  private let origin = ContinuousClock.now

  init(csv: CSVFile, intervalMilliseconds: Int) {
    self.csv = csv
    interval = Double(intervalMilliseconds) / 1000
  }

  func start() {
    Thread.detachNewThread { [self] in
      while !stopped.load(ordering: .relaxed) {
        sample()
        Thread.sleep(forTimeInterval: interval)
      }
    }
  }

  func stop() {
    stopped.store(true, ordering: .relaxed)
    sample()
  }

  /// 区間を始める。開始時点の値を記録してピークをリセットする。
  func begin(phase: String, index: Int) {
    let reading = FootprintReading.read()?.current ?? 0
    state.withLock {
      $0.phase = phase
      $0.index = index
      $0.phaseBefore = reading
      $0.phasePeak = reading
    }
    sample()
  }

  /// 区間を終える。以降のサンプルは `idle` 区間として記録する。
  func end() -> PhaseResult {
    sample()
    let reading = FootprintReading.read()
    return state.withLock {
      let after = reading?.current ?? 0
      let result = PhaseResult(
        before: $0.phaseBefore,
        after: after,
        peak: max($0.phasePeak, after),
        lifetimeMax: reading?.lifetimeMax ?? 0
      )
      $0.phase = "idle"
      $0.phasePeak = 0
      return result
    }
  }

  private func sample() {
    guard let reading = FootprintReading.read() else { return }
    let elapsed = (ContinuousClock.now - origin).seconds
    let (phase, index) = state.withLock {
      $0.phasePeak = max($0.phasePeak, reading.current)
      return ($0.phase, $0.index)
    }
    csv.append([
      format(elapsed, digits: 3), phase, String(index), megabytes(reading.current),
      megabytes(reading.lifetimeMax), thermalStateLabel(),
    ])
  }
}

extension Duration {
  var seconds: Double {
    let (seconds, attoseconds) = components
    return Double(seconds) + Double(attoseconds) / 1e18
  }
}

func megabytes(_ bytes: UInt64) -> String {
  format(Double(bytes) / 1_048_576, digits: 1)
}

func format(_ value: Double, digits: Int) -> String {
  value.formatted(
    .number.precision(.fractionLength(digits)).grouping(.never).locale(
      Locale(identifier: "en_US_POSIX")))
}

/// 計測条件の記録用。
enum MachineInfo {
  static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func lines() -> [String] {
    let info = ProcessInfo.processInfo
    return [
      "hardware_model: \(hardwareModel())",
      "os: \(info.operatingSystemVersionString)",
      "physical_memory_gb: \(format(Double(info.physicalMemory) / 1_073_741_824, digits: 1))",
      "active_processors: \(info.activeProcessorCount)",
      "low_power_mode: \(info.isLowPowerModeEnabled)",
      "thermal_state_at_start: \(thermalStateLabel())",
    ]
  }
}

enum ProbeError: Error, CustomStringConvertible {
  case cannotCreateFile(String)
  case modelNameMismatch(requested: String, resolved: String)
  case modelNotFound(String)
  case tokenizerNotFound(String)
  case tokenizerUnknown(String)
  case tokenizerCorrupted(String)
  case audioNotFound(String)
  case emptyAudio

  var description: String {
    switch self {
    case .cannotCreateFile(let path): "ファイルを作成できません: \(path)"
    case .modelNameMismatch(let requested, let resolved):
      "モデル名 \(requested) が一意に決まりません（取得されたのは \(resolved)）。フォルダ名を正確に指定してください"
    case .modelNotFound(let path): "モデルがありません: \(path)。先に fetch を実行してください"
    case .tokenizerNotFound(let path):
      "トークナイザーがありません: \(path)。先に fetch を実行してください（オフラインで計測するため）"
    case .tokenizerUnknown(let path):
      "モデル \(path) のトークナイザーを判定できません。ロード中に通信するおそれがあるため計測しません"
    case .tokenizerCorrupted(let path):
      "トークナイザーを手元のファイルから読み込めません: \(path)。削除して fetch をやり直してください（オフラインで計測するため）"
    case .audioNotFound(let path): "音声ファイルがありません: \(path)"
    case .emptyAudio: "音声が空です"
    }
  }
}
