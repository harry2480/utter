/// HUD に表示する文言と表示の種類（REC-03, REC-05, 4.1節）。
///
/// 文言は `HUDContent`（状態と通知の区分）だけから組み立てるため、API キー・トークン・エラー詳細を含まない。
/// 発話本文を持つのは Realtime Preview（2.2節, AC-03）の `transcript` だけで、録音中・認識中に限る。
/// `transcript` は VoiceOver の読み上げ（`accessibilityLabel` / `announcement`）と `description` に含めない。
/// 画面（Apps）はこの値をそのまま描画し、文言を独自に作らない。
///
/// 状態と通知のほかに、`HUDSessionInfo` から次を組み立てる（REC-03, REC-05）。
/// - 録音中: 経過時間と最大録音時間、レベルメーター、チップ（整形モード・アプリ別スタイル・音声認識の種別）
/// - 処理中: 4段階（録音 → 認識 → 整形 → 挿入）のどこにいるか
/// - クラウドへ送る間（クラウド STT の認識中、クラウド整形を送ると決めた整形中）: 送信先
/// - キャンセルが効く間（録音中・認識中・整形中）: 停止とキャンセルのキー。使えるキーだけを出す
/// - 挿入完了: 挿入先のアプリ名
public struct HUDPresentation: Hashable, Sendable {
  /// 表示の種類。画面はアイコンと色を選ぶのに使う
  public let indicator: HUDIndicator
  /// 1行目に出す文言。状態があれば状態、通知だけを残しているときは先頭の通知
  public let title: String
  /// 2行目以降に1件ずつ出す通知の文言。`HUDContent.notices` の順（録音停止または失敗の理由、Realtime Direct の無効化、整形の退避）
  public let messages: [String]
  /// Realtime Preview の確定済み・暫定テキスト。録音中・認識中で、表示する文字があるときだけ持つ
  public let transcript: HUDTranscript?
  /// 録音の経過時間と最大録音時間（例: `0:07 / 5:00`）。録音中だけ持つ
  public let recordingTimeText: String?
  /// レベルメーターの点灯する本数（0〜`HUDInputLevel.barCount`）。録音中だけ持つ
  public let inputLevelBars: Int?
  /// 録音中に出すチップの文言（整形モード・アプリ別スタイル・音声認識の種別の順）
  public let chips: [String]
  /// 処理中の段階。認識中・整形中・挿入中だけ持つ
  public let stage: HUDProcessingStage?
  /// クラウドへ送る間の送信先（例: `Claude へ送信`）。ローカルで処理する間は `nil`
  public let destination: String?
  /// 停止・キャンセルのキーの案内。キャンセルが効く間（録音中・認識中・整形中）だけ持つ
  public let keyHints: [HUDKeyHint]

  /// 状態も通知も挿入完了もない内容では `nil`（何も表示しない）。
  /// - Parameters:
  ///   - transcript: Realtime Preview の認識テキスト。録音中・認識中のときだけ使い、それ以外の段階では捨てる
  ///   - info: 状態以外に表示に添える情報。段階ごとに使う部分だけを使う
  public init?(
    _ content: HUDContent, transcript: HUDTranscript? = nil,
    info: HUDSessionInfo = HUDSessionInfo()
  ) {
    let status = content.status
    switch status {
    case .recording, .recognizing:
      self.transcript = transcript.flatMap { $0.isEmpty ? nil : $0 }
    case .refining, .inserting, .failed, nil:
      self.transcript = nil
    }
    let texts = content.notices.map(Self.text(for:))
    if let status {
      indicator = HUDIndicator(status)
      title = Self.text(for: status)
      messages = texts
    } else if let insertion = content.insertion {
      indicator = .completed
      title = Self.insertionText(for: insertion)
      messages = texts
    } else if let first = texts.first {
      indicator = .notice
      title = first
      messages = Array(texts.dropFirst())
    } else {
      return nil
    }
    if status == .recording {
      recordingTimeText = info.recordingTime?.text
      inputLevelBars = info.inputLevel?.bars ?? 0
      chips = info.details.map(Self.chips(for:)) ?? []
    } else {
      recordingTimeText = nil
      inputLevelBars = nil
      chips = []
    }
    stage = status.flatMap(Self.stage(for:))
    destination = status.flatMap { Self.destination(for: $0, info: info) }
    keyHints = status.map { Self.keyHints(for: $0, hints: info.keyHints) } ?? []
  }

  /// 2行目の文言（先頭の通知）。なければ `nil`。
  ///
  /// 通知が重なると先頭の1件しか返さないため、画面の表示には `messages` を使う。
  public var message: String? {
    messages.first
  }

  /// VoiceOver で読み上げる文言。1行目・送信先・通知を順に読む
  public var accessibilityLabel: String {
    var lines = [title]
    if let destination {
      lines.append(destination)
    }
    return (lines + messages).joined(separator: "。")
  }

  /// 表示したときに VoiceOver へ読み上げを依頼する文言。依頼しないときは `nil`。
  ///
  /// 失敗・通知・挿入完了だけを読み上げる。録音中の読み上げは音声がマイクに入って認識結果に混ざるおそれがあり、
  /// 認識・整形・挿入の各段階は短い間隔で変わって読み上げが途切れ続けるため、読み上げない（要素のラベルでは読める）。
  public var announcement: String? {
    switch indicator {
    case .failure, .notice, .completed: accessibilityLabel
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

  /// 表示している通知の文言（通知・挿入完了だけを残しているときは1行目を含む）
  private var noticeTexts: [String] {
    switch indicator {
    case .notice, .completed: [title] + messages
    case .recording, .processing, .failure: messages
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

  /// 挿入完了の1行目。読み戻しで確かめられなかったときは、入ったと言い切らない（INS-05）
  static func insertionText(for insertion: HUDInsertion) -> String {
    if insertion.isConfirmed {
      return "\(insertion.appName) に挿入しました"
    }
    return "\(insertion.appName) へ入力しました（反映を確認できません）"
  }

  /// 処理中の段階。録音中・失敗の表示中は `nil`
  private static func stage(for status: HUDStatus) -> HUDProcessingStage? {
    switch status {
    case .recognizing: .recognition
    case .refining: .refinement
    case .inserting: .insertion
    case .recording, .failed: nil
    }
  }

  /// クラウドへ送る間の送信先。クラウド STT は録音を止めた後（認識中）に音声を送る（#188）。
  /// 整形はクラウドへ送ると決めた後（`HUDSessionInfo.refinementDestination`）だけ出す
  private static func destination(for status: HUDStatus, info: HUDSessionInfo) -> String? {
    switch status {
    case .recognizing:
      info.details?.speechRecognition == .cloud ? "OpenAI へ送信" : nil
    case .refining:
      info.refinementDestination.map(destinationText(for:))
    case .recording, .inserting, .failed:
      nil
    }
  }

  private static func destinationText(for destination: CloudAIProviderKind) -> String {
    switch destination {
    case .claude: "Claude へ送信"
    case .chatGPT: "ChatGPT へ送信"
    }
  }

  /// キーの案内。キャンセルが効く間だけ出す（挿入中・失敗の表示中は出さない, REC-01）
  private static func keyHints(for status: HUDStatus, hints: HUDKeyHints) -> [HUDKeyHint] {
    var result: [HUDKeyHint] = []
    switch status {
    case .recording:
      if let stopKey = hints.stopKey {
        let action = hints.stopsOnRelease ? "離して停止" : "停止"
        result.append(HUDKeyHint(key: stopKey, action: action))
      }
      if let cancelKey = hints.cancelKey {
        result.append(HUDKeyHint(key: cancelKey, action: "キャンセル"))
      }
    case .recognizing, .refining:
      if let cancelKey = hints.cancelKey {
        result.append(HUDKeyHint(key: cancelKey, action: "キャンセル（挿入しません）"))
      }
    case .inserting, .failed:
      break
    }
    return result
  }

  /// 録音中のチップ。Raw はスタイルを使わないため、アプリ別スタイルのチップを出さない
  private static func chips(for details: HUDSessionDetails) -> [String] {
    var chips = [modeText(for: details.refinement.mode)]
    if let style = details.refinement.style {
      let label = styleText(for: style)
      chips.append(details.appName.map { "\($0)：\(label)" } ?? label)
    }
    chips.append(speechRecognitionText(for: details.speechRecognition))
    return chips
  }

  private static func modeText(for mode: HUDRefinementMode) -> String {
    switch mode {
    case .raw: "Raw"
    case .natural: "Natural"
    case .structured: "Structured"
    }
  }

  private static func styleText(for style: RefinementStyle) -> String {
    switch style {
    case .standard: "標準"
    case .concise: "簡潔"
    case .polite: "丁寧"
    case .technical: "技術語"
    case .command: "コマンド"
    case .document: "文書"
    }
  }

  private static func speechRecognitionText(for kind: HUDSpeechRecognitionKind) -> String {
    switch kind {
    case .local: "ローカルSTT"
    case .cloud: "クラウドSTT"
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
    case .sensitiveInput: "入力先が機密入力の"
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
// チップ（アプリ名を含む）とキーの案内は件数だけを出す。
extension HUDPresentation: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "HUDPresentation(indicator: \(indicator), title: \(title), messages: \(messages), "
      + "transcript: \(transcript.map(String.init(describing:)) ?? "nil"), "
      + "recordingTime: \(recordingTimeText ?? "nil"), "
      + "inputLevelBars: \(inputLevelBars.map { "\($0)" } ?? "nil"), "
      + "chips: \(chips.count), stage: \(stage.map(String.init(describing:)) ?? "nil"), "
      + "destination: \(destination ?? "nil"), keyHints: \(keyHints.count))"
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
  /// 挿入を終え、挿入先を残している（通知が重なれば2行目以降に出す）
  case completed

  init(_ status: HUDStatus) {
    switch status {
    case .recording: self = .recording
    case .recognizing, .refining, .inserting: self = .processing
    case .failed: self = .failure
    }
  }
}
