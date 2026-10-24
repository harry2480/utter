import Foundation

// Phase 0 検証（#48）: SpeechAnalyzer / SpeechTranscriber の日本語・部分認識・遅延・メモリを計測する。
// 使い捨てのプロトタイプ。テレメトリ・外部送信はしない（install のアセット取得だけ OS 経由で通信する）。

let command: Command
do {
  command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
} catch {
  printError("\(error)")
  exit(64)
}

do {
  switch command {
  case .status(let locale):
    await runStatus(locale: locale)
  case .authorize:
    await runAuthorize()
  case .install(let locale):
    try await runInstall(locale: locale)
  case .release(let locale):
    await runRelease(locale: locale)
  case .file(let path, let options):
    guard FileManager.default.fileExists(atPath: path) else {
      throw ProbeError("音声ファイルがありません: \(path)")
    }
    let log = try EventLog(path: options.logPath)
    printError(
      "pace=\(options.pace.rawValue) preset=\(options.preset.rawValue) retention=\(options.retentionName)"
    )
    let output = try await transcribe(
      source: .file(URL(fileURLWithPath: path)), options: options, log: log)
    await log.close()
    printSummary(output.summary)
    print("確定テキスト          : \(output.finalText)")
    if output.summary.error != nil { exit(1) }
  case .mic(let seconds, let options):
    let log = try EventLog(path: options.logPath)
    printError("preset=\(options.preset.rawValue) retention=\(options.retentionName)")
    let output = try await transcribe(
      source: .microphone(seconds: seconds), options: options, log: log)
    await log.close()
    printSummary(output.summary)
    print("確定テキスト          : \(output.finalText)")
    if output.summary.error != nil { exit(1) }
  case .batch(let manifest, let outputPath, let options):
    let log = try EventLog(path: options.logPath)
    printError(
      "pace=\(options.pace.rawValue) preset=\(options.preset.rawValue) retention=\(options.retentionName)"
    )
    let failures = try await runBatch(
      manifestPath: manifest, outputPath: outputPath, options: options, log: log)
    await log.close()
    if failures > 0 { exit(1) }
  }
} catch {
  printError("エラー: \(error)")
  exit(1)
}
