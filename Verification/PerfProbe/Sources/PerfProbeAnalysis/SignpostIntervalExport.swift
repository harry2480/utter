import Foundation

/// `xctrace export` で書き出した `OSSignpostIntervals` 表の1行。
public struct SignpostIntervalRecord: Hashable, Sendable {
  public let name: String
  public let subsystem: String
  /// 開始したプロセス（例: `perf-probe-demo (95897)`）
  public let process: String
  public let durationNanoseconds: Int64

  public init(name: String, subsystem: String, process: String, durationNanoseconds: Int64) {
    self.name = name
    self.subsystem = subsystem
    self.process = process
    self.durationNanoseconds = durationNanoseconds
  }

  public var durationMilliseconds: Double {
    Double(durationNanoseconds) / 1_000_000
  }
}

public enum SignpostIntervalExportError: Error, Equatable {
  /// XML として読めない
  case malformedXML(String)
  /// `OSSignpostIntervals` の列定義が見つからない（xpath の指定違い、または xctrace の形式変更）
  case missingColumns([String])
}

/// `xctrace export --xpath '.../table[@schema="OSSignpostIntervals"]'` の XML を読む。
///
/// xctrace の XML は同じ値を2回目以降 `ref` で参照するため、`id` ごとの値を覚えて解決する。
/// 終了していない区間（duration が無い行）は `incompleteRows` に数えて結果から除く。
public struct SignpostIntervalExport: Sendable {
  public let records: [SignpostIntervalRecord]
  public let incompleteRows: Int

  public init(data: Data) throws {
    let delegate = ExportParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw SignpostIntervalExportError.malformedXML(
        parser.parserError.map { String(describing: $0) } ?? "unknown"
      )
    }
    let required = ["duration", "name", "subsystem", "process"]
    let missing = required.filter { !delegate.columns.contains($0) }
    if !missing.isEmpty {
      throw SignpostIntervalExportError.missingColumns(missing)
    }

    var records: [SignpostIntervalRecord] = []
    var incomplete = 0
    for row in delegate.rows {
      func cell(_ mnemonic: String) -> ExportParserDelegate.Cell? {
        guard let index = delegate.columns.firstIndex(of: mnemonic), index < row.count else {
          return nil
        }
        return row[index]
      }
      guard
        let duration = cell("duration").flatMap({ Int64($0.text) }),
        let name = cell("name")?.text, !name.isEmpty
      else {
        incomplete += 1
        continue
      }
      records.append(
        SignpostIntervalRecord(
          name: name,
          subsystem: cell("subsystem")?.text ?? "",
          process: cell("process")?.fmt ?? "",
          durationNanoseconds: duration
        )
      )
    }
    self.records = records
    incompleteRows = incomplete
  }
}

/// XMLParser のコールバックを受けて、列定義と行を組み立てる。
/// パース中だけ使い、外へは出さない。
private final class ExportParserDelegate: NSObject, XMLParserDelegate {
  struct Cell {
    var text: String
    var fmt: String
  }

  private(set) var columns: [String] = []
  private(set) var rows: [[Cell]] = []

  private var valuesByID: [String: Cell] = [:]
  private var elementStack: [String] = []
  /// 開いている要素ごとの (id, 直下の文字列, fmt)
  private var openCells: [(id: String?, text: String, fmt: String)] = []
  private var currentRow: [Cell]?
  private var mnemonicText: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let parent = elementStack.last
    elementStack.append(elementName)

    if elementName == "mnemonic", parent == "col" {
      mnemonicText = ""
    }
    if elementName == "row" {
      currentRow = []
    }
    if let ref = attributeDict["ref"] {
      openCells.append(
        (id: nil, text: valuesByID[ref]?.text ?? "", fmt: valuesByID[ref]?.fmt ?? ""))
    } else {
      openCells.append((id: attributeDict["id"], text: "", fmt: attributeDict["fmt"] ?? ""))
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if mnemonicText != nil {
      mnemonicText? += string
    }
    guard !openCells.isEmpty else { return }
    openCells[openCells.count - 1].text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let open = openCells.removeLast()
    elementStack.removeLast()
    let cell = Cell(
      text: open.text.trimmingCharacters(in: .whitespacesAndNewlines),
      fmt: open.fmt
    )
    if let id = open.id {
      valuesByID[id] = cell
    }

    if elementName == "mnemonic", let text = mnemonicText {
      columns.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
      mnemonicText = nil
    }
    if elementName == "row" {
      if let row = currentRow {
        rows.append(row)
      }
      currentRow = nil
    } else if elementStack.last == "row" {
      // 行の直下の要素が1列分。sentinel は空の値
      currentRow?.append(elementName == "sentinel" ? Cell(text: "", fmt: "") : cell)
    }
  }
}
