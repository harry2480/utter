import Foundation
import UtterAI
import UtterCore
import UtterPersistence

// iOS 本体アプリのホーム・録音中・結果の画面に出す表示の値（#201）。
// 画面（Apps/iOS/Sources）はここで決めた文言を出すだけにし、判定をテストできるようにする。
// 本文は持たない（途中の文字は `InterimTranscript` が表示のためだけに持つ）。

/// 認識・整形の行き先の表示（ホーム・録音中のチップ・結果）。
///
/// 端末の外へ文字を送る先には「文字を送信」と示す（AC-06）。表示のための判定で、送信の可否は
/// `CloudRefinement` が送信の直前に同意・API キー・予算から決める。送りうる先を少なく見せないよう、迷う場合は送る側に倒す。
public struct ProcessingDestination: Hashable, Sendable {
  /// 文字を送る先に添える表示
  public static let sendsTextLabel = "文字を送信"

  /// 行き先の名前
  public let name: String
  /// 端末の外へ文字を送る（送りうる）先か
  public let sendsText: Bool

  private init(name: String, sendsText: Bool) {
    self.name = name
    self.sendsText = sendsText
  }

  /// 認識の行き先。iOS の STT はどれも端末内で、音声も文字も送らない
  public init(speechEngine: SpeechEngineSelection) {
    switch speechEngine {
    case .unconfigured: name = "未設定（文字にしません）"
    case .speechAnalyzer: name = "SpeechAnalyzer（端末内）"
    }
    sendsText = false
  }

  /// これから録音する発話の整形先。保存済みの設定から決める。
  ///
  /// 処理系にクラウド AI を選び、Claude への整形の送信に同意していれば「文字を送信」と示す。
  /// API キー・予算がそろわず端末内で整形する場合もあるが、送りうる先として示す（そろわなければ録音の後に理由を通知する）。
  public init(refinementFor mode: RefinementMode, settings: AppSettings) {
    guard mode != .raw else {
      self = .unrefined
      return
    }
    guard settings.refinementEngine == .cloudAI else {
      self = .localBasic
      return
    }
    guard settings.consentState.allows(.textRefinement(.claude)) else {
      self = .localBasicWithoutConsent
      return
    }
    self = .claude
  }

  /// 保存した結果の整形先。実際に通った経路から決める。
  ///
  /// Claude を使えずに端末内の整形に切り替えた結果は、同意がない・機密入力で送らなかった場合を除き、
  /// 送信した後に切り替えた可能性があるため「文字を送信」と示す。
  public init(refinementFor mode: RefinementMode, route: SessionRefinementRoute) {
    switch route {
    case .cloud:
      self = .claude
    case .localOnly(.rawMode):
      self = .unrefined
    case .localOnly:
      self = mode == .raw ? .unrefined : .localBasic
    case .cloudFallback(let reason):
      switch reason {
      case .consentNotGranted, .sensitiveInputSuppressed: self = .claudeFallback(sentText: false)
      case .providerFailed, .validationFailed: self = .claudeFallback(sentText: true)
      }
    }
  }

  /// 整形しない（Raw）
  static let unrefined = ProcessingDestination(name: "整形しない（Raw）", sendsText: false)
  /// 端末内の整形
  static let localBasic = ProcessingDestination(name: "Local Basic（端末内）", sendsText: false)
  /// Claude による整形
  static let claude = ProcessingDestination(name: "Claude", sendsText: true)
  /// クラウド AI を選んでいるが、Claude への送信に同意していないため端末内で整形する
  static let localBasicWithoutConsent = ProcessingDestination(
    name: "Local Basic（Claude への送信に未同意）", sendsText: false)

  /// Claude を使えず、端末内の整形に切り替えた
  static func claudeFallback(sentText: Bool) -> ProcessingDestination {
    ProcessingDestination(name: "Local Basic（Claude から切り替え）", sendsText: sentText)
  }
}

// 文体（整形モード, TXT-01）の表示。
extension RefinementMode {
  /// 文体の名前
  public var styleName: String {
    switch self {
    case .raw: "Raw"
    case .natural: "Natural"
    case .structured: "Structured"
    }
  }

  /// 文体の説明
  public var styleDescription: String {
    switch self {
    case .raw: "認識結果のまま"
    case .natural: "自然な文に整える"
    case .structured: "箇条書き・段落に整える"
    }
  }

  /// 保存した設定の文体
  init(_ setting: RefinementModeSetting) {
    switch setting {
    case .raw: self = .raw
    case .natural: self = .natural
    case .structured: self = .structured
    }
  }
}

extension RefinementModeSetting {
  /// 保存する文体
  init(_ mode: RefinementMode) {
    switch mode {
    case .raw: self = .raw
    case .natural: self = .natural
    case .structured: self = .structured
    }
  }
}

/// 録音時間の表示（REC-05）
public enum RecordingDurationText {
  /// 「分:秒」（秒は 2 桁）。端数の秒は切り捨て、負の値は 0 にする
  public static func clock(_ duration: Duration) -> String {
    let total = max(duration, .zero).components.seconds
    let seconds = total % 60
    return "\(total / 60):\(seconds < 10 ? "0" : "")\(seconds)"
  }

  /// ホームに出す最大録音時間（「最大録音時間 5 分」）
  public static func maximum(_ duration: Duration) -> String {
    let total = max(duration, .zero).components.seconds
    let minutes = total / 60
    let seconds = total % 60
    let text =
      switch (minutes, seconds) {
      case (0, _): "\(seconds) 秒"
      case (_, 0): "\(minutes) 分"
      default: "\(minutes) 分 \(seconds) 秒"
      }
    return "最大録音時間 \(text)"
  }
}

/// 録音中の経過時間と最大録音時間（REC-05）
public struct RecordingProgress: Hashable, Sendable {
  /// 録音を始めてからの時間。0〜最大録音時間に収める
  public let elapsed: Duration
  public let maxDuration: Duration

  public init(elapsed: Duration, maxDuration: Duration) {
    self.maxDuration = max(maxDuration, .zero)
    self.elapsed = min(max(elapsed, .zero), self.maxDuration)
  }

  /// 「経過 / 最大録音時間」（「0:12 / 5:00」）
  public var text: String {
    "\(RecordingDurationText.clock(elapsed)) / \(RecordingDurationText.clock(maxDuration))"
  }

  /// 最大録音時間に対する経過の割合（0〜1）
  public var fraction: Double {
    guard maxDuration > .zero else { return 1 }
    return elapsed / maxDuration
  }
}

/// 保存した結果が消えるまでの残り時間（iOS-IPC-02）
public enum ResultRemainingTime {
  /// 残り時間を分に切り上げる（作成直後は 10 分、残り 30 秒なら 1 分）。期限を過ぎていれば `nil`
  public static func minutes(until expiresAt: Date, at now: Date) -> Int? {
    let remaining = expiresAt.timeIntervalSince(now)
    guard remaining > 0 else { return nil }
    let minutes = (remaining / 60).rounded(.up)
    // 保存済みの値が壊れて期限が極端に先でも、変換で停止しないよう上限で止める
    return minutes < Double(Int.max) ? Int(minutes) : Int.max
  }

  /// 「あと N 分で消えます」。期限を過ぎていれば「期限が切れました」
  public static func message(until expiresAt: Date, at now: Date) -> String {
    guard let minutes = minutes(until: expiresAt, at: now) else { return "期限が切れました" }
    return "あと \(minutes) 分で消えます"
  }
}

/// 結果の画面に出す、元のアプリに戻ってキーボードから入れる手順（iOS-03, iOS-07）。
///
/// 戻る操作は利用者が行う（本体アプリから元のアプリを開く公開 API はない, iOS-03）。手順の文言は
/// キーボードからの導線と復帰の検証（#53）の結果に合わせて見直す（仮置き）。
public struct ResultReturnGuide: Hashable, Sendable {
  /// キーボードから入れる手順。キーボードと共有していなければ空
  public let steps: [String]
  /// キーボードが使えないときのコピーの案内
  public let copyHint: String

  public init(sharing: SharedResultSharing) {
    switch sharing {
    case .appGroup:
      steps = [
        "画面左上の「◀︎」（表示されている場合）か、画面の下端を横にスワイプして、元のアプリに戻ります。",
        "入力欄をタップし、地球儀キーで utter キーボードに切り替えます。",
        "キーボードに出る本文と入力欄を確かめて「挿入」を押します。",
      ]
      copyHint = "パスワードや電話番号の欄など utter キーボードが出ない欄では、この画面でコピーして貼り付けてください。"
    case .appLocalOnly:
      steps = []
      copyHint = "結果をキーボードと共有していないため、この画面でコピーし、元のアプリに戻って貼り付けてください。"
    }
  }
}

/// 保存した結果の文体と整形先。本文は持たない
public struct SavedResultContext: Hashable, Sendable {
  public let mode: RefinementMode
  public let refinement: ProcessingDestination

  public init(mode: RefinementMode, refinement: ProcessingDestination) {
    self.mode = mode
    self.refinement = refinement
  }
}

/// 録音中に出す途中の文字（2.2節）。確定した部分と聞き取り中の部分を分ける。
///
/// STT が途中経過（`partial` / `confirmed`）を返す場合だけ作れる。本文のため、画面に出すだけで保存・記録しない。
public struct InterimTranscript: Hashable, Sendable {
  /// 確定した部分。なければ `nil`
  public let confirmed: String?
  /// 聞き取り中（暫定）の部分。なければ `nil`
  public let listening: String?

  /// 途中の文字がなければ `nil`
  public init?(_ preview: TranscriptPreview) {
    let confirmed = preview.confirmedText
    let listening = preview.provisionalText
    let hasConfirmed = !confirmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasListening = !listening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasConfirmed || hasListening else { return nil }
    self.confirmed = hasConfirmed ? confirmed : nil
    self.listening = hasListening ? listening : nil
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには文字数だけを出す。
extension InterimTranscript: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "InterimTranscript(confirmedLength: \(confirmed?.count ?? 0), "
      + "listeningLength: \(listening?.count ?? 0))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
