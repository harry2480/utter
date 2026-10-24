/// HUD に表示する文言と表示の種類（REC-03, REC-05）。
///
/// `HUDContent`（状態と通知の区分）だけから組み立てるため、発話本文・認識結果・API キー・トークン・
/// エラー詳細を含まない。画面（Apps）はこの値をそのまま描画し、文言を独自に作らない。
public struct HUDPresentation: Hashable, Sendable {
  /// 表示の種類。画面はアイコンと色を選ぶのに使う
  public let indicator: HUDIndicator
  /// 1行目に出す文言。状態があれば状態、通知だけを残しているときは通知
  public let title: String
  /// 2行目に出す通知の文言。なければ `nil`
  public let message: String?

  /// 状態も通知もない内容では `nil`（何も表示しない）。
  public init?(_ content: HUDContent) {
    switch (content.status, content.notice) {
    case (let status?, let notice):
      indicator = HUDIndicator(status)
      title = Self.text(for: status)
      message = notice.map(Self.text(for:))
    case (nil, let notice?):
      indicator = .notice
      title = Self.text(for: notice)
      message = nil
    case (nil, nil):
      return nil
    }
  }

  /// VoiceOver で読み上げる文言。表示している文言を順に読む
  public var accessibilityLabel: String {
    [title, message].compactMap(\.self).joined(separator: "。")
  }

  /// 表示したときに VoiceOver へ読み上げを依頼する文言。依頼しないときは `nil`。
  ///
  /// 失敗と通知だけを読み上げる。録音中の読み上げは音声がマイクに入って認識結果に混ざるおそれがあり、
  /// 認識・整形・挿入の各段階は短い間隔で変わって読み上げが途切れ続けるため、読み上げない（要素のラベルでは読める）。
  public var announcement: String? {
    switch indicator {
    case .failure, .notice: accessibilityLabel
    case .recording: nil
    case .processing: message == nil ? nil : accessibilityLabel
    }
  }

  static func text(for status: HUDStatus) -> String {
    switch status {
    case .recording: "録音中"
    case .recognizing: "認識中"
    case .refining: "整形中"
    case .inserting: "挿入中"
    case .failed(.recording): "録音に失敗しました"
    case .failed(.recognition): "認識に失敗しました"
    case .failed(.refinement): "整形に失敗しました"
    case .failed(.insertion): "挿入に失敗しました"
    }
  }

  // 新しい通知・原因を追加したら、ここに文言を追加する（default で受けない）
  static func text(for notice: HUDNotice) -> String {
    switch notice {
    case .maxRecordingDurationReached: "最大録音時間に達したため、録音を停止しました"
    case .audioBufferLimitReached: "録音できる音声の上限に達したため、録音を停止しました"
    case .recordingInterrupted(let cause): "\(reason(for: cause))ため、録音を停止しました"
    }
  }

  private static func reason(for cause: RecordingInterruptionCause) -> String {
    switch cause {
    case .audioInterruption: "ほかの音声に割り込まれた"
    case .inputDeviceLost: "マイクが使えなくなった"
    case .mediaServicesReset: "音声システムがリセットされた"
    case .movedToBackground: "アプリがバックグラウンドに移った"
    case .thermalState: "端末の温度が上がった"
    case .lowPowerMode: "低電力モードになった"
    }
  }
}

/// HUD の表示の種類（REC-03）。
public enum HUDIndicator: Hashable, Sendable {
  /// 録音中
  case recording
  /// 認識・整形・挿入の処理中
  case processing
  /// 失敗の表示中
  case failure
  /// セッション終了後に通知だけを残している
  case notice

  init(_ status: HUDStatus) {
    switch status {
    case .recording: self = .recording
    case .recognizing, .refining, .inserting: self = .processing
    case .failed: self = .failure
    }
  }
}
