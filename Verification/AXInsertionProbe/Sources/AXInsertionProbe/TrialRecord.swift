import Foundation

/// 1回の試行の記録。入力欄の値・クリップボードの中身は含めない（挿入した文字列もプリセット名だけを残す）。
struct TrialRecord: Codable {
  var timestamp = ""
  var label = ""
  var trial = 0
  /// ax-selected / ax-value / pasteboard / cgevent
  var route = ""
  /// 互換性表・`InsertionRoute` の表記（accessibility / pasteboard / keyEvents）
  var insertionRoute = ""
  var bundleID = ""
  var appVersion = ""
  var role = ""
  var subrole = ""
  var macOS = ""
  var textPreset = ""
  var axFlag = ""
  /// 経路の応答（`InsertionResponse`）: succeeded / rejectedBeforeSend / failedAfterSend
  var response = ""
  /// 読み戻し（`InsertionReadBack`）: matches / unchanged / differs / unavailable
  var readBack = ""
  /// range / contains / none
  var readBackMethod = ""
  /// `InsertionResult.classify` の結果: verified / unconfirmed / failed。挿入しなかった場合は skipped
  var result = ""
  /// success / success-visual / failure / unknown / skipped
  var outcome = ""
  /// 挿入しなかった理由: no-focus / secure-field / secure-input / target-changed / multiline-in-terminal
  var skipReason = ""
  /// 挿入の呼び出しにかかった時間（ミリ秒）
  var insertMs = 0
  /// 挿入の開始から読み戻しの判定が出るまでの時間（ミリ秒）
  var confirmMs = 0
  /// Pasteboard 経路で付けた印（both / transient / concealed / none）
  var markers = ""
  var clipboardItems = 0
  var clipboardTypes = 0
  var clipboardUnreadableTypes = 0
  /// restored / restored-mismatch / skipped-changed / failed / n/a
  var restore = ""
  /// 人の記録（--interactive）: yes / no / 空欄
  var visualMatch = ""
  /// 人の記録（--interactive）: once / multiple / partial / none / 空欄
  var undo = ""
  /// 人の記録（--interactive）: クリップボード管理アプリの履歴に残ったか yes / no / 空欄
  var clipboardHistory = ""
  var note = ""

  static let csvHeader = [
    "timestamp", "label", "trial", "route", "insertionRoute", "bundleID", "appVersion", "role",
    "subrole", "macOS", "textPreset", "axFlag", "response", "readBack", "readBackMethod", "result",
    "outcome", "skipReason", "insertMs", "confirmMs", "markers", "clipboardItems", "clipboardTypes",
    "clipboardUnreadableTypes", "restore", "visualMatch", "undo", "clipboardHistory", "note",
  ]

  var csvFields: [String] {
    [
      timestamp, label, String(trial), route, insertionRoute, bundleID, appVersion, role, subrole,
      macOS, textPreset, axFlag, response, readBack, readBackMethod, result, outcome, skipReason,
      String(insertMs), String(confirmMs), markers, String(clipboardItems), String(clipboardTypes),
      String(clipboardUnreadableTypes), restore, visualMatch, undo, clipboardHistory, note,
    ]
  }
}

enum RecordWriter {
  static func append(_ record: TrialRecord, to directory: String) throws {
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let csvURL = directoryURL.appendingPathComponent("trials.csv")
    var csv = ""
    if !FileManager.default.fileExists(atPath: csvURL.path) {
      csv += csvLine(TrialRecord.csvHeader)
    }
    csv += csvLine(record.csvFields)
    try appendText(csv, to: csvURL)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = try encoder.encode(record)
    try appendText(
      String(decoding: json, as: UTF8.self) + "\n",
      to: directoryURL.appendingPathComponent("trials.jsonl"))
  }

  static func csvLine(_ fields: [String]) -> String {
    fields.map(escape).joined(separator: ",") + "\n"
  }

  private static func escape(_ field: String) -> String {
    guard field.contains(where: { [",", "\"", "\n", "\r"].contains($0) }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func appendText(_ text: String, to url: URL) throws {
    let data = Data(text.utf8)
    guard FileManager.default.fileExists(atPath: url.path) else {
      try data.write(to: url)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }
}
