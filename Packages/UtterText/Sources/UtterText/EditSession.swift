import UtterCore

/// Edit Mode の1回分の編集（AC-14, 2.2節）。
///
/// 選択テキストを受け取り、編集案の差分プレビュー → 確定またはキャンセル → 確定後の復元、の順に進む。
/// 確定後も選択テキストを保持し、復元（Undo）に使う。値型で、選択範囲の取得や入力欄の書き換えは行わない。
///
/// ```
/// awaitingProposal ──propose──▶ reviewing ──commit──▶ committed ──restore──▶ restored
///        │                       │  ▲ propose                │
///        └──────cancel───────────┴──┴──────cancel──▶ cancelled
/// ```
public struct EditSession: Hashable, Sendable {
  /// 編集の段階。
  public enum State: Hashable, Sendable {
    /// 編集案を待っている
    case awaitingProposal
    /// 編集案の差分を確認している
    case reviewing(EditProposal)
    /// 編集案で確定した
    case committed(EditProposal)
    /// 確定せずに終えた
    case cancelled
    /// 確定した編集を元に戻した
    case restored

    public var kind: Kind {
      switch self {
      case .awaitingProposal: .awaitingProposal
      case .reviewing: .reviewing
      case .committed: .committed
      case .cancelled: .cancelled
      case .restored: .restored
      }
    }

    /// 本文を持たない段階の種類（エラーや診断に使う）。
    public enum Kind: Hashable, Sendable, CaseIterable {
      case awaitingProposal
      case reviewing
      case committed
      case cancelled
      case restored
    }
  }

  /// 状態を進める操作。
  public enum Action: Hashable, Sendable, CaseIterable {
    case propose
    case commit
    case cancel
    case restore
    case prepareCloudTransmission
  }

  /// 編集の対象として選択されたテキスト
  public let selection: String
  public private(set) var state: State
  public let differ: TextDiffer

  /// 空の選択は編集の対象にできない。
  public init(selection: String, differ: TextDiffer = TextDiffer()) throws(EditSessionError) {
    guard !selection.isEmpty else { throw .emptySelection }
    self.selection = selection
    self.differ = differ
    state = .awaitingProposal
  }

  /// キャンセルまたは復元で終わり、以降の操作を受け付けない段階か。確定後は復元できるため含まない。
  public var isFinished: Bool {
    switch state.kind {
    case .cancelled, .restored: true
    case .awaitingProposal, .reviewing, .committed: false
    }
  }

  /// 編集案を受け取り、選択テキストとの差分を求めて確認待ちにする。
  ///
  /// 確認中に別の編集案を受け取った場合は置き換える（音声指示のやり直し）。
  /// 空の編集案は選択テキストの削除として扱い、確定するまで反映しない。
  public mutating func propose(_ editedText: String) throws(EditSessionError) {
    switch state {
    case .awaitingProposal, .reviewing:
      state = .reviewing(
        EditProposal(text: editedText, diff: differ.diff(from: selection, to: editedText)))
    case .committed, .cancelled, .restored:
      throw .invalidTransition(from: state.kind, action: .propose)
    }
  }

  /// 確認中の編集案で確定し、選択範囲を置き換えるテキストを返す。
  public mutating func commit() throws(EditSessionError) -> String {
    guard case .reviewing(let proposal) = state else {
      throw .invalidTransition(from: state.kind, action: .commit)
    }
    state = .committed(proposal)
    return proposal.text
  }

  /// 確定せずに終える。選択範囲は変更しない。
  public mutating func cancel() throws(EditSessionError) {
    switch state {
    case .awaitingProposal, .reviewing:
      state = .cancelled
    case .committed, .cancelled, .restored:
      throw .invalidTransition(from: state.kind, action: .cancel)
    }
  }

  /// 確定した編集を元に戻すための置き換え内容を返す（Undo）。一度だけ行える。
  ///
  /// 呼び出し側は、入力欄の該当範囲が `EditRestoration.expectedText` のままであることを確かめてから
  /// `replacement` に置き換える。確定後に利用者が書き換えていた場合は置き換えない。
  public mutating func restore() throws(EditSessionError) -> EditRestoration {
    guard case .committed(let proposal) = state else {
      throw .invalidTransition(from: state.kind, action: .restore)
    }
    state = .restored
    return EditRestoration(expectedText: proposal.text, replacement: selection)
  }

  /// 選択テキストをクラウド AI へ送るための内容を用意する（2.2節, 7章, AC-06）。
  ///
  /// 音声入力の整形（`textRefinement`）への同意とは別に、送信先ごとの `editSelection` への同意が必要。
  /// 送信はこの値を受け取る側が行い、送信の直前に最新の同意状態でこの関数を呼び直す。
  /// 確定前（編集案の待機中・確認中）に限る。
  public func cloudTransmission(
    to provider: CloudAIProviderKind, consent: ConsentState
  ) throws(EditSessionError) -> EditSelectionTransmission {
    switch state {
    case .awaitingProposal, .reviewing:
      break
    case .committed, .cancelled, .restored:
      throw .invalidTransition(from: state.kind, action: .prepareCloudTransmission)
    }
    guard consent.allows(.editSelection(provider)) else {
      throw .transmissionNotConsented(provider)
    }
    return EditSelectionTransmission(provider: provider, selection: selection)
  }
}

/// 編集案と、選択テキストとの差分。
public struct EditProposal: Hashable, Sendable {
  /// 選択範囲を置き換えるテキスト
  public let text: String
  /// 選択テキストから `text` への差分
  public let diff: TextDiff
}

/// 確定した編集を元に戻すための置き換え内容。
public struct EditRestoration: Hashable, Sendable {
  /// 置き換える前に入力欄の該当範囲にあるはずのテキスト（確定したテキスト）
  public let expectedText: String
  /// 戻す先のテキスト（元の選択テキスト）
  public let replacement: String
}

/// 同意を確認したうえで、選択テキストをクラウド AI へ送るための内容（AC-06）。
///
/// `EditSession.cloudTransmission(to:consent:)` からしか作れないため、
/// これを受け取る送信経路は `editSelection` への同意なしには呼び出せない。
public struct EditSelectionTransmission: Hashable, Sendable {
  /// 同意済みの送信先
  public let provider: CloudAIProviderKind
  /// 送信する選択テキスト。指示ではなく編集対象のデータとして扱う
  public let selection: String

  fileprivate init(provider: CloudAIProviderKind, selection: String) {
    self.provider = provider
    self.selection = selection
  }
}

/// 編集の操作エラー。選択テキストや編集案を含めない。
public enum EditSessionError: Error, Hashable, Sendable {
  /// 選択テキストが空
  case emptySelection
  /// その段階では行えない操作
  case invalidTransition(from: EditSession.State.Kind, action: EditSession.Action)
  /// 送信先への選択テキストの送信に同意していない
  case transmissionNotConsented(CloudAIProviderKind)
}

// 選択テキストや編集案をログに出さないよう、文字列表現とリフレクションには段階と文字数だけを出す。
extension EditSession: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditSession(state: \(state.kind), selectionLength: \(selection.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["state": state.kind, "selectionLength": selection.count])
  }
}

extension EditSession.State: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "\(kind)"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["kind": kind])
  }
}

extension EditProposal: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditProposal(length: \(text.count), diff: \(diff))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["length": text.count, "diff": diff])
  }
}

extension EditRestoration: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditRestoration(expectedLength: \(expectedText.count), replacementLength: \(replacement.count))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["expectedLength": expectedText.count, "replacementLength": replacement.count])
  }
}

extension EditSelectionTransmission: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditSelectionTransmission(provider: \(provider), length: \(selection.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["provider": provider, "length": selection.count])
  }
}
