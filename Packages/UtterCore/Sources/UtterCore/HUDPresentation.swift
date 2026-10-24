/// HUD に表示する文言と表示の種類（REC-03, REC-05, 4.1節）。
///
/// `HUDContent`（状態と通知の区分）だけから組み立てるため、発話本文・認識結果・API キー・トークン・
/// エラー詳細を含まない。画面（Apps）はこの値をそのまま描画し、文言を独自に作らない。
public struct HUDPresentation: Hashable, Sendable {
  /// 表示の種類。画面はアイコンと色を選ぶのに使う
  public let indicator: HUDIndicator
  /// 1行目に出す文言。状態があれば状態、通知だけを残しているときは先頭の通知
  public let title: String
  /// 2行目以降に1件ずつ出す通知の文言。`HUDContent.notices` の順（録音停止または失敗の理由、整形の退避）
  public let messages: [String]

  /// 状態も通知もない内容では `nil`（何も表示しない）。
  public init?(_ content: HUDContent) {
    let texts = content.notices.map(Self.text(for:))
    if let status = content.status {
      indicator = HUDIndicator(status)
      title = Self.text(for: status)
      messages = texts
    } else if let first = texts.first {
      indicator = .notice
      title = first
      messages = Array(texts.dropFirst())
    } else {
      return nil
    }
  }

  /// 2行目の文言（先頭の通知）。なければ `nil`。
  ///
  /// 通知が重なると先頭の1件しか返さないため、画面の表示には `messages` を使う。
  public var message: String? {
    messages.first
  }

  /// VoiceOver で読み上げる文言。表示している文言を順に読む
  public var accessibilityLabel: String {
    ([title] + messages).joined(separator: "。")
  }

  /// 表示したときに VoiceOver へ読み上げを依頼する文言。依頼しないときは `nil`。
  ///
  /// 失敗と通知だけを読み上げる。録音中の読み上げは音声がマイクに入って認識結果に混ざるおそれがあり、
  /// 認識・整形・挿入の各段階は短い間隔で変わって読み上げが途切れ続けるため、読み上げない（要素のラベルでは読める）。
  public var announcement: String? {
    switch indicator {
    case .failure, .notice: accessibilityLabel
    case .recording: nil
    case .processing: messages.isEmpty ? nil : accessibilityLabel
    }
  }

  /// 直前の表示から続けて表示するときに読み上げを依頼する文言。依頼しないときは `nil`。
  ///
  /// 失敗は `announcement` のとおり読み上げる。それ以外は、直前の表示になかった通知があるときだけ読み上げる
  /// （段階が変わるたびに同じ通知を読み直さない。整形中→挿入中→通知だけを残す、の間に退避の通知を繰り返さない）。
  /// - Parameter previous: 直前に表示していた内容。隠していた後に表示するときは `nil`
  public func announcement(after previous: HUDPresentation?) -> String? {
    guard let announcement else { return nil }
    guard indicator != .failure, let previous else { return announcement }
    return Set(noticeTexts).isSubset(of: previous.noticeTexts) ? nil : announcement
  }

  /// 表示している通知の文言（通知だけを残しているときは1行目を含む）
  private var noticeTexts: [String] {
    indicator == .notice ? [title] + messages : messages
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
    case .speechRecognitionNotConfigured: "音声認識が設定されていません"
    case .microphoneAccessDenied: "マイクの使用が許可されていません"
    case .refinementFellBack(let fallback): "\(reason(for: fallback))ため、ローカルで整形しました"
    }
  }

  /// 退避の理由（4.1節, AC-16, AI-06）。種類ごとに利用者の対処が違うため分けて書く。エラー詳細は含めない
  private static func reason(for fallback: RefinementFallbackNotice) -> String {
    switch fallback {
    case .consentNotGranted: "クラウドへの送信に同意していない"
    case .sensitiveInput: "入力先が機密入力の"
    case .timeout: "クラウド整形の応答が時間内に届かなかった"
    case .authenticationExpired: "クラウド整形の API キーが無効になっている"
    case .quotaExceeded: "クラウド整形の利用枠が不足している"
    case .budgetExceeded: "月次予算の上限を超える"
    case .networkUnavailable: "ネットワークに接続できない"
    case .invalidResponse: "クラウド整形の応答を解釈できなかった"
    case .providerCancelled: "クラウド整形が中断された"
    case .validationFailed: "クラウド整形の結果が検証を通らなかった"
    }
  }

  private static func reason(for cause: RecordingInterruptionCause) -> String {
    switch cause {
    case .audioInterruption: "ほかの音声に割り込まれた"
    case .inputDeviceLost: "マイクが使えなくなった"
    case .inputDeviceChanged: "入力機器が切り替わった"
    case .mediaServicesReset: "音声システムがリセットされた"
    case .movedToBackground: "アプリがバックグラウンドに移った"
    case .thermalState: "端末の温度が上がった"
    case .lowPowerMode: "低電力モードになった"
    case .systemSleep: "Mac がスリープした"
    case .microphoneAccessRevoked: "マイクの使用許可が取り消された"
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
