import Testing
import UtterCore

@testable import UtterPersistence

struct DictionaryStoreTests {
  @Test("TXT-03: 辞書エントリを追加・取得・削除")
  func dictionaryOperations() async {
    let store = DictionaryStore()

    await store.set(key: "key1", value: "value1")
    #expect(await store.get("key1") == "value1")

    await store.remove("key1")
    #expect(await store.get("key1") == nil)
  }

  @Test("TXT-03: すべてのエントリを一覧取得")
  func listAll() async {
    let store = DictionaryStore()
    await store.set(key: "a", value: "1")
    await store.set(key: "b", value: "2")

    let all = await store.all()
    #expect(all.count == 2)
    #expect(all["a"] == "1")
  }

  @Test("AI-05: 月次コスト合計を記録・集計")
  func monthlyUsage() async throws {
    let store = MonthlyUsageStore()
    try await store.add(month: "2024-10", cost: 5.0)
    try await store.add(month: "2024-10", cost: 3.0)

    #expect(await store.total(month: "2024-10") == 8.0)
  }

  @Test("AI-05: 負のコスト値を拒否")
  func rejectNegativeCost() async {
    let store = MonthlyUsageStore()
    do {
      try await store.add(month: "2024-10", cost: -1.0)
      #expect(Bool(false), "負のコストが拒否されるはず")
    } catch CostError.negativeCost(-1.0) {
      // 期待通り
    } catch {
      #expect(Bool(false), "予期しないエラー: \(error)")
    }
  }

  @Test("AI-05: 無限大のコスト値を拒否")
  func rejectNonFiniteCost() async {
    let store = MonthlyUsageStore()
    do {
      try await store.add(month: "2024-10", cost: Double.infinity)
      #expect(Bool(false), "無限大のコストが拒否されるはず")
    } catch CostError.nonFiniteCost(_) {
      // 期待通り
    } catch {
      #expect(Bool(false), "予期しないエラー: \(error)")
    }
  }

  @Test("AI-05: 月次コストの削除")
  func removeMonth() async throws {
    let store = MonthlyUsageStore()
    try await store.add(month: "2024-10", cost: 5.0)
    await store.remove(month: "2024-10")
    #expect(await store.total(month: "2024-10") == 0)
  }

  @Test("AI-05: 全コストクリア")
  func clearAll() async throws {
    let store = MonthlyUsageStore()
    try await store.add(month: "2024-10", cost: 5.0)
    try await store.add(month: "2024-11", cost: 3.0)
    await store.clear()
    #expect((await store.all()).isEmpty)
  }
}
