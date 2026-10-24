import Foundation

/// ビルド設定（Info.plist）から読む、キーボード拡張の設定。
///
/// どちらも Phase i0 の判定待ちで、既定（`Config/Base.xcconfig`）では空になり無効。
/// - App Group（#56）: `Config/Local.xcconfig` で `UTTER_APP_GROUP_ENABLED = YES` と `UTTER_APP_GROUP_ID` を設定したときだけ入る
/// - 本体アプリを開く URL スキーム（#53）: `UTTER_HOST_APP_URL_SCHEME` を設定したときだけ入る。本体アプリが登録した自アプリの
///   スキームだけを使う（他アプリのスキームや非公開 API は使わない, iOS-03）
struct KeyboardConfiguration {
  /// App Group ID。設定していなければ `nil`（共有結果を読まない）
  let appGroupID: String?
  /// 本体アプリを開く URL。設定していなければ `nil`（手動で切り替える案内だけを出す）
  let hostAppURL: URL?

  static let appGroupIDKey = "UtterAppGroupID"
  static let hostAppURLSchemeKey = "UtterHostAppURLScheme"

  init(bundle: Bundle = .main) {
    appGroupID = Self.nonEmptyString(bundle.object(forInfoDictionaryKey: Self.appGroupIDKey))
    hostAppURL = Self.nonEmptyString(bundle.object(forInfoDictionaryKey: Self.hostAppURLSchemeKey))
      .flatMap { URL(string: "\($0)://") }
  }

  /// 空と、ビルド設定が展開されずに残った値（`$(...)`）は設定なしとして扱う
  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces),
      !string.isEmpty, !string.hasPrefix("$(")
    else {
      return nil
    }
    return string
  }
}
