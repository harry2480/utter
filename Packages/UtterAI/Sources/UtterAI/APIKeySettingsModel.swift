import Observation

/// API キーの設定画面の状態と操作（AC-12）。画面（SwiftUI）と保存先の本番実装は各アプリが持つ。
///
/// - 保存済みのキーは画面に再表示しない。状態は `load()` で確かめ、読めない値（壊れた値など）は
///   `unavailable` として示す（整形時に黙って失敗し続けないため）
/// - 入力は保存に成功したら消す。画面を閉じるときも `clearInput()` で消す
/// - 入力の前後の空白・改行は取り除いて保存し、空・空白だけの入力は保存しない（`APIKey`）
@MainActor
@Observable
public final class APIKeySettingsModel {
  /// 保存の状態
  public enum Status: Hashable, Sendable {
    case notSaved
    case saved
    /// 保存先を確かめられないか、保存されている値を読めない
    case unavailable(APIKeyStoreError)
  }

  /// 直前の操作の結果
  public enum Feedback: Hashable, Sendable {
    case saved
    case deleted
    case invalidInput(APIKeyValidationError)
    case saveFailed(APIKeyStoreError)
    case deleteFailed(APIKeyStoreError)
  }

  /// 入力欄の値。表示・ログには使わない
  public var input = ""
  /// 保存の状態。`refresh()` を呼ぶまでは `nil`
  public private(set) var status: Status?
  public private(set) var feedback: Feedback?

  @ObservationIgnored private let store: any APIKeyStore

  public init(store: any APIKeyStore) {
    self.store = store
  }

  /// 前後の空白・改行・制御文字以外の入力があれば保存できる（`APIKey` と同じ基準）。
  public var canSave: Bool {
    input.unicodeScalars.contains { !APIKey.isTrimmable($0) }
  }

  /// 保存済みとして削除できる。
  public var canDelete: Bool { status == .saved }

  /// 保存の状態を確かめ直す。
  public func refresh() {
    do {
      status = try store.load() == nil ? .notSaved : .saved
    } catch {
      status = .unavailable(error)
    }
  }

  /// 入力を検証して保存する。失敗したら入力を残し、保存済みのキーは変えない。
  public func save() {
    let key: APIKey
    do {
      key = try APIKey(input)
    } catch {
      feedback = .invalidInput(error)
      return
    }
    do {
      try store.save(key)
    } catch {
      feedback = .saveFailed(error)
      return
    }
    input = ""
    status = .saved
    feedback = .saved
  }

  /// 保存済みのキーを削除する。
  public func delete() {
    do {
      try store.delete()
    } catch {
      feedback = .deleteFailed(error)
      refresh()
      return
    }
    status = .notSaved
    feedback = .deleted
  }

  /// 入力と直前の結果を消す（画面を閉じるとき）。
  public func clearInput() {
    input = ""
    feedback = nil
  }
}

// 入力中のキーを出さないよう、文字列表現とリフレクションには状態だけを出す。
extension APIKeySettingsModel: CustomStringConvertible, CustomReflectable {
  public nonisolated var description: String { "APIKeySettingsModel" }
  public nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}
