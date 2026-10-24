// Phase i0 検証用（#56, #53）。本番コードではない使い捨てのプロトタイプ。
// 本体アプリとキーボード拡張の両方にコンパイルされる。
// App Group に置くのは固定のダミー文字列だけ。発話本文・秘密情報・生音声は置かない（iOS-IPC-04）。

import Foundation

/// ビルド設定から渡される識別子と、検証で共通に使う定数。
enum ProbeConfig {
  /// Info.plist に `$(PROBE_APP_GROUP_ID)` として埋め込むキー。
  static let appGroupInfoKey = "UtterProbeAppGroupID"
  /// `Config/Probe.xcconfig` の既定値。`Local.xcconfig` で上書きしていないことの検出に使う。
  static let placeholderAppGroupID = "group.example.utter.keyboardprobe"
  /// 本体アプリが登録する URL スキーム（自アプリ専用。他アプリのスキームは使わない）。
  static let urlScheme = "utterkeyboardprobe"
  /// 共有コンテナ内でこのプローブが使うディレクトリ名。片付けはこのディレクトリごと削除する。
  static let directoryName = "UtterKeyboardProbe"
  /// 既定のダミー結果。実際の発話や個人情報を入れないこと。
  static let dummyText = "utter プローブのダミー結果"
  /// キーボード拡張が書き込みの可否を確かめるファイル。
  static let keyboardWriteFileName = "keyboard-write-test.json"

  static var appGroupID: String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
      !value.isEmpty, !value.hasPrefix("$(")
    else { return nil }
    return value
  }

  static var isPlaceholderAppGroupID: Bool {
    appGroupID == placeholderAppGroupID
  }

  static func openAppURL(via route: String) -> URL? {
    URL(string: "\(urlScheme)://from-keyboard?via=\(route)")
  }
}

/// 検証するファイル保護クラス。クラスごとに別ファイルへ書き、拡張とロック中の読み書きを比べる。
enum ProbeProtection: String, CaseIterable, Codable, Sendable, Identifiable {
  case complete
  case completeUnlessOpen
  case completeUntilFirstUserAuthentication
  case none

  var id: String { rawValue }

  var label: String {
    switch self {
    case .complete: "complete"
    case .completeUnlessOpen: "completeUnlessOpen"
    case .completeUntilFirstUserAuthentication: "completeUntilFirstUserAuthentication"
    case .none: "none"
    }
  }

  var shortLabel: String {
    switch self {
    case .complete: "C"
    case .completeUnlessOpen: "CUO"
    case .completeUntilFirstUserAuthentication: "CUFUA"
    case .none: "none"
    }
  }

  var writingOption: Data.WritingOptions {
    switch self {
    case .complete: .completeFileProtection
    case .completeUnlessOpen: .completeFileProtectionUnlessOpen
    case .completeUntilFirstUserAuthentication: .completeFileProtectionUntilFirstUserAuthentication
    case .none: .noFileProtection
    }
  }

  var resultFileName: String { "result-\(rawValue).json" }
  var lockTestFileName: String { "locktest-\(rawValue).json" }
}

/// App Group に置くダミー結果。
struct ProbePayload: Codable, Sendable {
  let text: String
  let writtenAt: Date
  let protection: ProbeProtection?
  let writer: String
}

/// 1回の操作の結果。画面表示と記録用のテキストに使う。パスや本文は含めない。
struct ProbeOutcome: Sendable, Identifiable {
  let id = UUID()
  let at: Date
  let action: String
  let target: String
  let succeeded: Bool
  let summary: String
  let detail: String?

  var line: String {
    let mark = succeeded ? "OK" : "NG"
    let detailText = detail.map { " [\($0)]" } ?? ""
    return "\(ProbeTime.format(at)) \(action) \(target): \(mark) \(summary)\(detailText)"
  }
}

enum ProbeTime {
  static func format(_ date: Date) -> String {
    date.formatted(
      .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        .secondFraction(.fractional(3)))
  }
}

/// App Group コンテナの読み書き。
enum ProbeStore {
  static func containerURL() -> URL? {
    guard let groupID = ProbeConfig.appGroupID else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
  }

  static var containerStatus: String {
    guard ProbeConfig.appGroupID != nil else {
      return "App Group ID が Info.plist にない（ビルド設定を確認）"
    }
    return containerURL() == nil
      ? "コンテナ URL を取得できない（nil）" : "コンテナ URL を取得できた"
  }

  private static func directoryURL() throws -> URL {
    guard let container = containerURL() else { throw ProbeStoreError.containerUnavailable }
    return container.appending(path: ProbeConfig.directoryName, directoryHint: .isDirectory)
  }

  static func write(
    fileName: String, text: String, protection: ProbeProtection?, writer: String,
    action: String = "書き込み"
  ) -> ProbeOutcome {
    let now = Date()
    do {
      let directory = try directoryURL()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let payload = ProbePayload(text: text, writtenAt: now, protection: protection, writer: writer)
      let data = try JSONEncoder().encode(payload)
      var options: Data.WritingOptions = [.atomic]
      if let protection { options.insert(protection.writingOption) }
      let url = directory.appending(path: fileName)
      try data.write(to: url, options: options)
      return ProbeOutcome(
        at: now, action: action, target: fileName, succeeded: true,
        summary: "書き込めた", detail: "実際の保護属性: \(protectionAttribute(of: url))")
    } catch {
      let described = ProbeErrorClassifier.describe(error)
      return ProbeOutcome(
        at: now, action: action, target: fileName, succeeded: false,
        summary: described.summary, detail: described.detail)
    }
  }

  static func read(fileName: String, action: String = "読み込み") -> (ProbeOutcome, ProbePayload?) {
    let now = Date()
    do {
      let url = try directoryURL().appending(path: fileName)
      let data = try Data(contentsOf: url)
      let payload = try JSONDecoder().decode(ProbePayload.self, from: data)
      let outcome = ProbeOutcome(
        at: now, action: action, target: fileName, succeeded: true,
        summary: "読めた（書き込み \(ProbeTime.format(payload.writtenAt)) by \(payload.writer)）",
        detail: "保護属性: \(protectionAttribute(of: url))")
      return (outcome, payload)
    } catch {
      let described = ProbeErrorClassifier.describe(error)
      let outcome = ProbeOutcome(
        at: now, action: action, target: fileName, succeeded: false,
        summary: described.summary, detail: described.detail)
      return (outcome, nil)
    }
  }

  static func delete(fileName: String) -> ProbeOutcome {
    let now = Date()
    do {
      let url = try directoryURL().appending(path: fileName)
      try FileManager.default.removeItem(at: url)
      return ProbeOutcome(
        at: now, action: "削除", target: fileName, succeeded: true, summary: "削除した", detail: nil)
    } catch {
      let described = ProbeErrorClassifier.describe(error)
      return ProbeOutcome(
        at: now, action: "削除", target: fileName, succeeded: false,
        summary: described.summary, detail: described.detail)
    }
  }

  /// 片付け用。プローブのディレクトリごと削除する。
  static func deleteAll() -> ProbeOutcome {
    let now = Date()
    do {
      try FileManager.default.removeItem(at: try directoryURL())
      return ProbeOutcome(
        at: now, action: "全削除", target: ProbeConfig.directoryName, succeeded: true,
        summary: "削除した", detail: nil)
    } catch {
      let described = ProbeErrorClassifier.describe(error)
      return ProbeOutcome(
        at: now, action: "全削除", target: ProbeConfig.directoryName, succeeded: false,
        summary: described.summary, detail: described.detail)
    }
  }

  /// 実際に付いた保護属性。属性の取得自体に失敗したらその旨を返す。
  static func protectionAttribute(of url: URL) -> String {
    do {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: url.path(percentEncoded: false))
      guard let protection = attributes[.protectionKey] as? FileProtectionType else {
        return "なし（属性が返らない）"
      }
      return protection.rawValue
    } catch {
      return "取得失敗 \(ProbeErrorClassifier.describe(error).detail)"
    }
  }
}

enum ProbeStoreError: Error {
  case containerUnavailable
}

/// エラーの種類を人が読める形にする。
/// `localizedDescription` はファイルのパスを含むため表示しない（ドメインとコードの連鎖だけを出す）。
enum ProbeErrorClassifier {
  static func describe(_ error: Error) -> (summary: String, detail: String) {
    if case ProbeStoreError.containerUnavailable = error {
      return (
        "App Group コンテナ URL を取得できない（Entitlement・署名・App Group ID を確認）",
        "containerURL == nil"
      )
    }
    let root = error as NSError
    var chain: [String] = []
    var posixCode: Int?
    var current: NSError? = root
    while let item = current {
      chain.append("\(item.domain) \(item.code)")
      if item.domain == NSPOSIXErrorDomain, posixCode == nil { posixCode = item.code }
      current = item.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    let detail = chain.joined(separator: " ← ")

    let summary: String
    if posixCode == Int(ENOENT)
      || (root.domain == NSCocoaErrorDomain && root.code == NSFileReadNoSuchFileError)
    {
      summary = "ファイルがない"
    } else if posixCode == Int(EPERM) {
      summary = "操作が許可されない（EPERM: ロック中の保護クラス、またはサンドボックスの拒否）"
    } else if posixCode == Int(EACCES) {
      summary = "アクセス拒否（EACCES）"
    } else if root.domain == NSCocoaErrorDomain
      && (root.code == NSFileReadNoPermissionError || root.code == NSFileWriteNoPermissionError)
    {
      summary = "権限がない（Cocoa の権限エラー）"
    } else if root.domain == NSCocoaErrorDomain && root.code == NSCoderReadCorruptError {
      summary = "内容を解釈できない"
    } else {
      summary = "その他のエラー"
    }
    return (summary, detail)
  }
}
