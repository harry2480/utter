import Foundation
import Testing

@testable import UtterPersistence

struct DictionaryStoreTests {
  private let store: DictionaryStore

  init() throws {
    store = DictionaryStore(database: try UtterDatabase.inMemory())
  }

  @Test("TXT-03: 辞書語を追加・一覧・削除でき、追加した順に並ぶ")
  func termsCanBeAddedListedAndRemoved() throws {
    try store.addTerm("Claude")
    try store.addTerm("utter")
    try store.addTerm("Claude")

    #expect(try store.terms() == ["Claude", "utter"])

    try store.removeTerm("Claude")
    try store.removeTerm("missing")

    #expect(try store.terms() == ["utter"])
  }

  @Test("TXT-03: 空の辞書語・空のパターンは保存しない")
  func rejectsEmptyValues() throws {
    #expect(throws: DictionaryStoreError.emptySpelling) {
      try store.addTerm("")
    }
    #expect(throws: DictionaryStoreError.emptyPattern) {
      try store.saveRule(StoredReplacementRule(pattern: "", replacement: "x"))
    }
    #expect(try store.terms().isEmpty)
    #expect(try store.rules().isEmpty)
  }

  @Test("TXT-03: 置換ルールを追加・更新・削除でき、更新しても定義順を保つ")
  func rulesCanBeAddedUpdatedAndRemoved() throws {
    try store.saveRule(StoredReplacementRule(pattern: "くろーど", replacement: "Claude"))
    try store.saveRule(
      StoredReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true))
    try store.saveRule(StoredReplacementRule(pattern: "くろーど", replacement: "Claude Code"))

    #expect(
      try store.rules() == [
        StoredReplacementRule(pattern: "くろーど", replacement: "Claude Code"),
        StoredReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true),
      ])

    try store.removeRule(pattern: "くろーど")

    #expect(
      try store.rules() == [
        StoredReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true)
      ])
  }

  @Test("TXT-03: 正規化形式が違うだけの辞書語・パターンは同じものとして扱う")
  func normalizesUnicode() throws {
    try store.addTerm("が")
    try store.addTerm("か\u{3099}")
    try store.saveRule(StoredReplacementRule(pattern: "が", replacement: "1"))
    try store.saveRule(StoredReplacementRule(pattern: "か\u{3099}", replacement: "2"))

    #expect(try store.terms().count == 1)
    #expect(try store.rules().map(\.replacement) == ["2"])

    try store.removeTerm("か\u{3099}")
    try store.removeRule(pattern: "か\u{3099}")

    #expect(try store.terms().isEmpty)
    #expect(try store.rules().isEmpty)
  }

  @Test("TXT-03: すべての辞書語と置換ルールを削除できる")
  func removeAllClearsTermsAndRules() throws {
    try store.addTerm("utter")
    try store.saveRule(StoredReplacementRule(pattern: "a", replacement: "b"))

    try store.removeAll()

    #expect(try store.terms().isEmpty)
    #expect(try store.rules().isEmpty)
  }
}

struct MonthlyUsageStoreTests {
  private let store: MonthlyUsageStore

  init() throws {
    store = MonthlyUsageStore(database: try UtterDatabase.inMemory())
  }

  private func month(_ year: Int, _ month: Int) throws -> UsageMonth {
    try UsageMonth(year: year, month: month)
  }

  @Test("AI-05: 月ごとの推定費用を加算し、Decimal の誤差なく累計する")
  func recordsMonthlyTotalsExactly() throws {
    let october = try month(2026, 10)
    try store.record(Decimal(string: "0.1")!, currencyCode: "JPY", in: october)
    try store.record(Decimal(string: "0.2")!, currencyCode: "JPY", in: october)

    #expect(try store.spent(in: october, currencyCode: "JPY") == Decimal(string: "0.3"))
    #expect(try store.spent(in: try month(2026, 11), currencyCode: "JPY") == 0)
  }

  @Test("AI-05: 月をまたいで、両端を含む期間の合計を集計する")
  func aggregatesAcrossMonths() throws {
    try store.record(10, currencyCode: "JPY", in: try month(2026, 11))
    try store.record(20, currencyCode: "JPY", in: try month(2026, 12))
    try store.record(40, currencyCode: "JPY", in: try month(2027, 1))
    try store.record(80, currencyCode: "JPY", in: try month(2027, 2))
    try store.record(5, currencyCode: "USD", in: try month(2026, 12))

    let total = try store.spent(
      from: try month(2026, 12), through: try month(2027, 1), currencyCode: "JPY")

    #expect(total == 60)
    #expect(
      try store.spent(from: try month(2027, 1), through: try month(2026, 12), currencyCode: "JPY")
        == 0)
  }

  @Test("AI-05: 通貨ごとに分けて保存し、月の古い順に一覧できる")
  func listsEntriesByMonthAndCurrency() throws {
    try store.record(3, currencyCode: "USD", in: try month(2026, 10))
    try store.record(1, currencyCode: "JPY", in: try month(2026, 10))
    try store.record(2, currencyCode: "JPY", in: try month(2026, 9))

    #expect(
      try store.entries() == [
        MonthlyUsageEntry(month: try month(2026, 9), currencyCode: "JPY", amount: 2),
        MonthlyUsageEntry(month: try month(2026, 10), currencyCode: "JPY", amount: 1),
        MonthlyUsageEntry(month: try month(2026, 10), currencyCode: "USD", amount: 3),
      ])
  }

  @Test("AI-05: 負の値・NaN・不正な通貨コードは記録せず、既存の累計を保つ")
  func rejectsInvalidRecords() throws {
    let october = try month(2026, 10)
    try store.record(5, currencyCode: "JPY", in: october)

    #expect(throws: MonthlyUsageStoreError.negativeAmount) {
      try store.record(-1, currencyCode: "JPY", in: october)
    }
    #expect(throws: MonthlyUsageStoreError.invalidAmount) {
      try store.record(Decimal.nan, currencyCode: "JPY", in: october)
    }
    for code in ["jpy", "JP", "JPYY", "円円円"] {
      #expect(throws: MonthlyUsageStoreError.invalidCurrencyCode) {
        try store.record(1, currencyCode: code, in: october)
      }
    }
    #expect(try store.spent(in: october, currencyCode: "JPY") == 5)
  }

  @Test("AI-05: 加算後の累計が Decimal で表せなければ拒否し、既存の累計を保つ")
  func rejectsOverflowingTotal() throws {
    let october = try month(2026, 10)
    try store.record(Decimal.greatestFiniteMagnitude, currencyCode: "JPY", in: october)

    #expect(throws: MonthlyUsageStoreError.totalOverflow) {
      try store.record(Decimal.greatestFiniteMagnitude, currencyCode: "JPY", in: october)
    }
    #expect(try store.spent(in: october, currencyCode: "JPY") == Decimal.greatestFiniteMagnitude)
  }

  @Test("AI-05: 月をまたいだ合計が Decimal で表せなければ、期間の集計を拒否する")
  func rejectsOverflowingRangeTotal() throws {
    let november = try month(2026, 11)
    let december = try month(2026, 12)
    try store.record(Decimal.greatestFiniteMagnitude, currencyCode: "JPY", in: november)
    try store.record(Decimal.greatestFiniteMagnitude, currencyCode: "JPY", in: december)

    #expect(throws: MonthlyUsageStoreError.totalOverflow) {
      try store.spent(from: november, through: december, currencyCode: "JPY")
    }
    #expect(
      try store.spent(from: november, through: november, currencyCode: "JPY")
        == Decimal.greatestFiniteMagnitude)
  }

  @Test("AI-05: 範囲外の年月は作れない", arguments: [(2026, 0), (2026, 13), (0, 1), (10_000, 1)])
  func rejectsInvalidMonth(_ year: Int, _ month: Int) {
    #expect(throws: MonthlyUsageStoreError.invalidMonth) {
      try UsageMonth(year: year, month: month)
    }
  }

  @Test("AI-05: 月の記録・すべての記録を削除できる")
  func removesRecords() throws {
    try store.record(1, currencyCode: "JPY", in: try month(2026, 9))
    try store.record(2, currencyCode: "JPY", in: try month(2026, 10))
    try store.record(3, currencyCode: "USD", in: try month(2026, 10))

    try store.remove(month: try month(2026, 10))
    #expect(
      try store.entries() == [
        MonthlyUsageEntry(month: try month(2026, 9), currencyCode: "JPY", amount: 1)
      ])

    try store.removeAll()
    #expect(try store.entries().isEmpty)
  }
}

struct UtterDatabaseTests {
  private let directory = TemporaryDirectory()

  @Test("TXT-03, AI-05: ファイルに保存した辞書と使用量は、開き直しても復元できる")
  func persistsAcrossReopen() throws {
    let url = directory.url.appendingPathComponent("utter.sqlite")
    let october = try UsageMonth(year: 2026, month: 10)
    do {
      let database = try UtterDatabase.open(at: url)
      try DictionaryStore(database: database).addTerm("utter")
      try MonthlyUsageStore(database: database).record(
        Decimal(string: "1.25")!, currencyCode: "JPY", in: october)
    }

    let reopened = try UtterDatabase.open(at: url)

    #expect(try DictionaryStore(database: reopened).terms() == ["utter"])
    #expect(
      try MonthlyUsageStore(database: reopened).spent(in: october, currencyCode: "JPY")
        == Decimal(string: "1.25"))
  }

  @Test("TXT-03, AI-05: スキーマ移行は版ごとに一度だけ適用され、開き直しても再適用しない")
  func appliesMigrationsOnce() throws {
    let url = directory.url.appendingPathComponent("utter.sqlite")
    let first = try UtterDatabase.open(at: url)
    let second = try UtterDatabase.open(at: url)

    let applied = try second.writer.read { db in
      try UtterDatabase.migrator.appliedMigrations(db)
    }
    #expect(applied == ["v1", "v2"])
    #expect(try first.writer.read { db in try UtterDatabase.migrator.hasCompletedMigrations(db) })
  }
}
