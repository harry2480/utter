import Foundation
import UtterCore

/// キーボード拡張が入力欄へ本文を挿入する口（iOS-05）。`UITextDocumentProxy` を使う実装はキーボード拡張側に置く
public protocol SharedResultTextInserter: Sendable {
  /// 本文を挿入する。挿入できたことを確認できなければ `.unknown` を返す
  func insert(_ text: String) async -> SharedResultInsertionConfirmation
}

/// 挿入を確認できたか
public enum SharedResultInsertionConfirmation: Hashable, Sendable {
  case confirmed
  /// 挿入を試みたが、入力欄に入ったかを確認できない
  case unknown
}

/// 挿入前に画面へ出す内容（iOS-05, iAC-04）
public enum SharedResultPreview: Hashable, Sendable {
  /// 待っているセッションの結果がない
  case notFound
  /// 挿入できる。本文を表示し、利用者の明示的な挿入操作を待つ
  case insertable(text: String)
  /// 挿入結果が不明。自動では再挿入せず、本文を見せて再挿入するか利用者に確認する（iOS-IPC-03）
  case needsConfirmation(text: String)
  /// 挿入できない（期限切れ・挿入済み・挿入中など）
  case notInsertable(SharedResultInsertability)
}

/// 挿入操作の結果
public enum SharedResultInsertionOutcome: Hashable, Sendable {
  /// 挿入し、挿入済みを記録した
  case inserted
  /// 挿入を試みたが確認できなかった。次の表示では再挿入の確認を出す
  case insertionUnknown
  /// 挿入しなかった
  case notInserted(SharedResultInsertability)
  /// 待っているセッションの結果がない
  case notFound
}

// 本文をログに出さないよう、文字列表現には区分と文字数だけを出す。
extension SharedResultPreview: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notFound: "SharedResultPreview.notFound"
    case .insertable(let text): "SharedResultPreview.insertable(length: \(text.count))"
    case .needsConfirmation(let text):
      "SharedResultPreview.needsConfirmation(length: \(text.count))"
    case .notInsertable(let reason): "SharedResultPreview.notInsertable(\(reason))"
    }
  }
}

/// キーボード拡張で、共有結果のプレビューと明示的な挿入を行う（iOS-05, iOS-IPC-03, iOS-IPC-05, iAC-04）。
///
/// 挿入の前に `inserting` を比較交換で保存して確保するため、連打・キーボードの再生成・本体アプリとの同時操作でも
/// 1回しか挿入しない。挿入を確認できなければ `insertionUnknown` を記録し、自動では再挿入しない。
/// 挿入後の記録が別プロセスの更新（整理で `insertionUnknown` にされた等）と競合したら、読み直して記録し直す。
/// 挿入済みを記録した結果と、期限切れの結果は削除し、共有テキストを残さない。
///
/// 前提: 本体アプリは削除したセッションIDで結果を作り直さない（セッションごとに新しい ID を使う）。
public actor SharedResultInsertionCoordinator {
  private let store: SharedResultStore
  private let inserter: any SharedResultTextInserter
  private let now: @Sendable () -> Date

  /// 挿入後の記録で比較交換が競合したときに読み直す回数の上限
  static let maxRecordAttempts = 3

  public init(
    store: SharedResultStore,
    inserter: any SharedResultTextInserter,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.inserter = inserter
    self.now = now
  }

  /// 待っているセッションの結果を、挿入前に表示する内容にする。期限切れの結果はこのとき削除する
  public func preview(sessionID: SessionID) async throws -> SharedResultPreview {
    guard let result = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    switch result.insertability(for: sessionID, at: now()) {
    case .insertable:
      return .insertable(text: result.text)
    case .needsConfirmation:
      return .needsConfirmation(text: result.text)
    case .expired:
      // 挿入に使えないため、共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
      try? await store.delete(sessionID: sessionID)
      return .notInsertable(.expired)
    case let other:
      return .notInsertable(other)
    }
  }

  /// 利用者の明示的な挿入操作を受けて挿入する。
  ///
  /// 投げるのは挿入する前の読み書きに失敗した場合だけで、そのときは挿入していない。
  /// 挿入した後に記録できなくても、投げずに挿入の確認結果に応じた値を返す。
  /// - Parameter confirmedReinsertion: 挿入結果が不明な結果を、利用者が確認したうえで挿入し直す場合に `true`
  public func insert(
    sessionID: SessionID, confirmedReinsertion: Bool = false
  ) async throws -> SharedResultInsertionOutcome {
    let now = now()
    guard let loaded = try await store.load(sessionID: sessionID) else {
      return .notFound
    }
    var claimed = loaded
    do {
      // 確認つきの再挿入でも、結果がそのまま挿入できる状態なら通常の挿入として扱う
      if confirmedReinsertion, loaded.insertability(for: sessionID, at: now) != .insertable {
        try claimed.beginInsertionAfterConfirmation(for: sessionID, at: now)
      } else {
        try claimed.beginInsertion(for: sessionID, at: now)
      }
    } catch .notInsertable(let reason) {
      if reason == .expired {
        // 挿入に使えないため、共有テキストを残さない（iOS-IPC-05）。失敗しても本体アプリの整理で消える
        try? await store.delete(sessionID: sessionID)
      }
      return .notInserted(reason)
    } catch {
      return .notInserted(loaded.insertability(for: sessionID, at: now))
    }

    // 挿入する前に確保する。別の操作が先に確保していれば挿入しない
    do {
      try await store.save(claimed, expectedRevision: loaded.revision)
    } catch SharedResultStoreError.revisionConflict {
      let current = try await store.load(sessionID: sessionID)
      return current.map { .notInserted($0.insertability(for: sessionID, at: now)) } ?? .notFound
    }

    let confirmation = await inserter.insert(claimed.text)
    return await record(confirmation, for: claimed)
  }

  /// 挿入の結果を記録する。挿入はすでに済んでいるため、記録に失敗しても投げずに、挿入の確認結果に応じた値を返す。
  private func record(
    _ confirmation: SharedResultInsertionConfirmation, for claimed: SharedResult
  ) async -> SharedResultInsertionOutcome {
    await store.recordCompletion(
      of: claimed, confirmation: confirmation, maxAttempts: Self.maxRecordAttempts, now: now)
    return confirmation == .confirmed ? .inserted : .insertionUnknown
  }
}

extension SharedResultStore {
  /// `inserting` で確保した結果に、挿入（またはコピー）の結果を記録する（iOS-IPC-03, iOS-IPC-05, iOS-07）。
  ///
  /// 競合したら読み直し、挿入済みの記録を失わないようにする。挿入済みを記録した結果は削除し、共有テキストを残さない。
  /// 挿入・コピーはすでに済んでいるため、記録に失敗しても投げない（残った結果は整理で復旧する）。
  func recordCompletion(
    of claimed: SharedResult,
    confirmation: SharedResultInsertionConfirmation,
    maxAttempts: Int,
    now: @Sendable () -> Date
  ) {
    var base = claimed
    for _ in 0..<maxAttempts {
      var updated = base
      do {
        switch confirmation {
        case .confirmed:
          try updated.markConsumed(at: now())
        case .unknown:
          try updated.markInsertionUnknown()
        }
      } catch {
        // 読み直した結果が、記録できない状態（挿入済みに対する結果不明など）になっている
        return
      }
      do {
        if updated.revision != base.revision {
          try save(updated, expectedRevision: base.revision)
        }
        if case .consumed = updated.status {
          // 失敗しても本体アプリの整理で消える
          try? delete(sessionID: claimed.sessionID)
        }
        return
      } catch SharedResultStoreError.revisionConflict {
        guard let current = try? load(sessionID: claimed.sessionID) else {
          // 期限切れなどで削除された、または読めない。挿入は済んでいる
          return
        }
        base = current
      } catch {
        return
      }
    }
  }
}
