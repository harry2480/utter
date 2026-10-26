import Foundation

/// 除外アプリの一覧に追加できる、起動中のアプリ（7章, AC-12）。
///
/// 画面は `NSWorkspace.runningApplications` から `RunningApp` を作って渡す。絞り込みと並べ替えはここで行い、テストする。
struct ExcludedAppCandidate: Hashable, Sendable, Identifiable {
  let bundleID: String
  /// 画面に出す名前。取れなければ bundle ID
  let name: String

  var id: String { bundleID }

  /// 起動中のアプリの情報（`NSRunningApplication` の値）
  struct RunningApp: Hashable, Sendable {
    let bundleID: String?
    let name: String?
    /// Dock に出る通常のアプリか（`activationPolicy == .regular`）。常駐・背景のプロセスは候補にしない
    let isRegular: Bool
  }

  /// 起動中のアプリのうち、bundle ID を持つ通常のアプリで、自分自身・一覧に入っているアプリを除いたもの。
  /// 名前順（同じ名前は bundle ID 順）に並べ、同じアプリ（大文字・小文字の違いを含む）は1つにする
  static func candidates(
    from running: [RunningApp], ownBundleID: String?, form: SettingsForm
  ) -> [ExcludedAppCandidate] {
    var seen: Set<String> = []
    if let ownBundleID { seen.insert(ownBundleID.lowercased()) }
    var candidates: [ExcludedAppCandidate] = []
    for app in running where app.isRegular {
      guard let bundleID = app.bundleID, SettingsForm.isPlausibleBundleID(bundleID),
        !form.containsExcludedApp(bundleID), seen.insert(bundleID.lowercased()).inserted
      else { continue }
      let name = app.name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
      candidates.append(ExcludedAppCandidate(bundleID: bundleID, name: name))
    }
    return candidates.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
    }
  }
}
