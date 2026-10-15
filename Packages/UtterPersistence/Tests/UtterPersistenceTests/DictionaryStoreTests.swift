import Testing
import UtterCore

@testable import UtterPersistence

struct DictionaryStoreTests {
  @Test("TXT-03: 辞書エントリを追加・取得・削除")
  async func dictionaryOperations() async {
    let store = DictionaryStore()
    
    await store.set("key1", "value1")
    #expect(await store.get("key1") == "value1")
    
    await store.remove("key1")
    #expect(await store.get("key1") == nil)
  }

  @Test("TXT-03: すべてのエントリを一覧取得")
  async func listAll() async {
    let store = DictionaryStore()
    await store.set("a", "1")
    await store.set("b", "2")
    
    let all = await store.all()
    #expect(all.count == 2)
    #expect(all["a"] == "1")
  }

  @Test("AI-05: 月次コスト合計を記録・集計")
  func monthlyUsage() {
    var store = MonthlyUsageStore()
    store.record(month: "2024-10", cost: 5.0)
    store.record(month: "2024-10", cost: 3.0)
    
    #expect(store.total(month: "2024-10") == 8.0)
  }
}
