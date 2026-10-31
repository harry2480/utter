// #233 の待機セッション方式の試作（Phase i0 検証）。本番コードではない。
// 本体アプリとキーボード拡張の両方にコンパイルされる。
// App Group に置くのは、合図・本体アプリの状態・時刻だけの計測記録と、整形後の本文（共有結果）だけ。
// 音声は置かない。計測記録に発話本文を入れない（iOS-IPC-04）。

import Foundation
import UtterCore
import UtterPersistence

/// キーボードから本体アプリへの合図。正は App Group のファイルで、Darwin 通知は「読み直して」のヒント。
struct VoiceCommand: Codable, Sendable, Equatable {
  enum Action: String, Codable, Sendable {
    case start
    case stop
  }

  /// 単調に増える番号（ミリ秒の時刻）。本体アプリは処理済みより大きいものだけを扱う
  let sequence: Int64
  let action: Action
  let sessionID: SessionID
  let issuedAt: Date
}

/// 本体アプリの状態。キーボードは待機中か・結果ができたかをこれで判断する。
struct VoiceHostState: Codable, Sendable, Equatable {
  enum Phase: String, Codable, Sendable {
    /// 待機していない
    case off
    /// 待機中（合図を待っている）
    case standby
    /// 録音中
    case recording
    /// 認識・整形中
    case processing
    /// 結果を共有結果に保存した
    case done
    /// 失敗した（理由は `detail`）
    case failed
  }

  let phase: Phase
  let sessionID: SessionID?
  /// 本体アプリが最後に書いた時刻。待機中は数秒ごとに更新する（古ければ本体アプリが止まっている）
  let updatedAt: Date
  /// 失敗の理由など（発話本文は入れない）
  let detail: String?

  /// 待機中とみなす、更新の新しさの上限
  static let heartbeatTimeout: TimeInterval = 8

  func isAlive(at now: Date) -> Bool {
    phase != .off && now.timeIntervalSince(updatedAt) <= Self.heartbeatTimeout
  }
}

/// 録音中の音量（波形の表示用）。直近の数個の値だけで、音声そのものは置かない。
struct VoiceLevel: Codable, Sendable {
  let sessionID: SessionID
  /// 0〜1 に正規化した音量。古い順
  let levels: [Float]
  let at: Date
}

/// 計測の記録（1行1件）。時刻と区間名だけで、発話本文は入れない。
struct VoiceEvent: Codable, Sendable {
  let at: Date
  let source: String
  let name: String
  let sessionID: SessionID?
  let detail: String?
}

enum VoiceStoreError: Error {
  case containerUnavailable
}

/// App Group 上の待機セッションのファイル。
enum VoiceStore {
  static let commandFileName = "voice-command.json"
  static let hostStateFileName = "voice-host.json"
  static let eventsFileName = "voice-events.jsonl"
  static let levelFileName = "voice-level.json"

  static func directoryURL() throws -> URL {
    guard let container = ProbeStore.containerURL() else {
      throw VoiceStoreError.containerUnavailable
    }
    let url = container.appending(
      path: "\(ProbeConfig.directoryName)/Voice", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// 本体アプリとキーボードが使う共有結果の置き場。utter 本体の共有結果とは分ける
  static func resultStore() -> SharedResultStore? {
    guard let directory = try? directoryURL().appending(path: "SharedResults") else { return nil }
    return SharedResultStore(directory: directory)
  }

  static func write<Value: Encodable>(_ value: Value, to fileName: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    try data.write(
      to: directoryURL().appending(path: fileName),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func read<Value: Decodable>(_ type: Value.Type, from fileName: String) -> Value? {
    guard let url = try? directoryURL().appending(path: fileName),
      let data = try? Data(contentsOf: url)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
  }

  /// 計測の記録を1行追記する。書けなくても（フルアクセスなしなど）動作は止めない
  @discardableResult
  static func appendEvent(
    source: String, name: String, sessionID: SessionID? = nil, detail: String? = nil
  ) -> Bool {
    let event = VoiceEvent(
      at: Date(), source: source, name: name, sessionID: sessionID, detail: detail)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      // ミリ秒まで残す（区間の計測に使う）
      try container.encode(date.timeIntervalSince1970)
    }
    guard var line = try? encoder.encode(event),
      let url = try? directoryURL().appending(path: eventsFileName)
    else { return false }
    line.append(0x0A)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        return true
      } catch {
        return false
      }
    }
    return (try? line.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication))
      != nil
  }

  static func eventsData() -> Data? {
    guard let url = try? directoryURL().appending(path: eventsFileName) else { return nil }
    return try? Data(contentsOf: url)
  }

  static func clearEvents() {
    guard let url = try? directoryURL().appending(path: eventsFileName) else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

/// プロセスをまたぐ「読み直して」の合図（Darwin 通知）。中身は運ばない。欠落・重複・遅延を前提にする。
enum VoiceSignal: String, CaseIterable, Sendable {
  /// キーボードが合図のファイルを書いた
  case command = "com.harry2480.keyboardprobe.voice.command"
  /// 本体アプリが状態のファイルを書いた
  case hostState = "com.harry2480.keyboardprobe.voice.host"

  /// 受け取ったら、メインスレッドでこの名前の NotificationCenter 通知を出す
  var localName: Notification.Name { Notification.Name(rawValue) }

  func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue as CFString), nil,
      nil,
      true)
  }

  /// Darwin 通知を受けたら NotificationCenter へ転送する。プロセスで1回だけ呼ぶ
  static func startForwarding() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    for signal in allCases {
      CFNotificationCenterAddObserver(
        center, nil,
        { _, _, name, _, _ in
          guard let raw = name?.rawValue as String? else { return }
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name(raw), object: nil)
          }
        }, signal.rawValue as CFString, nil, .deliverImmediately)
    }
  }
}
