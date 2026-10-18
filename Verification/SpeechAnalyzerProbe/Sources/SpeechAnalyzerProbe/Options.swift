import Foundation
import Speech

/// コマンドラインの解析。依存を増やさないため手書きにする。
enum Command {
  case status(locale: Locale)
  case authorize
  case install(locale: Locale)
  case release(locale: Locale)
  case file(path: String, run: RunOptions)
  case mic(seconds: Double, run: RunOptions)
  case batch(manifest: String, output: String, run: RunOptions)
}

/// 音声の渡し方
enum Pace: String {
  /// 音声の長さどおりの間隔で渡す（マイク入力の模擬）。遅延を計測できる
  case realtime
  /// 待たずに渡す。処理速度（実時間比）だけを計測でき、遅延は計測できない
  case fast
}

struct RunOptions {
  var locale = Locale(identifier: "ja_JP")
  var preset: PresetName = .progressive
  var pace: Pace = .realtime
  var retention: SpeechAnalyzer.Options.ModelRetention?
  /// 記録用の名前（省略時は OS の既定）
  var retentionName = "default"
  var cancelAfter: Double?
  var memoryInterval: Double = 0.5
  var logPath: String?
  /// 確定・暫定の本文を標準出力に出すか（batch は件数が多いため既定で出さない）
  var printsText = true
}

enum PresetName: String, CaseIterable {
  case progressive
  case transcription
  case timeIndexedProgressive

  var preset: SpeechTranscriber.Preset {
    switch self {
    case .progressive: .progressiveTranscription
    case .transcription: .transcription
    case .timeIndexedProgressive: .timeIndexedProgressiveTranscription
    }
  }
}

struct UsageError: Error, CustomStringConvertible {
  let description: String
}

let usage = """
  使い方:
    speechanalyzer-probe status   [--locale ja_JP]
    speechanalyzer-probe authorize
    speechanalyzer-probe install  [--locale ja_JP]
    speechanalyzer-probe release  [--locale ja_JP]
    speechanalyzer-probe file  <音声ファイル> [実行オプション]   （既定 --pace realtime）
    speechanalyzer-probe mic   [--seconds 10] [実行オプション]
    speechanalyzer-probe batch <manifest.json> --out <results.json> [実行オプション]   （既定 --pace fast）

  実行オプション:
    --locale <id>             既定 ja_JP
    --preset <名前>           progressive（既定）| transcription | timeIndexedProgressive
    --pace <realtime|fast>    realtime: 音声の長さどおりに渡す（遅延を計測） / fast: 待たずに渡す（実時間比のみ）
    --retention <名前>        whileInUse | lingering | processLifetime（省略時は OS の既定）
    --cancel-after <秒>       入力開始からこの秒数で cancelAndFinishNow() を呼び、応答時間を計測する
    --memory-interval <秒>    物理メモリ（phys_footprint）の記録間隔。既定 0.5
    --log <path.jsonl>        結果・メモリのイベントを JSON Lines で保存する（認識本文を含む）

  詳細は Verification/SpeechAnalyzerProbe/README.md を参照。
  """

func parseCommand(_ arguments: [String]) throws -> Command {
  guard let name = arguments.first else { throw UsageError(description: usage) }
  var rest = Array(arguments.dropFirst())
  var run = RunOptions()
  var seconds = 10.0
  var output: String?
  var positional: [String] = []
  var paceSpecified = false

  func value(for flag: String) throws -> String {
    guard !rest.isEmpty else { throw UsageError(description: "\(flag) に値がありません") }
    return rest.removeFirst()
  }
  func number(for flag: String) throws -> Double {
    let text = try value(for: flag)
    guard let number = Double(text), number > 0 else {
      throw UsageError(description: "\(flag) には正の数を指定してください: \(text)")
    }
    return number
  }

  while !rest.isEmpty {
    let argument = rest.removeFirst()
    switch argument {
    case "--locale": run.locale = Locale(identifier: try value(for: argument))
    case "--preset":
      let text = try value(for: argument)
      guard let preset = PresetName(rawValue: text) else {
        throw UsageError(description: "不明な --preset: \(text)")
      }
      run.preset = preset
    case "--pace":
      let text = try value(for: argument)
      guard let pace = Pace(rawValue: text) else {
        throw UsageError(description: "不明な --pace: \(text)")
      }
      run.pace = pace
      paceSpecified = true
    case "--retention":
      let text = try value(for: argument)
      // システムフレームワークの enum は case 名を文字列化できる保証がないため、明示的に対応づける
      let retentions: [String: SpeechAnalyzer.Options.ModelRetention] = [
        "whileInUse": .whileInUse, "lingering": .lingering, "processLifetime": .processLifetime,
      ]
      guard let retention = retentions[text] else {
        throw UsageError(description: "不明な --retention: \(text)")
      }
      run.retention = retention
      run.retentionName = text
    case "--cancel-after": run.cancelAfter = try number(for: argument)
    case "--memory-interval": run.memoryInterval = try number(for: argument)
    case "--log": run.logPath = try value(for: argument)
    case "--seconds": seconds = try number(for: argument)
    case "--out": output = try value(for: argument)
    case "-h", "--help": throw UsageError(description: usage)
    default:
      guard !argument.hasPrefix("--") else {
        throw UsageError(description: "不明なオプション: \(argument)\n\n\(usage)")
      }
      positional.append(argument)
    }
  }

  func onlyPositional(_ count: Int) throws {
    guard positional.count == count else { throw UsageError(description: usage) }
  }

  switch name {
  case "status":
    try onlyPositional(0)
    return .status(locale: run.locale)
  case "authorize":
    try onlyPositional(0)
    return .authorize
  case "install":
    try onlyPositional(0)
    return .install(locale: run.locale)
  case "release":
    try onlyPositional(0)
    return .release(locale: run.locale)
  case "file":
    try onlyPositional(1)
    // fast では入力が一瞬で終わり、キャンセルが入力の途中に入る保証がない
    if run.cancelAfter != nil, run.pace == .fast {
      throw UsageError(description: "--cancel-after は --pace realtime（file の既定）でだけ使えます")
    }
    return .file(path: positional[0], run: run)
  case "mic":
    try onlyPositional(0)
    run.pace = .realtime
    return .mic(seconds: seconds, run: run)
  case "batch":
    try onlyPositional(1)
    guard let output else { throw UsageError(description: "batch には --out <results.json> が必要です") }
    guard run.cancelAfter == nil else {
      throw UsageError(description: "batch では --cancel-after を使えません（file / mic で計測してください）")
    }
    if !paceSpecified { run.pace = .fast }
    run.printsText = false
    return .batch(manifest: positional[0], output: output, run: run)
  default:
    throw UsageError(description: usage)
  }
}
