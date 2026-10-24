/// STT モデルの保持モード（6章）。利用者が設定で選ぶ。
public enum ModelRetentionMode: Hashable, Sendable, CaseIterable, Codable {
  /// 推論後に原則モデルを解放する
  case powerSaving
  /// 推論後に短時間保持し、メモリ圧迫・低バッテリーで解放する（標準）
  case balanced
  /// 利用者の許可とメモリの範囲でモデルを保持する。低バッテリーでも保持し、メモリ圧迫時は解放する
  case performance
}

/// OS から通知されるメモリ圧迫の度合い。OS 固有の型はアプリ側でこの値に変換する
public enum MemoryPressure: Hashable, Sendable, Comparable, Codable {
  case normal
  case warning
  case critical
}

/// モデルの負荷の区分。WhisperKit の大きなモデルなど、メモリを多く使うものを `heavy` にする
public enum ModelWeight: Hashable, Sendable {
  case light
  case heavy
}

/// 判定に使う端末の状態
public struct DeviceResourceState: Hashable, Sendable, Codable {
  public let memoryPressure: MemoryPressure
  /// バッテリー駆動で残量が少ない、または低電力モード（外部電源につないでいても含む）
  public let isBatteryLow: Bool

  public init(memoryPressure: MemoryPressure = .normal, isBatteryLow: Bool = false) {
    self.memoryPressure = memoryPressure
    self.isBatteryLow = isBatteryLow
  }
}

/// モデルをロードしてよいかの判定（AC-11）
public enum ModelLoadDecision: Hashable, Sendable {
  case allowed
  /// メモリ圧迫のため、高負荷モデルのロードを見送る。呼び出し側は軽いモデルへの切り替えや通知を行う
  case deferredForMemoryPressure
}

/// 推論後のモデルの扱い（6章）
public enum ModelRetention: Hashable, Sendable {
  /// すぐに解放する
  case releaseNow
  /// 指定した時間だけ保持し、その間に入力がなければ解放する
  case keep(for: Duration)
  /// 端末の状態、またはポリシー（モード・高速モードの許可）が変わるまで保持する。
  /// 呼び出し側は、どちらかが変わったら `retention(in:)` を呼び直す
  case keepUntilStateChanges
}

/// STT モデルのロードと保持の方針（6章, AC-11）。
///
/// 時刻やタイマーは持たず、端末の状態から判定だけを返す。保持時間の既定値は暫定で、Phase 0 の実測後に見直す。
///
/// - メモリ圧迫時は、軽いモデルのロードは許可するが、推論後はモデルの重さによらず解放する（安定性を優先）。
///   軽いモデルを圧迫中も保持するかは、ロードの遅延と電力の実測（Phase 0）で決める
/// - 高速モードの「メモリ上限の範囲」（6章）は、モデルのサイズと上限を比べる判定をまだ持たない。
///   上限の値は Phase 0 の実測後に決め、ここではメモリ圧迫の通知だけで判定する
public struct ModelRetentionPolicy: Hashable, Sendable {
  /// バランスモードで推論後に保持する時間の既定値（暫定。6章では 30〜60 秒を検証候補とする）
  public static let defaultBalancedRetention: Duration = .seconds(30)

  public let mode: ModelRetentionMode
  /// バランスモードで推論後に保持する時間
  public let balancedRetention: Duration
  /// 高速モードでのモデル保持を利用者が許可したか。許可がなければバランスモードとして扱う
  public let performanceRetentionAllowed: Bool

  public init(
    mode: ModelRetentionMode = .balanced,
    balancedRetention: Duration = defaultBalancedRetention,
    performanceRetentionAllowed: Bool = false
  ) throws(ModelRetentionPolicyError) {
    guard balancedRetention > .zero else {
      throw .nonPositiveRetention
    }
    self.mode = mode
    self.balancedRetention = balancedRetention
    self.performanceRetentionAllowed = performanceRetentionAllowed
  }

  /// モデルをロードしてよいか。メモリ圧迫時は、どのモードでも高負荷モデルのロードを抑止する（AC-11）
  public func loadDecision(for weight: ModelWeight, in state: DeviceResourceState)
    -> ModelLoadDecision
  {
    guard weight == .heavy, state.memoryPressure >= .warning else {
      return .allowed
    }
    return .deferredForMemoryPressure
  }

  /// 推論が終わった後、または端末の状態が変わったときの、ロード済みモデルの扱い
  public func retention(in state: DeviceResourceState) -> ModelRetention {
    // Mac 全体の安定性を優先し、メモリ圧迫時はどのモードでも解放する。
    // 高負荷モデルのロードを抑止する条件（loadDecision）とそろえ、圧迫中にロード済みのモデルを残さない
    guard state.memoryPressure == .normal else {
      return .releaseNow
    }
    switch effectiveMode {
    case .powerSaving:
      return .releaseNow
    case .balanced:
      guard !state.isBatteryLow else {
        return .releaseNow
      }
      return .keep(for: balancedRetention)
    case .performance:
      return .keepUntilStateChanges
    }
  }

  /// 高速モードの許可がなければバランスモードとして扱う
  public var effectiveMode: ModelRetentionMode {
    mode == .performance && !performanceRetentionAllowed ? .balanced : mode
  }
}

public enum ModelRetentionPolicyError: Error, Hashable, Sendable {
  case nonPositiveRetention
}
