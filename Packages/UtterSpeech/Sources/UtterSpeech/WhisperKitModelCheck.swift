/// WhisperKit のモデルのフォルダを、ロードしてよいか判定する（PERM-03）。
///
/// 次の両方を満たすときだけ `.ready` にする。
/// - マニフェストに、WhisperKit がロードに使うファイルがそろっている（`requiredComponents` と `requiredTokenizerFiles`）
/// - マニフェストに、WhisperKit が直下より先にトークナイザーを探す場所（`disallowedPathPrefixes`）のファイルがない
/// - フォルダが `ModelIntegrityVerifier` でマニフェストと一致した（`.verified`。マニフェストにないファイルがあれば失敗）
///
/// トークナイザーはモデルのフォルダの直下に置き、モデル本体と同じマニフェストで照合する
/// （ライセンス・依存関係.md 3.4 の案 a）。WhisperKit はローカルのトークナイザーが無い・読めないと、
/// `download: false` でも Hugging Face から照合なしで取得するため（同 3.2）、そろっていなければロードしない。
///
/// モデルの取得はしない。取得と表示は Apps が行う。
/// 処理は同期的にファイルを読むため、メインスレッドの外で呼ぶ。
public struct WhisperKitModelCheck: Sendable {
  /// WhisperKit がロードする Core ML モデル（`<名前>.mlmodelc` のディレクトリ）
  public static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
  /// フォルダの直下に置くトークナイザーのファイル。WhisperKit は `tokenizer.json` があるフォルダから読み、
  /// `tokenizer_config.json` が無いと読み込みに失敗する（WhisperKitProbe で確認）
  public static let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

  /// マニフェストに置けないパスの先頭。WhisperKit はフォルダ直下より先に `models/openai/whisper-*/` の下の
  /// トークナイザーを探し、読めなければ Hugging Face から取得するため、直下のトークナイザーだけを使うよう置かせない
  public static let disallowedPathPrefixes = ["models/"]

  public let manifest: ModelManifest

  public init(manifest: ModelManifest) {
    self.manifest = manifest
  }

  /// マニフェストに足りないもの。`<名前>.mlmodelc/` で始まるファイルが1つもない Core ML モデルと、
  /// 直下にないトークナイザーのファイルを返す。空ならそろっている
  public var missingRequirements: [String] {
    let paths = Set(manifest.files.map(\.path))
    let missingComponents = Self.requiredComponents.map { "\($0).mlmodelc/" }.filter { prefix in
      !paths.contains { $0.hasPrefix(prefix) }
    }
    let missingTokenizerFiles = Self.requiredTokenizerFiles.filter { !paths.contains($0) }
    return missingComponents + missingTokenizerFiles
  }

  /// マニフェストにある、置けないパス（`disallowedPathPrefixes` で始まるもの）
  public var disallowedPaths: [String] {
    manifest.files.map(\.path).filter { path in
      Self.disallowedPathPrefixes.contains { path.hasPrefix($0) }
    }
  }

  /// フォルダを判定する。タスクがキャンセルされたら `CancellationError` を投げる
  public func check(_ source: some ModelFileSource) throws(CancellationError)
    -> WhisperKitModelReadiness
  {
    // マニフェストが足りなければ、重いハッシュの計算をしない
    let missing = missingRequirements
    guard missing.isEmpty else {
      return .incompleteManifest(missing)
    }
    let disallowed = disallowedPaths
    guard disallowed.isEmpty else {
      return .disallowedPaths(disallowed)
    }
    switch try ModelIntegrityVerifier(manifest: manifest).verify(source) {
    case .notInstalled:
      return .notInstalled
    case .failed(let issues):
      return .integrityFailed(issues)
    case .verified:
      return .ready
    }
  }
}

/// WhisperKit のモデルのフォルダの状態。値に含むのはモデルのファイルのパスとサイズだけ
public enum WhisperKitModelReadiness: Hashable, Sendable {
  /// ロードしてよい
  case ready
  /// フォルダがない（未取得）
  case notInstalled
  /// マニフェストに WhisperKit のロードに要るファイルがない（値は足りないもの）。マニフェストの誤り
  case incompleteManifest([String])
  /// マニフェストに置けないパスがある（値はそのパス）。マニフェストの誤り
  case disallowedPaths([String])
  /// フォルダがマニフェストと一致しない。取得し直しを案内する
  case integrityFailed([ModelIntegrityIssue])

  /// 認識を始められないときの失敗の種類。`.ready` なら `nil`
  public var recognitionError: SpeechRecognitionError? {
    switch self {
    case .ready: nil
    case .notInstalled, .incompleteManifest, .disallowedPaths, .integrityFailed: .modelUnavailable
    }
  }
}
