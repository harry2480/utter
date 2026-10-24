import Synchronization

/// 固定の一覧・ハッシュ・失敗を返すテスト用の `ModelFileSource`（PERM-03）。
///
/// ハッシュを求められたパスを記録し、検証がどのファイルを読んだかを確かめられる。
public final class StubModelFileSource: ModelFileSource {
  /// ディレクトリの中身。`nil` はディレクトリが存在しない状態
  public let listing: Result<[ModelDirectoryEntry]?, ModelFileSourceError>
  /// パスごとの読み込み結果。登録のないパスは `.unreadable` を投げる
  public let digests: [String: Result<ModelFileDigest, ModelFileSourceError>]
  private let requested = Mutex<[String]>([])

  public init(
    listing: Result<[ModelDirectoryEntry]?, ModelFileSourceError>,
    digests: [String: Result<ModelFileDigest, ModelFileSourceError>] = [:]
  ) {
    self.listing = listing
    self.digests = digests
  }

  /// ハッシュを求められたパス（呼ばれた順）
  public var requestedPaths: [String] {
    requested.withLock { $0 }
  }

  public func entries() throws(ModelFileSourceError) -> [ModelDirectoryEntry]? {
    try listing.get()
  }

  public func digest(of path: String) throws(ModelFileSourceError) -> ModelFileDigest {
    requested.withLock { $0.append(path) }
    guard let result = digests[path] else {
      throw .unreadable
    }
    return try result.get()
  }
}
