import Foundation

/// 時刻つきのログを標準出力と（指定時は）ファイルへ書く。
///
/// キー入力として記録してよいのは修飾キーと Esc だけ。通常の文字キーのキーコードや文字は
/// 呼び出し側で渡さないこと（「他のキーが押された」という事実だけを書く）。
@MainActor
final class ProbeLog {
  private let fileHandle: FileHandle?
  private let formatter: ISO8601DateFormatter

  init(filePath: String?) throws {
    formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    guard let filePath else {
      fileHandle = nil
      return
    }
    let url = URL(fileURLWithPath: filePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    fileHandle = handle
  }

  /// `[時刻] [uptime ms] [区分] 本文` の1行を書く。uptime は再起動まで単調増加する経過時間。
  func write(_ category: String, _ message: String) {
    let uptimeMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000
    let line =
      "\(formatter.string(from: Date())) up=\(String(format: "%.1f", uptimeMs))ms [\(category)] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    fileHandle?.write(Data(line.utf8))
  }

  func close() {
    try? fileHandle?.synchronize()
    try? fileHandle?.close()
  }
}
