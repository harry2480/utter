import Foundation
import Security
import UtterAI

/// Keychain による `ChatGPTAccountStore`（AC-12, #50）。
///
/// - Sign in with ChatGPT の記録（ホスト ID・発行済みのクライアントID・アクセストークン・リフレッシュトークン・
///   ID トークン）を1つの項目にまとめて、data protection keychain に本デバイス限定（`WhenUnlockedThisDeviceOnly`）・
///   iCloud 同期なしで保存する。この Mac の外へ移らず、バックアップから別の Mac へ復元されない
/// - アクセストークン・期限・スコープ・入れ替わったリフレッシュトークンは、1回の更新でまとめて置き換える（S3）
/// - 署名なしのビルドでは `errSecMissingEntitlement` で失敗する。同期される旧来の keychain へは切り替えない（安全側）
/// - 記録の中身はログ・エラーに出さない。エラーは `OSStatus` だけを持つ
struct KeychainChatGPTAccountStore: ChatGPTAccountStore {
  let service: String
  let account: String

  /// 既定の保存先。service は Bundle ID（未設定なら固定値）で、API キーと account だけを分ける
  static func standard(bundle: Bundle = .main) -> KeychainChatGPTAccountStore {
    KeychainChatGPTAccountStore(
      service: bundle.bundleIdentifier ?? "utter", account: "chatgpt-sign-in")
  }

  func load() throws(ChatGPTAccountStoreError) -> ChatGPTAccountRecord? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else { throw .operationFailed(code: status) }
    guard let data = result as? Data,
      let record = try? JSONDecoder().decode(ChatGPTAccountRecord.self, from: data)
    else {
      throw .invalidStoredData
    }
    return record
  }

  func save(_ record: ChatGPTAccountRecord) throws(ChatGPTAccountStoreError) {
    guard let data = try? JSONEncoder().encode(record) else { throw .invalidStoredData }
    // 保存済みなら置き換える。削除してから追加すると、追加に失敗したときに元の記録を失うため更新を先に試す
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

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      // iCloud キーチェーンで同期しない（検索も同期しない項目だけを対象にする）
      kSecAttrSynchronizable as String: false,
    ]
  }
}
