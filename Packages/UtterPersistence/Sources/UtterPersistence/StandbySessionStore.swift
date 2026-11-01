import Foundation
import UtterCore

/// 待機セッション（iOS-04, #247）の合図・本体アプリの状態・キーボードの生存の印を App Group に置く。
///
/// それぞれ1つのファイルを丸ごと書き換えるだけで、書くプロセスは値ごとに1つ（合図と生存の印はキーボード、
/// 状態は本体アプリ）に決まっているため、比較交換はせず、書き込みはアトミックに行う。
/// 読む側は、ファイルを正とし、プロセス間の通知を読み直しのきっかけにだけ使う。
public actor StandbySessionStore {
  private let directory: URL
  private let fileProtection: SharedResultFileProtection

  private static let commandFileName = "command.json"
  private static let hostStateFileName = "host.json"
  private static let heartbeatFileName = "keyboard-heartbeat.json"

  /// App Group 経由のディレクトリを使用して初期化する。コンテナを取得できなければ `nil`
  public init?(
    groupIdentifier: String,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier)
    else {
      return nil
    }
    self.init(
      directory: url.appendingPathComponent("StandbySession"), fileProtection: fileProtection)
  }

  /// 保存先のディレクトリを指定して初期化する（テストでは一時ディレクトリを渡す）
  public init(
    directory: URL,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    self.directory = directory
    self.fileProtection = fileProtection
  }

  // MARK: 合図（キーボードが書き、本体アプリが読む）

  /// 前の合図の次の番号で合図を書き、書いた合図を返す
  /// - Throws: 読み書きできなければ `SharedResultStoreError.fileAccessDenied`
  @discardableResult
  public func issueCommand(
    _ action: StandbyCommand.Action, sessionID: SessionID, at now: Date
  ) throws -> StandbyCommand {
    // 前の合図が壊れていても、新しい合図は時刻を元にした番号で書ける
    let previous = try? loadCommand()
    let command = StandbyCommand.next(
      after: previous, action: action, sessionID: sessionID, at: now)
    try write(command, to: Self.commandFileName)
    return command
  }

  /// 最後に書かれた合図。なければ `nil`
  public func loadCommand() throws -> StandbyCommand? {
    try read(StandbyCommand.self, from: Self.commandFileName)
  }

  // MARK: 本体アプリの状態（本体アプリが書き、キーボードが読む）

  public func saveHostState(_ state: StandbyHostState) throws {
    try write(state, to: Self.hostStateFileName)
  }

  public func loadHostState() throws -> StandbyHostState? {
    try read(StandbyHostState.self, from: Self.hostStateFileName)
  }

  // MARK: 生存の印（キーボードが書き、本体アプリが読む）

  public func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) throws {
    try write(heartbeat, to: Self.heartbeatFileName)
  }

  public func loadHeartbeat() throws -> KeyboardHeartbeat? {
    try read(KeyboardHeartbeat.self, from: Self.heartbeatFileName)
  }

  // MARK: ファイル

  private func write(_ value: some Encodable, to fileName: String) throws {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(value)
      try data.write(
        to: directory.appendingPathComponent(fileName),
        options: [.atomic, fileProtection.writingOption])
    } catch let error as CocoaError
      where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission
    {
      throw SharedResultStoreError.fileAccessDenied
    }
  }

  /// - Throws: 読めなければ `SharedResultStoreError.fileAccessDenied`、復号できなければ
  ///   `SharedResultStoreError.corruptedResult`
  private func read<Value: Decodable>(_ type: Value.Type, from fileName: String) throws -> Value? {
    let data: Data
    do {
      data = try Data(contentsOf: directory.appendingPathComponent(fileName))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
    guard let value = try? JSONDecoder().decode(type, from: data) else {
      throw SharedResultStoreError.corruptedResult
    }
    return value
  }
}
