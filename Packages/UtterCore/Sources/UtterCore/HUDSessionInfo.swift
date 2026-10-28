import Foundation

/// 状態と通知のほかに、HUD に出す進行中のセッションの情報（REC-03, REC-05）。
///
/// `HUDController` がセッションごとに集めて `HUDPresentation` に渡す。発話本文・音声・API キーは持たない。
public struct HUDSessionInfo: Hashable, Sendable {
  /// 録音開始時に決めたセッションの設定（チップに出す）
  public var details: HUDSessionDetails?
  /// 録音の経過時間と最大録音時間。録音中だけ持つ
  public var recordingTime: HUDRecordingTime?
  /// 入力音量。録音中に録音のチャンクから求めた値
  public var inputLevel: HUDInputLevel?
  /// クラウド整形の送信先。整形中に送ると決めたときだけ持つ
  public var refinementDestination: CloudAIProviderKind?
  /// 停止・キャンセルのキー
  public var keyHints: HUDKeyHints

  public init(
    details: HUDSessionDetails? = nil,
    recordingTime: HUDRecordingTime? = nil,
    inputLevel: HUDInputLevel? = nil,
    refinementDestination: CloudAIProviderKind? = nil,
    keyHints: HUDKeyHints = HUDKeyHints()
  ) {
    self.details = details
    self.recordingTime = recordingTime
    self.inputLevel = inputLevel
    self.refinementDestination = refinementDestination
    self.keyHints = keyHints
  }
}

/// 録音開始時に決めたセッションの設定（REC-03）。HUD の録音中のチップに出す。
///
/// 設定の区分と前面アプリの表示名だけを持ち、bundle ID・ウィンドウタイトル・URL は持たない。
public struct HUDSessionDetails: Hashable, Sendable {
  /// 整形モードとアプリ別スタイル
  public let refinement: HUDRefinementSummary
  /// 録音開始時の前面アプリの表示名。分からなければ `nil`
  public let appName: String?
  /// 音声認識の種別
  public let speechRecognition: HUDSpeechRecognitionKind

  public init(
    refinement: HUDRefinementSummary, appName: String?,
    speechRecognition: HUDSpeechRecognitionKind
  ) {
    self.refinement = refinement
    self.appName = appName
    self.speechRecognition = speechRecognition
  }
}

/// 録音開始時の整形の設定（TXT-01, CTX-01, CTX-02）。
public struct HUDRefinementSummary: Hashable, Sendable {
  public let mode: HUDRefinementMode
  /// 前面アプリから選んだスタイル。Raw はスタイルを使わないため `nil`
  public let style: RefinementStyle?

  public init(mode: HUDRefinementMode, style: RefinementStyle?) {
    self.mode = mode
    self.style = mode == .raw ? nil : style
  }
}

/// 整形モード（TXT-01）。UtterCore は UtterText に依存しないため、HUD の表示用に区分だけを持つ。
public enum HUDRefinementMode: Hashable, Sendable, CaseIterable {
  case raw
  case natural
  case structured
}

/// 音声認識の種別。
public enum HUDSpeechRecognitionKind: Hashable, Sendable, CaseIterable {
  /// この Mac の中で認識する（STT Worker）
  case local
  /// クラウド STT（#188）。録音を止めた後に音声を送る
  case cloud
}

/// 録音の経過時間と最大録音時間（REC-05）。
public struct HUDRecordingTime: Hashable, Sendable {
  /// 録音を始めてからの時間。0 から `limit` までに収める
  public let elapsed: Duration
  /// 最大録音時間。分からなければ `nil`
  public let limit: Duration?

  public init(elapsed: Duration, limit: Duration?) {
    var elapsed = max(elapsed, .zero)
    if let limit, elapsed > limit {
      elapsed = limit
    }
    self.elapsed = elapsed
    self.limit = limit
  }

  /// 表示する文言（例: `0:07 / 5:00`）。秒未満は切り捨てる
  public var text: String {
    let elapsedText = Self.minutesAndSeconds(elapsed)
    guard let limit else { return elapsedText }
    return "\(elapsedText) / \(Self.minutesAndSeconds(limit))"
  }

  private static func minutesAndSeconds(_ duration: Duration) -> String {
    let seconds = max(duration.components.seconds, 0)
    let remainder = seconds % 60
    return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
  }
}

/// 録音中の入力音量（REC-03）。レベルメーターの点灯する本数だけを持つ。
///
/// 録音のチャンクのサンプルからその場で求め、サンプルは保持・送信しない。
public struct HUDInputLevel: Hashable, Sendable {
  /// レベルメーターの本数
  public static let barCount = 5
  /// 無音として0本にする音量の上限（dBFS）。これを超えると1本目から点灯する
  static let floorDecibels: Double = -50

  /// 点灯する本数（0〜`barCount`）
  public let bars: Int

  public init(bars: Int) {
    self.bars = min(max(bars, 0), Self.barCount)
  }

  /// -1.0〜1.0 のモノラル PCM サンプルの実効値（RMS）から求める。空・無音なら0本
  public init(samples: [Float]) {
    guard !samples.isEmpty else {
      self.init(bars: 0)
      return
    }
    var sum = 0.0
    for sample in samples where sample.isFinite {
      let value = Double(sample)
      sum += value * value
    }
    let rms = (sum / Double(samples.count)).squareRoot()
    guard rms > 0 else {
      self.init(bars: 0)
      return
    }
    let decibels = 20 * log10(rms)
    let ratio = (decibels - Self.floorDecibels) / -Self.floorDecibels
    guard ratio > 0 else {
      self.init(bars: 0)
      return
    }
    self.init(bars: Int((ratio * Double(Self.barCount)).rounded(.up)))
  }
}

/// 停止とキャンセルに使えるキー（REC-01, REC-02）。使えないキーは `nil`。
public struct HUDKeyHints: Hashable, Sendable {
  /// 録音を止めるキーの表記（例: `⌥Space`）
  public let stopKey: String?
  /// 押している間だけ録音する（Push-to-talk）か。`true` ならキーを離すと止まる
  public let stopsOnRelease: Bool
  /// キャンセルするキーの表記（例: `Esc`）。Esc の捕捉を使える間だけ持つ
  public let cancelKey: String?

  public init(stopKey: String? = nil, stopsOnRelease: Bool = false, cancelKey: String? = nil) {
    self.stopKey = stopKey
    self.stopsOnRelease = stopsOnRelease
    self.cancelKey = cancelKey
  }
}

/// HUD に出すキーの案内の1件（例: `Esc` / `キャンセル`）。
public struct HUDKeyHint: Hashable, Sendable {
  /// キーの表記
  public let key: String
  /// キーで行う操作
  public let action: String

  public init(key: String, action: String) {
    self.key = key
    self.action = action
  }
}

/// 処理の4段階（REC-03）。HUD は処理中にどこにいるかを出す。
public enum HUDProcessingStage: Hashable, Sendable, CaseIterable {
  case recording
  case recognition
  case refinement
  case insertion

  /// 段階の名前
  public var label: String {
    switch self {
    case .recording: "録音"
    case .recognition: "認識"
    case .refinement: "整形"
    case .insertion: "挿入"
    }
  }
}
