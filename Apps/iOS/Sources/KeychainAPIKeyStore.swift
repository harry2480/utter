import Foundation
import Security
import UtterAI

/// iOS 本体アプリの Keychain による `APIKeyStore`（iOS-10, AC-12, iAC-08）。
///
/// - 本デバイス限定（`WhenUnlockedThisDeviceOnly`）・iCloud 同期なしで保存する。バックアップから別の端末へ復元されない
/// - アクセスグループを指定しない。`keychain-access-groups` の Entitlement を持たないため、本体アプリ自身の
///   グループ（application-identifier）に入り、App Group には入らない。キーボード拡張からは読めない（iAC-08）
/// - 端末のロック中は読み出せない（`errSecInteractionNotAllowed`）。その間の整形は送信せずにローカル整形になる
/// - キーの値はログ・エラーに出さない。エラーは `OSStatus` だけを持つ
/// - macOS とは共有しない（Apps/macOS に別の実装がある, 13章）
struct KeychainAPIKeyStore: APIKeyStore {
  let service: String
  let account: String

  /// Claude API キーの保存先。service は Bundle ID（未設定なら固定値）。
  static func claude(bundle: Bundle = .main) -> KeychainAPIKeyStore {
    KeychainAPIKeyStore(
      service: bundle.bundleIdentifier ?? "utter", account: "claude-api-key")
  }

  func load() throws(APIKeyStoreError) -> APIKey? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else { throw .operationFailed(code: status) }
    guard let data = result as? Data, let string = String(data: data, encoding: .utf8),
      let key = try? APIKey(string)
    else {
      throw .invalidStoredData
    }
    return key
  }

  func save(_ key: APIKey) throws(APIKeyStoreError) {
    let data = Data(key.value.utf8)
    // 保存済みなら置き換える。削除してから追加すると、追加に失敗したときに元のキーを失うため更新を先に試す
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw .operationFailed(code: updateStatus)
    }
    var item = baseQuery()
    item.merge(attributes) { _, new in new }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw .operationFailed(code: addStatus) }
  }

  func delete() throws(APIKeyStoreError) {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw .operationFailed(code: status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // iCloud キーチェーンで同期しない（検索も同期しない項目だけを対象にする）
      kSecAttrSynchronizable as String: false,
    ]
  }
}
