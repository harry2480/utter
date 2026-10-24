import CryptoKit
import Foundation

/// ローカルのディレクトリに置いたモデルを読む `ModelFileSource`（PERM-03）。
///
/// - シンボリックリンクはたどらず `.other` として返す（ディレクトリの外のファイルをモデルとして読まない）。
///   モデルのディレクトリ自体がシンボリックリンクなら、一覧を返さず `.unreadable` を投げる
/// - ハッシュはファイルを一定の大きさずつ読んで計算し、ファイル全体をメモリに載せない
/// - ハッシュを計算するときは、モデルのディレクトリを開いてその下だけを解決し、途中のディレクトリを含めて
///   シンボリックリンクをたどらない（`openat` と `O_NOFOLLOW_ANY` / `O_RESOLVE_BENEATH`）。
///   一覧の取得後に途中のディレクトリやモデルのディレクトリ自体をリンクに差し替えられても、外のファイルを読まない。
///   通常ファイルの中身を検証後に書き換える操作は防げないため、ディレクトリの書き込み権限で守る
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
    // ディレクトリ自体のシンボリックリンクもたどらない（lstat）。たどると、別の場所のファイルを検証済みにしてしまう
    var status = stat()
    guard lstat(directory.path, &status) == 0 else {
      if errno == ENOENT {
        return nil
      }
      throw .unreadable
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
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
    // モデルのディレクトリを開き、その下だけを解決して開く。
    // 絶対パスに O_NOFOLLOW_ANY を付けると、/var → /private/var のような上位のリンクで失敗するため、
    // ディレクトリ自体は O_NOFOLLOW（最後の要素だけ）で開き、ファイルは openat で相対に開く
    let directoryDescriptor = open(
      directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
      throw .unreadable
    }
    defer { close(directoryDescriptor) }
    // 途中のディレクトリを含めてリンクをたどらず、ディレクトリの外へ出ない。
    // FIFO に差し替えられても待たないよう O_NONBLOCK で開き、通常ファイルと確認してから外す
    let descriptor = openat(
      directoryDescriptor, path,
      O_RDONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw .unreadable
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw .unreadable
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      throw .unreadable
    }

    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
    defer { buffer.deallocate() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      if Task.isCancelled {
        throw .cancelled
      }
      let count = read(descriptor, buffer.baseAddress, chunkSize)
      if count < 0 {
        if errno == EINTR {
          continue
        }
        throw .unreadable
      }
      if count == 0 {
        break
      }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
      byteCount += Int64(count)
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return ModelFileDigest(byteCount: byteCount, sha256: hex)
  }
}
