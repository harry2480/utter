/// 取得済みのモデルの状態（PERM-03）。取得状態の表示と、ロードしてよいかの判定に使う
public enum ModelIntegrityStatus: Hashable, Sendable {
  /// モデルのディレクトリがない（未取得）
  case notInstalled
  /// マニフェストのとおりのファイルがそろい、サイズと SHA-256 が一致した
  case verified
  /// 完全性を確認できなかった。ロードせず、取得し直しを案内する
  case failed([ModelIntegrityIssue])

  /// ロードしてよいか。検証済みのときだけ `true`
  public var isLoadable: Bool {
    self == .verified
  }
}

/// 完全性を確認できなかった理由。値に含むのはモデルのファイルのパスとサイズだけ
public enum ModelIntegrityIssue: Hashable, Sendable {
  /// ディレクトリの一覧を取れなかった
  case directoryUnreadable
  /// マニフェストにあるファイルがない
  case missingFile(String)
  /// マニフェストにないファイルがある
  case unexpectedFile(String)
  /// シンボリックリンクなど、通常ファイルでもディレクトリでもない項目がある
  case unsupportedEntry(String)
  /// サイズがマニフェストと違う
  case sizeMismatch(path: String, expected: Int64, actual: Int64)
  /// SHA-256 がマニフェストと違う
  case digestMismatch(String)
  /// ファイルを読めなかった
  case unreadableFile(String)
}

/// 取得したモデルをマニフェストと照合し、完全性を判定する（PERM-03）。
///
/// 次のどれかがあれば `.failed` にする。
/// - マニフェストにあるファイルの欠落、サイズの不一致、SHA-256 の不一致、読み込みの失敗
/// - マニフェストにないファイル、シンボリックリンクなどの通常ファイルでない項目
///
/// パスは大文字・小文字を区別して照合する（Unicode 正規化の違いは `String` の比較で同じとみなされる）。
/// 取得処理はマニフェストのパスのとおりに書き込むため、大文字・小文字だけが違えば欠落とマニフェスト外のファイルとして失敗にする。
/// 大文字・小文字を区別するボリュームで別のファイルを同じものとみなさないよう、ゆるい照合はしない（失敗しても取得し直せば直る）。
///
/// ハッシュの計算は重いため、一覧だけで分かる問題（欠落・サイズ・余分な項目）が先に見つかったら、
/// ハッシュを計算せずにそれだけを返す。このため `.failed` の一覧は、すべての問題を網羅するとは限らない。
///
/// 処理は同期的にファイルを読む。呼び出し側はメインスレッドの外（バックグラウンドのタスク）で呼ぶ。
/// タスクがキャンセルされたら `CancellationError` を投げ、判定を返さない。
///
/// 検証後にファイルが書き換えられた場合は検出できない。モデルのディレクトリはアプリだけが書き込める場所に置き、
/// 取得・検証・ロードの間に他から変更されないようにする。
public struct ModelIntegrityVerifier: Sendable {
  public let manifest: ModelManifest

  public init(manifest: ModelManifest) {
    self.manifest = manifest
  }

  public func verify(_ source: some ModelFileSource) throws(CancellationError)
    -> ModelIntegrityStatus
  {
    let listed: [ModelDirectoryEntry]
    do {
      guard let entries = try source.entries() else {
        return .notInstalled
      }
      listed = entries
    } catch .cancelled {
      throw CancellationError()
    } catch {
      return .failed([.directoryUnreadable])
    }

    let entriesByPath = Dictionary(
      listed.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
    let expectedPaths = Set(manifest.files.map(\.path))

    var issues: [ModelIntegrityIssue] = []
    var filesToHash: [ModelManifest.File] = []
    for file in manifest.files {
      switch entriesByPath[file.path] {
      case nil:
        issues.append(.missingFile(file.path))
      case .other:
        issues.append(.unsupportedEntry(file.path))
      case .regularFile(let byteCount) where byteCount != file.byteCount:
        issues.append(.sizeMismatch(path: file.path, expected: file.byteCount, actual: byteCount))
      case .regularFile:
        filesToHash.append(file)
      }
    }
    for path in entriesByPath.keys.sorted() where !expectedPaths.contains(path) {
      switch entriesByPath[path] {
      case .regularFile:
        issues.append(.unexpectedFile(path))
      case .other, nil:
        issues.append(.unsupportedEntry(path))
      }
    }
    guard issues.isEmpty else {
      return .failed(issues)
    }

    for file in filesToHash {
      if Task.isCancelled {
        throw CancellationError()
      }
      do {
        let digest = try source.digest(of: file.path)
        if digest.byteCount != file.byteCount {
          // 一覧を取った後にファイルが変わった
          issues.append(
            .sizeMismatch(path: file.path, expected: file.byteCount, actual: digest.byteCount))
        } else if digest.sha256 != file.sha256 {
          issues.append(.digestMismatch(file.path))
        }
      } catch .cancelled {
        throw CancellationError()
      } catch {
        issues.append(.unreadableFile(file.path))
      }
    }
    return issues.isEmpty ? .verified : .failed(issues)
  }
}
