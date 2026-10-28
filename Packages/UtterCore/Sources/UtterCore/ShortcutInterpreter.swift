/// グローバルショートカットの押下・解放と Esc を、セッションへの操作に変換する（REC-01, REC-02, REC-06）。
///
/// 状態は `SessionStateMachine` が持ち、ここは現在の `SessionPhase` を受け取って操作を決めるだけにする。
/// 返した `ShortcutCommand` は、アプリが状態機械の対応する API で実行する。
///
/// | 操作 | 状態機械の API |
/// |---|---|
/// | `startRecording` | `start(at:)` |
/// | `stopRecording` | `stopRecording(at:)` |
/// | `cancelSession` | `cancel()` |
/// | `confirmCancel` | キャンセルするかを利用者に確かめ、キャンセルを選んだら `cancel()` |
///
/// 値型なので、利用側は状態機械と同じく `@MainActor` や `actor` に隔離して保持する。
public struct ShortcutInterpreter: Hashable, Sendable {
  /// 録音の操作方式。変更すると Push-to-talk の押下中の状態を破棄する。
  public var mode: ShortcutTriggerMode {
    didSet {
      if mode != oldValue { pushToTalkOwnsRecording = false }
    }
  }

  /// 認識中・整形中にもう一度押したときの動作（REC-06）。既定は何もしない
  public var pressWhileProcessing: ShortcutPressWhileProcessing

  /// Push-to-talk で、押下中のショートカットが今の録音を開始したか
  private var pushToTalkOwnsRecording = false

  public init(
    mode: ShortcutTriggerMode, pressWhileProcessing: ShortcutPressWhileProcessing = .ignore
  ) {
    self.mode = mode
    self.pressWhileProcessing = pressWhileProcessing
  }

  /// Esc を捕捉する状態か（REC-01）。
  ///
  /// 録音〜整形中のセッション中だけ捕捉する。待機中・挿入中・失敗の表示中は捕捉せず、
  /// 他アプリの Esc 操作に干渉しない。アプリは状態が変わるたびにこれを見て Esc の捕捉を付け外しする。
  public static func capturesEscape(in phase: SessionPhase) -> Bool {
    switch phase {
    case .recording, .recognizing, .refining:
      return true
    case .idle, .inserting, .error:
      return false
    }
  }

  /// 入力を現在の状態に照らして解釈する。
  public mutating func handle(_ input: ShortcutInput, phase: SessionPhase) -> ShortcutDecision {
    switch input {
    case .shortcutPressed(let isRepeat):
      return .consumed(isRepeat ? nil : press(phase: phase))
    case .shortcutReleased:
      return .consumed(release(phase: phase))
    case .escapePressed:
      guard Self.capturesEscape(in: phase) else { return .passThrough }
      pushToTalkOwnsRecording = false
      return .consumed(.cancelSession)
    }
  }

  /// 外部要因（スリープ・入力デバイス変更・イベントの取りこぼし等）で押下状態が信用できなくなったときに呼ぶ。
  public mutating func reset() {
    pushToTalkOwnsRecording = false
  }

  private mutating func press(phase: SessionPhase) -> ShortcutCommand? {
    switch phase {
    case .idle:
      pushToTalkOwnsRecording = mode == .pushToTalk
      return .startRecording
    case .recording:
      // Toggle の2回目。Push-to-talk では解放の取りこぼしからの回復として停止する
      pushToTalkOwnsRecording = false
      return .stopRecording
    case .recognizing, .refining:
      // 処理中の開始操作は無視するか、キャンセルするかを確かめる（REC-06。どちらにするかは設定で固定する）
      switch pressWhileProcessing {
      case .ignore: return nil
      case .confirmCancel: return .confirmCancel
      }
    case .inserting, .error:
      // 挿入が始まったら取り消さない（REC-01）。失敗の表示中も開始操作は無視する（REC-06）
      return nil
    }
  }

  private mutating func release(phase: SessionPhase) -> ShortcutCommand? {
    guard mode == .pushToTalk, pushToTalkOwnsRecording else { return nil }
    pushToTalkOwnsRecording = false
    // 押下中に最大録音時間などで自動停止していれば、解放では何もしない
    return phase == .recording ? .stopRecording : nil
  }
}

/// 録音の操作方式（REC-01, REC-02）。設定に保存する（UtterPersistence の `AppSettings`）。保存形式は case 名の文字列。
public enum ShortcutTriggerMode: String, Hashable, Sendable, CaseIterable, Codable {
  /// 1回目の押下で開始、2回目の押下で停止
  case toggle
  /// 押している間だけ録音し、離すと停止
  case pushToTalk
}

/// 認識中・整形中に録音ショートカットをもう一度押したときの動作（REC-06）。設定に保存する（UtterPersistence の `AppSettings`）。
/// 保存形式は case 名の文字列。録音中の押下（Toggle の停止）と挿入中・失敗の表示中の押下は、この設定によらない
public enum ShortcutPressWhileProcessing: String, Hashable, Sendable, CaseIterable, Codable {
  /// 何もしない（既定）
  case ignore
  /// キャンセルするかを確かめる。確かめている間も処理は止めない
  case confirmCancel
}

/// アプリのアダプターから届くキー入力。OS のイベント型は持たない。
public enum ShortcutInput: Hashable, Sendable {
  /// 録音ショートカットの押下。`isRepeat` はキーリピートによる押下
  case shortcutPressed(isRepeat: Bool)
  /// 録音ショートカットの解放
  case shortcutReleased
  /// 修飾キーなしの Esc の押下
  case escapePressed
}

/// 入力の解釈結果。
public enum ShortcutDecision: Hashable, Sendable {
  /// utter が入力を受け取る。値は実行する操作で、`nil` は何もしない（処理中の開始操作など）
  case consumed(ShortcutCommand?)
  /// 入力を捕捉せず、他アプリへそのまま渡す
  case passThrough
}

/// セッションへの操作。
public enum ShortcutCommand: Hashable, Sendable {
  case startRecording
  case stopRecording
  case cancelSession
  /// キャンセルするかを利用者に確かめる（`ShortcutPressWhileProcessing.confirmCancel`）。確かめるまではキャンセルしない
  case confirmCancel
}
