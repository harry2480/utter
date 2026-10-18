import CryptoKit
import Foundation

/// ローカルのディレクトリに置いたモデルを読む `ModelFileSource`（PERM-03）。
///
/// - シンボリックリンクはたどらず `.other` として返す（ディレクトリの外のファイルをモデルとして読まない）
/// - ハッシュはファイルを一定の大きさずつ読んで計算し、ファイル全体をメモリに載せない
/// - ハッシュを計算するときも最後の要素のシンボリックリンクはたどらない（`O_NOFOLLOW`）。
///   途中のディレクトリを一覧の取得後に差し替える操作までは防がない。
///   それができる権限があれば検証後にファイルを書き換えられるため、ディレクトリの書き込み権限で守る
public struct LocalModelFileSource: ModelFileSource {
  /// ハッシュの計算で1回に読むバイト数の既定値
  public static let defaultChunkSize = 1 << 20

  public let directory: URL
  public let chunkSize: Int

  /// - Parameters:
  ///   - directory: モデルのディレクトリ
  ///   - chunkSize: ハッシュの計算で1回に読むバイト数。1未満は既定値にする
  public init(directory: URL, chunkSize: Int = defaultChunkSize) {
    self.directory = directory
    self.chunkSize = chunkSize > 0 ? chunkSize : Self.defaultChunkSize
  }

  public func entries() throws(ModelFileSourceError) -> [ModelDirectoryEntry]? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
      return nil
    }
    guard isDirectory.boolValue else {
      throw .unreadable
    }
    let keys: [URLResourceKey] = [
      .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
    ]
    var failed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys, options: [.producesRelativePathURLs],
        errorHandler: { _, _ in
          failed = true
          return false
        })
    else {
      throw .unreadable
    }
    var result: [ModelDirectoryEntry] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        throw .unreadable
      }
      let path = url.relativePath
      if values.isSymbolicLink == true {
        result.append(ModelDirectoryEntry(path: path, kind: .other))
      } else if values.isDirectory == true {
        continue
      } else if values.isRegularFile == true, let size = values.fileSize {
        result.append(ModelDirectoryEntry(path: path, kind: .regularFile(byteCount: Int64(size))))
      } else {
        result.append(ModelDirectoryEntry(path: path, kind: .other))
      }
    }
    // 一覧の途中で読めない項目があれば、欠けた一覧で検証しない
    guard !failed else {
      throw .unreadable
    }
    return result
  }

  public func digest(of path: String) throws(ModelFileSourceError) -> ModelFileDigest {
    guard ModelManifest.File.isSafeRelativePath(path) else {
      throw .unreadable
    }
    let url = directory.appendingPathComponent(path, isDirectory: false)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw .unreadable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw .unreadable
    }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      if Task.isCancelled {
        throw .cancelled
      }
      let chunk: Data?
      do {
        chunk = try handle.read(upToCount: chunkSize)
      } catch {
        throw .unreadable
      }
      guard let chunk, !chunk.isEmpty else {
        break
      }
      hasher.update(data: chunk)
      byteCount += Int64(chunk.count)
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return ModelFileDigest(byteCount: byteCount, sha256: hex)
  }
}
