import Foundation
import UtterCore

/// iOS キーボード拡張と本体アプリ間で共有結果を保存・復元（iOS-IPC-04〜06）。
///
/// App Group 経由のディレクトリを使用。全操作はスレッドセーフな actor で実装。
public actor SharedResultStore: Sendable {
  private let directory: URL
  private var cache: [String: SharedResult] = [:]

  /// App Group 経由のディレクトリを使用して初期化
  /// - Parameters:
  ///   - groupIdentifier: App Group 識別子（iCloud 同期なし、本デバイス限定）
  public init?(groupIdentifier: String) {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
      return nil
    }
    self.directory = url.appendingPathComponent("SharedResults")
  }

  /// 結果を保存（sessionID ごとに上書き）
  public func save(_ result: SharedResult) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    
    let url = fileURL(for: result.sessionID)
    let data = try JSONEncoder().encode(result)
    try data.write(to: url, options: [.atomic])
    cache[cacheKey(result.sessionID)] = result
  }

  /// 結果を読み込む（存在しなければ nil）
  public func load(sessionID: SessionID) throws -> SharedResult? {
    let key = cacheKey(sessionID)
    if let cached = cache[key] { return cached }
    
    let url = fileURL(for: sessionID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let result = try JSONDecoder().decode(SharedResult.self, from: data)
    cache[key] = result
    return result
  }

  /// 結果を削除
  public func delete(sessionID: SessionID) throws {
    let url = fileURL(for: sessionID)
    try? FileManager.default.removeItem(at: url)
    cache.removeValue(forKey: cacheKey(sessionID))
  }

  /// キャッシュをクリア
  public func clearCache() {
    cache.removeAll()
  }

  private func fileURL(for sessionID: SessionID) -> URL {
    let hash = sessionID.hashValue.description
    return directory.appendingPathComponent("\(hash).json")
  }

  private func cacheKey(_ sessionID: SessionID) -> String {
    sessionID.hashValue.description
  }
}
