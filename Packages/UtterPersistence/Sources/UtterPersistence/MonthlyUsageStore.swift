import Foundation
import GRDB

/// 月ごとの推定費用の保存層（AI-05）。
///
/// UtterAI の `MonthlyUsageLedger` 相当の累計を、月と通貨の組ごとに保存する。
/// UtterAI に依存しないよう、金額は `Decimal`、通貨は ISO 4217 の3文字コードで受け取る。
/// 加算は1つのトランザクションで読み込みと書き込みを行うため、同時に記録しても失われない。
public struct MonthlyUsageStore: Sendable {
  private let database: UtterDatabase

  public init(database: UtterDatabase) {
    self.database = database
  }

  /// 推定費用を指定した月に加算する
  public func record(_ amount: Decimal, currencyCode: String, in month: UsageMonth) throws {
    guard !amount.isNaN else { throw MonthlyUsageStoreError.invalidAmount }
    guard amount >= 0 else { throw MonthlyUsageStoreError.negativeAmount }
    try Self.validate(currencyCode)
    try database.writer.write { db in
      let current = try Self.amount(db, monthIndex: month.index, currencyCode: currencyCode) ?? 0
      try db.execute(
        sql: """
          INSERT INTO monthlyUsage (monthIndex, currencyCode, amount) VALUES (?, ?, ?)
          ON CONFLICT(monthIndex, currencyCode) DO UPDATE SET amount = excluded.amount
          """,
        arguments: [month.index, currencyCode, Self.encode(current + amount)])
    }
  }

  /// 指定した月の推定費用の累計。記録がなければ 0
  public func spent(in month: UsageMonth, currencyCode: String) throws -> Decimal {
    try Self.validate(currencyCode)
    return try database.writer.read { db in
      try Self.amount(db, monthIndex: month.index, currencyCode: currencyCode) ?? 0
    }
  }

  /// `from` から `through` まで（両端を含む）の月をまたいだ推定費用の合計
  public func spent(
    from start: UsageMonth, through end: UsageMonth, currencyCode: String
  ) throws -> Decimal {
    try Self.validate(currencyCode)
    guard start <= end else { return 0 }
    return try database.writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT amount FROM monthlyUsage
          WHERE currencyCode = ? AND monthIndex BETWEEN ? AND ?
          """,
        arguments: [currencyCode, start.index, end.index]
      ).reduce(Decimal(0)) { total, text in total + (try Self.decode(text)) }
    }
  }

  /// 記録のあるすべての月と通貨の累計。月の古い順、同じ月は通貨コード順
  public func entries() throws -> [MonthlyUsageEntry] {
    try database.writer.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT monthIndex, currencyCode, amount FROM monthlyUsage ORDER BY monthIndex, currencyCode"
      ).map { row in
        MonthlyUsageEntry(
          month: try UsageMonth(index: row["monthIndex"]),
          currencyCode: row["currencyCode"],
          amount: try Self.decode(row["amount"]))
      }
    }
  }

  /// 指定した月の記録を、すべての通貨について削除する
  public func remove(month: UsageMonth) throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM monthlyUsage WHERE monthIndex = ?", arguments: [month.index])
    }
  }

  /// すべての記録を削除する
  public func removeAll() throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM monthlyUsage")
    }
  }

  private static func amount(_ db: Database, monthIndex: Int, currencyCode: String) throws
    -> Decimal?
  {
    try String.fetchOne(
      db, sql: "SELECT amount FROM monthlyUsage WHERE monthIndex = ? AND currencyCode = ?",
      arguments: [monthIndex, currencyCode]
    ).map(decode)
  }

  /// 地域設定によらず、小数点を `.` にした文字列で保存する
  private static let posix = Locale(identifier: "en_US_POSIX")

  private static func encode(_ amount: Decimal) -> String {
    NSDecimalNumber(decimal: amount).description(withLocale: posix)
  }

  private static func decode(_ text: String) throws -> Decimal {
    guard let amount = Decimal(string: text, locale: posix), !amount.isNaN else {
      throw MonthlyUsageStoreError.corruptedAmount
    }
    return amount
  }

  private static func validate(_ currencyCode: String) throws {
    guard currencyCode.count == 3, currencyCode.allSatisfy({ $0.isASCII && $0.isUppercase })
    else {
      throw MonthlyUsageStoreError.invalidCurrencyCode
    }
  }
}

/// 使用量を集計する年月（AI-05）。保存のため、年は 1〜9999 に限る
public struct UsageMonth: Hashable, Comparable, Sendable {
  public let year: Int
  public let month: Int

  public init(year: Int, month: Int) throws(MonthlyUsageStoreError) {
    guard (1...9999).contains(year), (1...12).contains(month) else {
      throw .invalidMonth
    }
    self.year = year
    self.month = month
  }

  /// 月の通し番号。範囲検索のため、この順序で保存する
  var index: Int { year * 12 + (month - 1) }

  init(index: Int) throws(MonthlyUsageStoreError) {
    let (year, month) = index.quotientAndRemainder(dividingBy: 12)
    try self.init(year: year, month: month + 1)
  }

  public static func < (lhs: UsageMonth, rhs: UsageMonth) -> Bool {
    lhs.index < rhs.index
  }
}

/// 保存されている月と通貨ごとの累計
public struct MonthlyUsageEntry: Hashable, Sendable {
  public let month: UsageMonth
  public let currencyCode: String
  public let amount: Decimal
}

/// 使用量の保存エラー。金額や利用者の入力は含めない
public enum MonthlyUsageStoreError: Error, Hashable, Sendable {
  case negativeAmount
  /// 金額が数値ではない（NaN）
  case invalidAmount
  /// 通貨コードが ISO 4217 の3文字の大文字ではない
  case invalidCurrencyCode
  /// 年が 1〜9999、月が 1〜12 の範囲外
  case invalidMonth
  /// 保存されている金額を数値として読めない
  case corruptedAmount
}
