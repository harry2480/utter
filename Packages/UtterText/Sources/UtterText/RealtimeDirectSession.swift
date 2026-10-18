import UtterCore

/// 入力欄の値の中の範囲。位置と長さは UTF-16 のコード単位で数える（AX の `NSRange` / `CFRange` と同じ単位）。
///
/// 書記素クラスター（Character）の途中を指さないよう、`RealtimeDirectSession` は Character の境界から求めた範囲だけを返す。
public struct UTF16TextRange: Hashable, Sendable {
  public let location: Int
  public let length: Int
  /// 範囲の終わり（含まない）
  public let upperBound: Int

  /// 負の値や、終わりが `Int` に収まらない範囲は `nil`。読み取った範囲が不正なら、確かめられない範囲として扱う。
  public init?(location: Int, length: Int) {
    let (upperBound, overflow) = location.addingReportingOverflow(length)
    guard location >= 0, length >= 0, !overflow else { return nil }
    self.location = location
    self.length = length
    self.upperBound = upperBound
  }

  /// 入力欄の値の中から求めた、正しいとわかっている範囲。
  init(validLocation location: Int, length: Int) {
    self.location = location
    self.length = length
    upperBound = location + length
  }
}

/// 書き込みの直前・取り消しの直前に読み取った入力欄の状態（AC-15）。アプリ側が AX などから作る。
///
/// 読み取れなかった値は `nil` にする。`nil` を含む場合、範囲を確かめられないとして書き込みをやめる。
/// 入力欄の値は照合だけに使い、送信・保存・ログ出力はしない。
public struct RealtimeDirectFieldObservation: Hashable, Sendable {
  /// フォーカスのある入力対象
  public var target: InsertionTargetID?
  /// 入力欄の値全体。書き込んだ範囲の外の変更も検出するため、範囲だけでなく全体を読む
  public var value: String?
  /// 選択範囲。選択がなければ長さ 0 のカーソル位置
  public var selectedRange: UTF16TextRange?

  public init(target: InsertionTargetID?, value: String?, selectedRange: UTF16TextRange?) {
    self.target = target
    self.value = value
    self.selectedRange = selectedRange
  }
}

/// 直接の書き込みをやめた理由（AC-09, AC-15）。
public enum RealtimeDirectStopReason: Hashable, Sendable, CaseIterable {
  /// 入力対象が見つからない
  case targetMissing
  /// フォーカスが別の入力対象に移った
  case targetChanged
  /// 入力欄が外部で変更された（値全体が、開始時の値に書き込んだテキストを挟んだものと違う）
  case fieldChanged
  /// カーソルが書き込んだ範囲の末尾から動いた、またはテキストが選択された
  case selectionMoved
  /// 入力欄の値・選択範囲を読み取れない
  case rangeUnverifiable
  /// 呼び出し側が書き込みの失敗を検出した
  case writeFailed
  /// 呼び出し側がフォーカスの変化などを検出した
  case interrupted
}

/// Realtime Direct の1セッション分の、入力欄への逐次の書き込み（2.2節, AC-15）。
///
/// 開始時のカーソル位置（`anchor`）から書き込んだテキスト（`writtenText`）を記録し、
/// 新しいテキストを受け取るたびに、書き込んだ範囲のうち置き換える部分と置き換え後の文字列を返す。
/// 書き込む前と取り消す前には、呼び出し側が読み取った入力欄の状態を記録と照合し、入力対象・値全体
/// （開始時の値の `anchor` の位置に `writtenText` を挟んだもの）・カーソル位置のどれかが合わなければ書き込みをやめる。
/// やめた後は入力欄に触れず、呼び出し側はコピー可能なプレビューへ退避する（AC-09）。
///
/// 位置はすべて UTF-16 のコード単位で、差分の区切りは Character（書記素クラスター）の境界に合わせる。
/// 結合文字や絵文字の途中で区切った置き換えはしない。値型で、入力欄の読み書きは行わない。
///
/// ```
/// writing ──finish──▶ finished
///    │ │                 │
///    │ └──────undo───────┼──▶ undone
///    │                   │
///    └─照合の失敗・stop──▶ stopped ◀─照合の失敗（undo）
/// ```
public struct RealtimeDirectSession: Hashable, Sendable {
  /// セッションの段階。
  public enum State: Hashable, Sendable {
    /// 書き込み中。新しいテキストを受け付ける
    case writing
    /// 認識を終えた。書き込みは受け付けず、取り消しだけ行える
    case finished
    /// 範囲を確かめられず、直接の書き込みをやめた。以降は入力欄に触れない
    case stopped(RealtimeDirectStopReason)
    /// 書き込んだテキストを取り除いた
    case undone

    public var kind: Kind {
      switch self {
      case .writing: .writing
      case .finished: .finished
      case .stopped: .stopped
      case .undone: .undone
      }
    }

    /// 理由を除いた段階の種類（エラーに使う）。
    public enum Kind: Hashable, Sendable, CaseIterable {
      case writing
      case finished
      case stopped
      case undone
    }
  }

  /// 状態を進める操作。
  public enum Action: Hashable, Sendable, CaseIterable {
    case update
    case finish
    case undo
  }

  /// 書き込み先の入力対象
  public let target: InsertionTargetID
  /// 書き込みを始めた位置（開始時のカーソル位置, UTF-16）
  public let anchor: Int
  /// 書き込みを始める前の入力欄の値。照合だけに使う
  let initialValue: String
  /// これまでに入力欄へ書き込んだテキスト。`anchor` から始まる
  public private(set) var writtenText = ""
  public private(set) var state = State.writing

  /// 使える条件と開始時の入力欄の状態を確かめて始める（AC-15）。
  ///
  /// 条件を満たさない場合や、入力対象・カーソル位置を確かめられない場合は、該当する理由をすべて含むエラーにする。
  /// 呼び出し側は Realtime Preview（停止後に一括挿入）で処理する。
  public init(
    requirements: RealtimeDirectRequirements, observation: RealtimeDirectFieldObservation
  ) throws(RealtimeDirectSessionError) {
    var reasons = requirements.unavailableReasons
    if observation.target == nil {
      reasons.insert(.targetUnknown)
    }
    if let value = observation.value, let selection = observation.selectedRange,
      Self.isCharacterBoundary(selection.location, in: value),
      Self.isCharacterBoundary(selection.upperBound, in: value)
    {
      if selection.length != 0 {
        reasons.insert(.selectionNotEmpty)
      }
    } else {
      reasons.insert(.fieldUnreadable)
    }
    guard reasons.isEmpty, let target = observation.target,
      let value = observation.value, let selection = observation.selectedRange
    else {
      throw .unavailable(reasons)
    }
    self.target = target
    anchor = selection.location
    initialValue = value
  }

  /// UTF-16 の位置が値の範囲内で、書記素クラスター（Character）の境界にあるか。
  private static func isCharacterBoundary(_ offset: Int, in value: String) -> Bool {
    guard offset <= value.utf16.count else { return false }
    let index = value.utf16.index(value.utf16.startIndex, offsetBy: offset)
    return index.samePosition(in: value) != nil
  }

  /// これまでに書き込んだ範囲（入力欄全体での位置）。
  public var trackedRange: UTF16TextRange {
    UTF16TextRange(validLocation: anchor, length: writtenText.utf16.count)
  }

  /// 書き込んだ範囲の末尾にあるはずのカーソル位置。
  var caretLocation: Int {
    trackedRange.upperBound
  }

  /// 入力欄に書かれているべきテキストを受け取り、次に行う書き込みを返す（2.2節）。
  ///
  /// `text` はこのセッションで書き込むテキスト全体（例: それまでの確定済みテキストの連結）で、差分ではない。
  /// 暫定の認識結果は渡さない（確定済みチャンクだけを書き込む）。完了時の全体の確定テキストのように、
  /// 書き込み済みの部分が変わったテキストも渡せる。
  ///
  /// 照合に失敗したら直接の書き込みをやめ、以降は同じ理由で `showPreview` を返す。
  /// それまでに書き込んだテキストは入力欄に残るため、呼び出し側はプレビューに全体を出す。
  /// `write` を返したら記録は書き込み後のテキストに進む。呼び出し側は書き込みに失敗したら
  /// `stop(.writeFailed)` を呼ぶ（呼ばなくても次の照合で止まる）。
  public mutating func update(
    to text: String, observation: RealtimeDirectFieldObservation
  ) throws(RealtimeDirectSessionError) -> RealtimeDirectStep {
    switch state {
    case .writing:
      break
    case .stopped(let reason):
      return .showPreview(reason)
    case .finished, .undone:
      throw .invalidTransition(from: state.kind, action: .update)
    }
    if let reason = mismatch(observation) {
      state = .stopped(reason)
      return .showPreview(reason)
    }
    guard let edit = Self.edit(anchor: anchor, from: writtenText, to: text) else {
      return .unchanged
    }
    writtenText = text
    return .write(edit)
  }

  /// 認識を終え、書き込みを締める。直接の書き込みをやめた後なら何もしない。
  public mutating func finish() throws(RealtimeDirectSessionError) {
    switch state {
    case .writing:
      state = .finished
    case .stopped:
      break
    case .finished, .undone:
      throw .invalidTransition(from: state.kind, action: .finish)
    }
  }

  /// 呼び出し側が検出した理由で直接の書き込みをやめる。書き込み中でなければ何もしない。
  public mutating func stop(_ reason: RealtimeDirectStopReason) {
    if state == .writing {
      state = .stopped(reason)
    }
  }

  /// 書き込んだテキストを取り除き、開始前の入力欄に戻すための置き換えを返す（取り消し, AC-15）。一度だけ行える。
  ///
  /// 書き込み中（セッションのキャンセル）と認識の終了後に行える。照合に失敗したら入力欄に触れずに
  /// 直接の書き込みをやめ、`unavailable` を返す。利用者が書き込み後に入力欄を変えていた場合も戻さない。
  public mutating func undo(
    observation: RealtimeDirectFieldObservation
  ) throws(RealtimeDirectSessionError) -> RealtimeDirectUndo {
    switch state {
    case .writing, .finished:
      break
    case .stopped(let reason):
      return .unavailable(reason)
    case .undone:
      throw .invalidTransition(from: state.kind, action: .undo)
    }
    if let reason = mismatch(observation) {
      state = .stopped(reason)
      return .unavailable(reason)
    }
    let edit = Self.edit(anchor: anchor, from: writtenText, to: "")
    writtenText = ""
    state = .undone
    return edit.map(RealtimeDirectUndo.revert) ?? .nothingToRevert
  }

  /// 読み取った入力欄の状態が記録と合わなければ、その理由を返す。
  private func mismatch(_ observation: RealtimeDirectFieldObservation) -> RealtimeDirectStopReason?
  {
    guard let current = observation.target else { return .targetMissing }
    guard current == target else { return .targetChanged }
    guard let value = observation.value, let selection = observation.selectedRange else {
      return .rangeUnverifiable
    }
    // 範囲の外の変更（前後での入力・同じ長さの書き換え）も検出するため、値全体を比べる。
    // アプリによる正規化（NFC など）も外部の変更として扱うため、UTF-16 のコード単位で比べる
    let initial = initialValue.utf16
    let split = initial.index(initial.startIndex, offsetBy: anchor)
    let expected = [initial[..<split], Substring(writtenText).utf16, initial[split...]].joined()
    guard value.utf16.elementsEqual(expected) else { return .fieldChanged }
    guard selection == UTF16TextRange(validLocation: caretLocation, length: 0) else {
      return .selectionMoved
    }
    return nil
  }

  /// `anchor` から書き込んだ `old` を `new` にするための置き換えを求める。変更がなければ `nil`。
  ///
  /// 共通の先頭・末尾を Character 単位で除き、残りを置き換える。Character の比較は正準等価ではなく
  /// Unicode スカラーの一致で行い、入力欄のテキストが `new` とコード単位まで一致するようにする。
  static func edit(anchor: Int, from old: String, to new: String) -> RealtimeDirectEdit? {
    var oldStart = old.startIndex
    var newStart = new.startIndex
    while oldStart < old.endIndex, newStart < new.endIndex,
      old[oldStart].unicodeScalars.elementsEqual(new[newStart].unicodeScalars)
    {
      old.formIndex(after: &oldStart)
      new.formIndex(after: &newStart)
    }
    var oldEnd = old.endIndex
    var newEnd = new.endIndex
    while oldEnd > oldStart, newEnd > newStart {
      let oldLast = old.index(before: oldEnd)
      let newLast = new.index(before: newEnd)
      guard old[oldLast].unicodeScalars.elementsEqual(new[newLast].unicodeScalars) else { break }
      oldEnd = oldLast
      newEnd = newLast
    }
    guard oldStart != oldEnd || newStart != newEnd else { return nil }

    let range = UTF16TextRange(
      validLocation: anchor + old.utf16.distance(from: old.startIndex, to: oldStart),
      length: old.utf16.distance(from: oldStart, to: oldEnd))
    return RealtimeDirectEdit(
      range: range,
      expectedText: String(old[oldStart..<oldEnd]),
      replacement: String(new[newStart..<newEnd]),
      caretLocation: anchor + new.utf16.count)
  }
}

/// 入力欄の1回の置き換え。
///
/// 呼び出し側は `range` のテキストが `expectedText` であることを照合済みのうえで `replacement` に置き換え、
/// カーソルを `caretLocation` に置く。置き換え後のカーソル位置は範囲の末尾とは限らない
/// （書き込み済みの途中だけを直す場合）。
public struct RealtimeDirectEdit: Hashable, Sendable {
  /// 置き換える範囲（入力欄全体での位置, UTF-16）
  public let range: UTF16TextRange
  /// 置き換える前に `range` にあるはずのテキスト
  public let expectedText: String
  /// 置き換え後のテキスト。空なら削除
  public let replacement: String
  /// 置き換えた後に置くカーソルの位置（UTF-16）
  public let caretLocation: Int
}

/// 新しいテキストを受け取った後に行うこと。
public enum RealtimeDirectStep: Hashable, Sendable {
  /// 入力欄を置き換える
  case write(RealtimeDirectEdit)
  /// 書き込み済みのテキストと同じで、何もしない
  case unchanged
  /// 直接の書き込みをやめ、コピー可能なプレビューへ退避する（AC-09）
  case showPreview(RealtimeDirectStopReason)
}

/// 取り消しで行うこと。
public enum RealtimeDirectUndo: Hashable, Sendable {
  /// 入力欄を置き換えて、書き込んだテキストを取り除く
  case revert(RealtimeDirectEdit)
  /// 何も書き込んでいないため、戻すものがない
  case nothingToRevert
  /// 範囲を確かめられないため、入力欄に触れない
  case unavailable(RealtimeDirectStopReason)
}

/// Realtime Direct の操作エラー。入力欄のテキストを含めない。
public enum RealtimeDirectSessionError: Error, Hashable, Sendable {
  /// 使えない。該当する理由をすべて含む
  case unavailable(Set<RealtimeDirectUnavailableReason>)
  /// その段階では行えない操作
  case invalidTransition(
    from: RealtimeDirectSession.State.Kind, action: RealtimeDirectSession.Action)
}

// 発話本文をログに出さないよう、文字列表現とリフレクションには段階・位置・文字数だけを出す。
extension RealtimeDirectSession: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RealtimeDirectSession(state: \(state), trackedRange: \(trackedRange))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["state": state, "trackedRange": trackedRange])
  }
}

extension RealtimeDirectFieldObservation: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RealtimeDirectFieldObservation(target: \(target.map(String.init(describing:)) ?? "nil"), "
      + "valueLength: \(value.map { String($0.utf16.count) } ?? "nil"), "
      + "selectedRange: \(selectedRange.map(String.init(describing:)) ?? "nil"))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

extension RealtimeDirectEdit: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RealtimeDirectEdit(range: \(range), replacementLength: \(replacement.utf16.count), "
      + "caretLocation: \(caretLocation))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "range": range, "replacementLength": replacement.utf16.count,
        "caretLocation": caretLocation,
      ])
  }
}

extension RealtimeDirectStep: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .write(let edit): "write(\(edit))"
    case .unchanged: "unchanged"
    case .showPreview(let reason): "showPreview(\(reason))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

extension RealtimeDirectUndo: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .revert(let edit): "revert(\(edit))"
    case .nothingToRevert: "nothingToRevert"
    case .unavailable(let reason): "unavailable(\(reason))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
