import Darwin
import Foundation

/// このプロセスの物理メモリ。Activity Monitor の「メモリ」列と同じ phys_footprint。
///
/// SpeechAnalyzer の推論の一部は OS のプロセスで動く可能性があり、その分はここに含まれない
/// （要件定義6章「OS 管理領域は別計測」。README の手順で別に記録する）。
struct MemoryUsage: Sendable {
  /// 現在の phys_footprint（バイト）
  let physFootprint: UInt64
  /// プロセス開始からの phys_footprint の最大値（バイト）。サンプリング間隔に依存しないピーク
  let lifetimeMaxPhysFootprint: UInt64

  static func current() -> MemoryUsage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    return MemoryUsage(
      physFootprint: info.ri_phys_footprint,
      lifetimeMaxPhysFootprint: info.ri_lifetime_max_phys_footprint
    )
  }
}

func megabytes(_ bytes: UInt64) -> Double {
  (Double(bytes) / 1_048_576 * 10).rounded() / 10
}

/// 計測条件の記録用（端末識別子は含めない）
struct MachineInfo: Codable, Sendable {
  let osVersion: String
  let hardwareModel: String
  let cpu: String
  let physicalMemoryGB: Double

  static func current() -> MachineInfo {
    MachineInfo(
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      hardwareModel: sysctlString("hw.model") ?? "不明",
      cpu: sysctlString("machdep.cpu.brand_string") ?? "不明",
      physicalMemoryGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()
    )
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
