/// API キーの保存先（AC-12）。本番は各アプリの Keychain 実装（本デバイス限定・iCloud 同期なし）、
/// テストは `StubAPIKeyStore` を使う。
///
/// 1つのインスタンスが1つのキー（例: Claude API キー）を扱う。
/// 実装はキーの値をログ・エラーに出さない。
public protocol APIKeyStore: Sendable {
  /// 保存済みのキーを読み出す。保存されていなければ `nil`。
  func load() throws(APIKeyStoreError) -> APIKey?
  /// キーを保存する。保存済みのキーがあれば置き換える。
  func save(_ key: APIKey) throws(APIKeyStoreError)
  /// キーを削除する。保存されていなくても成功する。
  func delete() throws(APIKeyStoreError)
}

/// API キーの保存先の失敗。キーの値は持たない。
public enum APIKeyStoreError: Error, Hashable, Sendable {
  /// 保存先の操作に失敗した。`code` は保存先の状態コード（Keychain の `OSStatus` など）
  case operationFailed(code: Int32)
  /// 保存されている値を API キーとして読めない
  case invalidStoredData
}
