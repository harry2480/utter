/// 取得済みのモデルのディレクトリを読む口（PERM-03）。
///
/// `ModelIntegrityVerifier` はこの protocol 越しにファイルの一覧とハッシュを得る。
/// 本番は `LocalModelFileSource`（FileManager と CryptoKit）、テストは `StubModelFileSource` を使う。
public protocol ModelFileSource: Sendable {
  /// ディレクトリの中身をすべて（サブディレクトリの中を含めて）返す。ディレクトリ自体は含めない。
  /// ディレクトリが存在しなければ `nil` を返す
  func entries() throws(ModelFileSourceError) -> [ModelDirectoryEntry]?

  /// 通常ファイルを先頭から最後まで読み、読んだバイト数と SHA-256 を返す。
  /// 読んでいる途中でタスクがキャンセルされたら `.cancelled` を投げる
  func digest(of path: String) throws(ModelFileSourceError) -> ModelFileDigest
}

/// モデルのディレクトリの中の1項目
public struct ModelDirectoryEntry: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// 通常ファイル
    case regularFile(byteCount: Int64)
    /// シンボリックリンク・デバイスなど、通常ファイルでもディレクトリでもないもの。
    /// ディレクトリの外を指しうるため、モデルの一部として扱わない
    case other
  }

  /// ディレクトリからの相対パス（`/` 区切り）
  public let path: String
  public let kind: Kind

  public init(path: String, kind: Kind) {
    self.path = path
    self.kind = kind
  }
}

/// ファイルを読んだ結果
public struct ModelFileDigest: Hashable, Sendable {
  /// 実際に読んだバイト数。一覧を取った後にファイルが変わっていないかの確認に使う
  public let byteCount: Int64
  /// SHA-256 の16進数表記（小文字64桁）
  public let sha256: String

  public init(byteCount: Int64, sha256: String) {
    self.byteCount = byteCount
    self.sha256 = sha256.lowercased()
  }
}

/// モデルのディレクトリを読めなかった理由。パス以外の内容は持たない
public enum ModelFileSourceError: Error, Hashable, Sendable {
  /// 一覧の取得やファイルの読み込みに失敗した（権限、I/O エラー、通常ファイルでないなど）
  case unreadable
  /// 読んでいる途中でタスクがキャンセルされた
  case cancelled
}
