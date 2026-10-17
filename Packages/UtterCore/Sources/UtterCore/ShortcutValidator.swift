/// ショートカット割当の検証と競合検出（REC-01, REC-02）。OS の登録処理は持たない純粋なロジック。
public struct ShortcutValidator: Hashable, Sendable {
  public let capabilities: ShortcutCapabilities

  public init(capabilities: ShortcutCapabilities) {
    self.capabilities = capabilities
  }

  /// `candidate` を `bindingID` として割り当てるときの問題を返す。空なら割り当てられる。
  ///
  /// `registered` のうち `bindingID` と同じ ID の割当は置き換え対象とみなし、比較しない。
  public func issues(
    for candidate: KeyCombination,
    bindingID: String,
    registered: [ShortcutBinding]
  ) -> [ShortcutValidationIssue] {
    var issues: [ShortcutValidationIssue] = []
    if candidate.isModifierOnly && !capabilities.supportsModifierOnly {
      issues.append(.modifierOnlyUnsupported)
    }
    if candidate == .escape {
      issues.append(.reservedForCancel)
    }
    for binding in registered where binding.id != bindingID {
      if let kind = Self.conflictKind(candidate, binding.combination) {
        issues.append(.conflict(bindingID: binding.id, kind: kind))
      }
    }
    return issues
  }

  /// 2つの組み合わせの競合の種類。競合しなければ `nil`。
  ///
  /// 修飾キー単独の組み合わせは、その修飾キーをすべて含む別の組み合わせを押す途中でも成立し得るため、
  /// 重複とみなす（どちらで判定するかは Phase 0 の実装方式に依存するため、安全側に倒す）。
  public static func conflictKind(_ lhs: KeyCombination, _ rhs: KeyCombination)
    -> ShortcutConflictKind?
  {
    if lhs == rhs {
      return .identical
    }
    if lhs.isModifierOnly && rhs.modifiers.isSuperset(of: lhs.modifiers) {
      return .modifierOverlap
    }
    if rhs.isModifierOnly && lhs.modifiers.isSuperset(of: rhs.modifiers) {
      return .modifierOverlap
    }
    return nil
  }
}

/// ショートカットを割り当てられない理由。
public enum ShortcutValidationIssue: Hashable, Sendable {
  /// 修飾キー単独の割当に対応していない
  case modifierOnlyUnsupported
  /// セッション中のキャンセル（Esc）に予約されている
  case reservedForCancel
  /// 登録済みの割当と競合する
  case conflict(bindingID: String, kind: ShortcutConflictKind)
}

public enum ShortcutConflictKind: Hashable, Sendable {
  /// 同じ組み合わせ
  case identical
  /// 一方が修飾キー単独で、もう一方がその修飾キーをすべて含む
  case modifierOverlap
}
