import Darwin
import Foundation
import Observation
import UIKit
import os

/// プロセスのメモリ（phys_footprint）と熱状態・電池を一定間隔で記録する。
@MainActor
@Observable
final class ResourceMonitor {
  static let interval: Duration = .milliseconds(500)

  private(set) var samples: [ResourceSample] = []
  private(set) var latest: ResourceSample?
  /// 実行中の認識の番号。サンプルに付けて、CSV で区間を見分けられるようにする
  var activeRunID: Int?

  @ObservationIgnored private var loop: Task<Void, Never>?

  func start() {
    guard loop == nil else { return }
    UIDevice.current.isBatteryMonitoringEnabled = true
    loop = Task { [weak self] in
      while !Task.isCancelled {
        self?.record()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  /// 今の値を1件記録して返す（実行の開始・終了時にも呼ぶ）
  @discardableResult
  func record() -> ResourceSample {
    let memory = MemoryProbe.footprint()
    let processInfo = ProcessInfo.processInfo
    let sample = ResourceSample(
      uptimeSeconds: processInfo.systemUptime,
      date: Date(),
      footprintBytes: memory?.current,
      processPeakFootprintBytes: memory?.processPeak,
      availableBytes: UInt64(os_proc_available_memory()),
      thermalState: processInfo.thermalState,
      batteryLevel: UIDevice.current.batteryLevel,
      lowPowerMode: processInfo.isLowPowerModeEnabled,
      activeRunID: activeRunID
    )
    samples.append(sample)
    latest = sample
    return sample
  }

  func reset() {
    samples.removeAll()
  }

  /// タイムライン CSV。発話本文は含めない。
  func timelineCSV() -> String {
    let start = samples.first?.uptimeSeconds ?? 0
    let formatter = ISO8601DateFormatter()
    var lines = [
      "elapsed_s,timestamp,footprint_mb,process_peak_footprint_mb,available_mb,thermal_state,battery_level,low_power_mode,run_id"
    ]
    for sample in samples {
      let columns = [
        String(format: "%.2f", sample.uptimeSeconds - start),
        formatter.string(from: sample.date),
        megabytes(sample.footprintBytes).map { String(format: "%.1f", $0) } ?? "",
        megabytes(sample.processPeakFootprintBytes).map { String(format: "%.1f", $0) } ?? "",
        String(format: "%.1f", Double(sample.availableBytes) / 1_048_576),
        sample.thermalState.label,
        sample.batteryLevel < 0 ? "" : String(format: "%.2f", sample.batteryLevel),
        sample.lowPowerMode ? "1" : "0",
        sample.activeRunID.map(String.init) ?? "",
      ]
      lines.append(columns.joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// task_vm_info からメモリ量を読む。
enum MemoryProbe {
  struct Footprint {
    /// phys_footprint
    var current: UInt64
    /// ledger_phys_footprint_peak（プロセス起動以降の最大値）。カーネルが返さなければ nil
    var processPeak: UInt64?
  }

  static func footprint() -> Footprint? {
    var info = task_vm_info_data_t()
    let fullCount = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    var count = mach_msg_type_number_t(fullCount)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: fullCount) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let peakEnd =
      (MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak) ?? .max)
      + MemoryLayout<Int64>.size
    let returnedBytes = Int(count) * MemoryLayout<natural_t>.size
    let peak =
      returnedBytes >= peakEnd && info.ledger_phys_footprint_peak > 0
      ? UInt64(info.ledger_phys_footprint_peak) : nil
    return Footprint(current: UInt64(info.phys_footprint), processPeak: peak)
  }
}

enum DeviceInfo {
  /// 機種の識別子（例: iPhone17,1）。シミュレータでは実行環境の機種を返す
  static var modelIdentifier: String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }
}
