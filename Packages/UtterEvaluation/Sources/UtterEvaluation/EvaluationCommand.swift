import Foundation

/// `utter-eval` コマンドの処理。標準出力・標準エラーへの書き込みは呼び出し側（`utter-eval`）が行う。
///
/// 標準出力には集計表だけを、標準エラーには固定の文言と識別子・記入ミスの位置だけを返し、発話本文を含めない。
public enum EvaluationCommand {
  public struct Result: Hashable, Sendable {
    public let standardOutput: String
    public let standardError: String
    /// 終了コード（sysexits.h に合わせる）
    public let exitCode: Int32
  }

  /// `arguments` は `CommandLine.arguments` と同じ形（先頭はコマンド名）。
  public static func run(
    arguments: [String],
    readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }
  ) -> Result {
    guard arguments.count == 2 else {
      return failure("使い方: utter-eval <results.json>", exitCode: 64)
    }
    do {
      let data = try readFile(URL(fileURLWithPath: arguments[1]))
      let samples = try JSONDecoder().decode([EvaluationSample].self, from: data)
      let report = try EvaluationReport(samples: samples)
      return Result(standardOutput: report.markdownTable(), standardError: "", exitCode: 0)
    } catch let error as EvaluationSampleError {
      // 発話本文は出さず、識別子だけを示す
      return failure("評価セットに不備があります: \(error)", exitCode: 65)
    } catch let error as DecodingError {
      // 値は出さず、記入ミスの位置（配列の番号とキー）だけを示す
      return failure("評価結果の形式が正しくありません: \(location(of: error))", exitCode: 65)
    } catch {
      // エラーの型名だけを出す
      return failure("評価結果を読み込めません: \(type(of: error))", exitCode: 66)
    }
  }

  private static func failure(_ message: String, exitCode: Int32) -> Result {
    Result(standardOutput: "", standardError: message + "\n", exitCode: exitCode)
  }

  static func location(of error: DecodingError) -> String {
    let path: [any CodingKey]
    switch error {
    case .typeMismatch(_, let context), .valueNotFound(_, let context),
      .keyNotFound(_, let context),
      .dataCorrupted(let context):
      path = context.codingPath
    @unknown default:
      path = []
    }
    let keys = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    if case .keyNotFound(let key, _) = error {
      return keys + " にキー \(key.stringValue) がありません"
    }
    return keys.isEmpty ? "ルート" : keys
  }
}
