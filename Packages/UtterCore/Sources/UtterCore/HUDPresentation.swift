/// HUD に表示する文言と表示の種類（REC-03, REC-05, 4.1節）。
///
/// 文言は `HUDContent`（状態と通知の区分）だけから組み立てるため、API キー・トークン・エラー詳細を含まない。
/// 発話本文を持つのは Realtime Preview（2.2節, AC-03）の `transcript` だけで、録音中・認識中に限る。
/// `transcript` は VoiceOver の読み上げ（`accessibilityLabel` / `announcement`）と `description` に含めない。
/// 画面（Apps）はこの値をそのまま描画し、文言を独自に作らない。
public struct HUDPresentation: Hashable, Sendable {
  /// 表示の種類。画面はアイコンと色を選ぶのに使う
  public let indicator: HUDIndicator
  /// 1行目に出す文言。状態があれば状態、通知だけを残しているときは先頭の通知
  public let title: String
  /// 2行目以降に1件ずつ出す通知の文言。`HUDContent.notices` の順（録音停止または失敗の理由、Realtime Direct の無効化、整形の退避）
  public let messages: [String]
  /// Realtime Preview の確定済み・暫定テキスト。録音中・認識中で、表示する文字があるときだけ持つ
  public let transcript: HUDTranscript?

  /// 状態も通知もない内容では `nil`（何も表示しない）。
  /// - Parameter transcript: Realtime Preview の認識テキスト。録音中・認識中のときだけ使い、それ以外の段階では捨てる
  public init?(_ content: HUDContent, transcript: HUDTranscript? = nil) {
    switch content.status {
    case .recording, .recognizing:
      self.transcript = transcript.flatMap { $0.isEmpty ? nil : $0 }
    case .refining, .inserting, .failed, nil:
      self.transcript = nil
    }
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
  /// 表示の種類と文言が同じで `transcript` だけが変わったときは `nil`（Realtime Preview の更新のたびに
  /// 同じ通知を読み上げ直さない）。それ以外で、失敗は `announcement` のとおり読み上げる。失敗以外は、直前の表示に
  /// なかった通知があるときだけ読み上げる（段階が変わるたびに同じ通知を読み直さない。整形中→挿入中→通知だけを
  /// 残す、の間に退避の通知を繰り返さない）。
  /// - Parameter previous: 直前に表示していた内容。隠していた後に表示するときは `nil`
  public func announcement(after previous: HUDPresentation?) -> String? {
    guard let announcement else { return nil }
    guard let previous else { return announcement }
    if previous.indicator == indicator, previous.title == title, previous.messages == messages {
      return nil
    }
    guard indicator != .failure else { return announcement }
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
    case .cloudSpeechRecognitionFailed(let failure):
      "\(reason(for: failure))ため、クラウドで音声認識できませんでした"
    case .realtimeDirectDisabled(let fallback): realtimeDirectText(for: fallback)
    case .recordingSuppressed(let suppression): "\(reason(for: suppression))ため、録音しません"
    }
  }

  /// 録音を始めなかった理由（7章, AC-12）。入力欄の内容・アプリ名は含めない
  private static func reason(for suppression: SensitiveInputReason) -> String {
    switch suppression {
    case .secureField: "パスワード欄の"
    case .secureEventInput: "セキュア入力が有効な"
    case .sensitiveApp: "機密情報を扱うアプリの"
    case .excludedApp: "除外アプリの"
    case .undetermined: "入力先を確認できない"
    }
  }

  /// Realtime Direct を無効にした理由と、その後の入力のしかた（2.2節, AC-15）。入力欄の内容・アプリ名は含めない
  private static func realtimeDirectText(for fallback: RealtimeDirectFallbackNotice) -> String {
    switch fallback {
    case .unsupportedTarget:
      "この入力先は Realtime Direct に対応していないため、停止後にまとめて入力します"
    case .sensitiveInput:
      "入力先が機密入力のため、Realtime Direct を使いません"
    case .cloudSpeechRecognition:
      "クラウド音声認識では Realtime Direct を使えないため、停止後にまとめて入力します"
    case .stoppedBeforeWriting:
      "入力欄の変更などを検知したため、Realtime Direct をやめて停止後にまとめて入力します"
    case .stoppedAfterWriting:
      "入力欄の変更などを検知したため、Realtime Direct の入力を途中でやめました"
    }
  }

  /// クラウド STT で認識できなかった理由（4章, AC-06, AI-06）。種類ごとに利用者の対処が違うため分けて書く。エラー詳細は含めない
  private static func reason(for failure: CloudSpeechRecognitionNotice) -> String {
    switch failure {
    case .consentNotGranted: "クラウド音声認識への音声の送信に同意していない"
    case .apiKeyNotSet: "OpenAI API キーが保存されていない"
    case .apiKeyUnavailable: "OpenAI API キーを読み出せない"
    case .budgetUnavailable: "月次予算・単価表を確かめられない"
    case .budgetExceeded: "月次予算の上限を超える"
    case .audioLimitExceeded: "クラウドへ送れる音声の上限を超えた"
    case .configurationUnavailable: "クラウド音声認識の設定を使えない"
    case .timeout: "クラウド音声認識の応答が時間内に届かなかった"
    case .authenticationExpired: "OpenAI API キーが無効になっている"
    case .quotaExceeded: "クラウド音声認識の利用枠が不足している"
    case .networkUnavailable: "ネットワークに接続できない"
    case .invalidResponse: "クラウド音声認識の応答を解釈できなかった"
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

// Realtime Preview の認識テキストをログに出さないよう、文字列表現とリフレクションでは `transcript` の文字数だけを出す。
extension HUDPresentation: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "HUDPresentation(indicator: \(indicator), title: \(title), messages: \(messages), "
      + "transcript: \(transcript.map(String.init(describing:)) ?? "nil"))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
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
