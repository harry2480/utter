import Foundation
import UtterCore

/// 試す挿入経路。AX は2通りの書き方を分けて計測する。
enum ProbeRoute: String, CaseIterable {
  /// kAXSelectedTextAttribute に書き込む（選択範囲・カーソル位置への挿入）
  case axSelected = "ax-selected"
  /// kAXValueAttribute に「選択範囲を置き換えた全体の値」を書き込む
  case axValue = "ax-value"
  /// Pasteboard に書き込み、Cmd+V を送る
  case pasteboard
  /// CGEvent のキー入力（Unicode 文字列付きのキーイベント）
  case cgevent

  /// 本番コードの経路（互換性表の表記）との対応
  var insertionRoute: InsertionRoute {
    switch self {
    case .axSelected, .axValue: .accessibility
    case .pasteboard: .pasteboard
    case .cgevent: .keyEvents
    }
  }
}

/// 挿入する固定のダミー文字列。機密情報を含めない。
///
/// どれも `#` で始まるため、シェルに入って万一 Enter が送られてもコメントとして扱われ、コマンドは実行されない。
enum TextPreset: String, CaseIterable {
  case ascii
  case ja
  case emoji
  case multiline

  var text: String {
    switch self {
    case .ascii: "# utter probe ABC 123"
    case .ja: "# utter検証 テスト用のダミー文です。句読点、記号（）も含む"
    case .emoji: "# utter検証 絵文字👍🏽と結合文字é"
    case .multiline: "# utter検証 1行目\n# utter検証 2行目"
    }
  }

  var containsNewline: Bool { text.contains("\n") }
}

/// Pasteboard 経路で付ける一時データの印（INS-06、nspasteboard.org の規約）
enum MarkerSet: String, CaseIterable {
  case both
  case transient
  case concealed
  case none

  var types: [String] {
    switch self {
    case .both: [PasteboardMarker.transient, PasteboardMarker.concealed]
    case .transient: [PasteboardMarker.transient]
    case .concealed: [PasteboardMarker.concealed]
    case .none: []
    }
  }
}

enum PasteboardMarker {
  static let transient = "org.nspasteboard.TransientType"
  static let concealed = "org.nspasteboard.ConcealedType"
}

struct RunOptions {
  var route: ProbeRoute = .axSelected
  var trials = 1
  var delay = 5.0
  var interval = 2.0
  var hold = 0.0
  var text: TextPreset = .ascii
  var label = ""
  var outputDirectory = "results"
  var markers: MarkerSet = .both
  var readBackTimeout = 1.5
  var restoreDelay = 0.3
  var interactive = false
  var axFlag: String?
  var allowMultilineInTerminal = false
}

enum Command {
  case check(prompt: Bool)
  case inspect(delay: Double)
  case run(RunOptions)
  case help
}

struct UsageError: Error, CustomStringConvertible {
  let description: String
}

enum ArgumentParser {
  static func parse(_ arguments: [String]) throws -> Command {
    guard let subcommand = arguments.first else { return .help }
    var rest = Array(arguments.dropFirst())
    switch subcommand {
    case "check":
      let prompt = rest.contains("--prompt")
      rest.removeAll { $0 == "--prompt" }
      guard rest.isEmpty else { throw UsageError(description: "不明な引数: \(rest)") }
      return .check(prompt: prompt)
    case "inspect":
      var delay = 3.0
      var iterator = rest.makeIterator()
      while let flag = iterator.next() {
        guard flag == "--delay" else { throw UsageError(description: "不明な引数: \(flag)") }
        delay = try double(iterator.next(), for: flag)
      }
      return .inspect(delay: delay)
    case "run":
      return .run(try parseRun(rest))
    case "help", "-h", "--help":
      return .help
    default:
      throw UsageError(description: "不明なサブコマンド: \(subcommand)")
    }
  }

  private static func parseRun(_ arguments: [String]) throws -> RunOptions {
    var options = RunOptions()
    var iterator = arguments.makeIterator()
    while let flag = iterator.next() {
      switch flag {
      case "--route":
        options.route = try choice(iterator.next(), for: flag)
      case "--trials":
        let value = iterator.next()
        guard let trials = value.flatMap(Int.init), trials >= 1 else {
          throw UsageError(description: "\(flag) には1以上の整数を指定してください")
        }
        options.trials = trials
      case "--delay": options.delay = try double(iterator.next(), for: flag)
      case "--interval": options.interval = try double(iterator.next(), for: flag)
      case "--hold": options.hold = try double(iterator.next(), for: flag)
      case "--readback-timeout": options.readBackTimeout = try double(iterator.next(), for: flag)
      case "--restore-delay": options.restoreDelay = try double(iterator.next(), for: flag)
      case "--text": options.text = try choice(iterator.next(), for: flag)
      case "--markers": options.markers = try choice(iterator.next(), for: flag)
      case "--label":
        guard let label = iterator.next() else { throw UsageError(description: "\(flag) に値がありません") }
        options.label = label
      case "--out":
        guard let path = iterator.next() else { throw UsageError(description: "\(flag) に値がありません") }
        options.outputDirectory = path
      case "--ax-flag":
        let value = iterator.next()
        guard let value, ["AXEnhancedUserInterface", "AXManualAccessibility"].contains(value) else {
          throw UsageError(
            description: "\(flag) には AXEnhancedUserInterface か AXManualAccessibility を指定してください")
        }
        options.axFlag = value
      case "--interactive": options.interactive = true
      case "--allow-multiline-in-terminal": options.allowMultilineInTerminal = true
      default:
        throw UsageError(description: "不明な引数: \(flag)")
      }
    }
    return options
  }

  private static func double(_ value: String?, for flag: String) throws -> Double {
    guard let value, let number = Double(value), number >= 0 else {
      throw UsageError(description: "\(flag) には0以上の数値を指定してください")
    }
    return number
  }

  private static func choice<T: RawRepresentable & CaseIterable>(_ value: String?, for flag: String)
    throws -> T where T.RawValue == String
  {
    guard let value, let parsed = T(rawValue: value) else {
      let allowed = T.allCases.map(\.rawValue).joined(separator: " | ")
      throw UsageError(description: "\(flag) には次のどれかを指定してください: \(allowed)")
    }
    return parsed
  }

  static let usage = """
    使い方: ax-insertion-probe <サブコマンド> [オプション]

    サブコマンド:
      check [--prompt]       Accessibility とイベント送信の権限を確認する（--prompt で許可ダイアログを出す）
      inspect [--delay 秒]   指定秒数後にフォーカス中の要素の属性を表示する（値の中身は表示しない）
      run [オプション]        指定秒数後にフォーカス中の入力欄へダミー文字列を挿入し、結果を記録する
      help                   この説明を表示する

    run のオプション:
      --route ax-selected|ax-value|pasteboard|cgevent   挿入経路（既定: ax-selected）
      --trials N             試行回数（既定: 1）
      --delay 秒             各試行の前に待つ秒数。この間に対象の入力欄をクリックする（既定: 5）
      --interval 秒          --interactive なしで連続試行するときの試行間隔（既定: 2）
      --hold 秒              挿入対象を記録してから挿入するまで待ち、同じ要素かを再検証する（既定: 0 = 再検証なし）
      --text ascii|ja|emoji|multiline   挿入するダミー文字列（既定: ascii）
      --label 文字列          記録に残す入力欄の説明（例: "Safari input"）
      --out ディレクトリ      記録の出力先（既定: ./results）。trials.csv と trials.jsonl に追記する
      --markers both|transient|concealed|none   Pasteboard 経路で付ける一時データの印（既定: both）
      --readback-timeout 秒  読み戻しで一致を待つ最大時間（既定: 1.5）
      --restore-delay 秒     Pasteboard 経路で、読み戻しの後クリップボードを復元するまで待つ時間（既定: 0.3）
      --ax-flag AXEnhancedUserInterface|AXManualAccessibility
                             挿入前に対象アプリへこの属性を true で設定し、試行後に元へ戻す（Chrome / Electron 用）
      --interactive          各試行の後に、目視確認・Undo・クリップボード履歴をターミナルで質問して記録する
      --allow-multiline-in-terminal   ターミナル系アプリへ改行を含む文字列を送ることを許可する
    """
}
