import Foundation

/// 計測イベントを JSON Lines でローカルファイルへ書く。外部へは送らない。
///
/// `result` イベントは認識本文を含む。ファイルは `--log` で指定した場所にだけ作る。
actor EventLog {
  private let handle: FileHandle?
  private let encoder: JSONEncoder

  init(path: String?) throws {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let path else {
      handle = nil
      return
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw ProbeError("ログファイルを作成できません: \(path)")
    }
    handle = try FileHandle(forWritingTo: url)
  }

  func write(_ event: some Encodable) {
    guard let handle, var data = try? encoder.encode(event) else { return }
    data.append(0x0A)
    handle.write(data)
  }

  func close() {
    try? handle?.close()
  }
}

struct ProbeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// 標準エラー出力へ書く（標準出力は計測結果に使う）
func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func toSeconds(_ duration: Duration) -> Double {
  let (whole, attoseconds) = duration.components
  return Double(whole) + Double(attoseconds) / 1e18
}

func fixed(_ value: Double?, digits: Int = 3) -> String {
  guard let value else { return "-" }
  return String(format: "%.\(digits)f", value)
}
