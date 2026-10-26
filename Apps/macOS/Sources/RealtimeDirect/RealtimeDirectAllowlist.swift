import Foundation
import UtterText

/// Realtime Direct を使ってよいアプリの許可リスト（2.2節, AC-15）。
///
/// 安全な範囲追跡と Undo が実機で確認されたアプリ（docs/挿入互換性表.md に Realtime Direct の列を足して記録する）だけを入れる。
/// Phase 0（#41）の判定前のため、確認済みのアプリはない（`verified` は空）。リストにないアプリは
/// `RealtimeDirectAppSupport.unsupported` になり、Realtime Direct は自動的に無効になる（AC-15）。
///
/// 実機での確認のため、Debug ビルドでだけ起動引数でアプリを足せる（`launchConfigured(arguments:)`）。
struct RealtimeDirectAllowlist: Hashable, Sendable {
  /// bundle ID（小文字）ごとの対応状況
  private let supports: [String: RealtimeDirectAppSupport]

  init(supports: [String: RealtimeDirectAppSupport] = [:]) {
    self.supports = Dictionary(
      supports.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
  }

  /// 互換性表で範囲追跡と Undo を確認したアプリ。#41 の判定待ちのため空
  static let verified = RealtimeDirectAllowlist()

  /// 前面アプリの対応状況。特定できない・リストにないアプリは未対応
  func support(for app: String?) -> RealtimeDirectAppSupport {
    app.flatMap { supports[$0.lowercased()] } ?? .unsupported
  }

  /// 対応するアプリの bundle ID（小文字）
  var apps: Set<String> {
    Set(supports.keys)
  }

  /// `apps` を範囲追跡と Undo を確認済みとして足したリスト
  func adding(_ apps: [String]) -> RealtimeDirectAllowlist {
    var supports = supports
    for app in apps {
      supports[app.lowercased()] = RealtimeDirectAppSupport(tracksRange: true, supportsUndo: true)
    }
    return RealtimeDirectAllowlist(supports: supports)
  }
}

#if DEBUG
  extension RealtimeDirectAllowlist {
    /// Debug ビルドで許可リストに足すアプリを渡す起動引数（カンマ区切りの bundle ID）。
    ///
    /// 例: `-UtterRealtimeDirectDebugApps com.apple.TextEdit,com.apple.Notes`
    static let debugAppsArgument = "-UtterRealtimeDirectDebugApps"

    /// 起動引数から足すアプリ。引数がない・値がない場合は空
    static func debugApps(arguments: [String]) -> [String] {
      guard let index = arguments.firstIndex(of: debugAppsArgument),
        arguments.indices.contains(index + 1)
      else { return [] }
      return arguments[index + 1].split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }
  }
#endif

extension RealtimeDirectAllowlist {
  /// 起動時に使う許可リスト。Release ビルドでは `verified` だけで、起動引数では足せない。
  static func launchConfigured(arguments: [String] = ProcessInfo.processInfo.arguments)
    -> RealtimeDirectAllowlist
  {
    #if DEBUG
      verified.adding(debugApps(arguments: arguments))
    #else
      verified
    #endif
  }
}
