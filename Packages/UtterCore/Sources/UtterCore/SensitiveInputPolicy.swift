/// 機密入力の判定に使う信号の状態（7章）。
///
/// 取得に失敗したら `unknown` にする。プラットフォームに概念がない信号（macOS の `secureEventInput` に当たる
/// システムのセキュア入力状態は iOS にない）は `off` にする。入力欄がセキュア属性かどうかは iOS でも `off` に固定せず、
/// 観測した値を使う。iOS キーボード拡張の入力欄の属性は `KeyboardInputField` で表し、該当すれば `on`、
/// 取れなければ `unknown` にする（iOS-09）。
public enum SensitiveSignal: Hashable, Sendable, CaseIterable {
  /// 該当する（セキュア属性の入力欄、セキュア入力が有効）
  case on
  /// 該当しない
  case off
  /// 判定できない
  case unknown
}

/// 判定する時点の入力先の状態（7章, AC-12）。アプリ側が AX やシステムの状態から作る。
public struct SensitiveInputContext: Hashable, Sendable {
  /// 入力欄がセキュア属性（パスワード欄など）か
  public var secureField: SensitiveSignal
  /// システムのセキュア入力状態が有効か
  public var secureEventInput: SensitiveSignal
  /// 前面アプリの識別子（bundle ID など）。特定できなければ `nil`。iOS 本体アプリでは自アプリの識別子
  public var app: String?

  public init(secureField: SensitiveSignal, secureEventInput: SensitiveSignal, app: String?) {
    self.secureField = secureField
    self.secureEventInput = secureEventInput
    self.app = app
  }
}

/// 録音・クラウド送信・履歴保存を抑止する理由。
public enum SensitiveInputReason: Hashable, Sendable {
  /// 入力欄がセキュア属性
  case secureField
  /// システムのセキュア入力が有効
  case secureEventInput
  /// 機密アプリ
  case sensitiveApp
  /// 利用者が除外したアプリ
  case excludedApp
  /// 判定に必要な情報が取れない（安全側に倒す）
  case undetermined
}

/// 録音・クラウド送信・履歴保存それぞれの可否。
public struct SensitiveInputDecision: Hashable, Sendable {
  public let allowsRecording: Bool
  public let allowsCloudTransmission: Bool
  public let allowsHistory: Bool
  /// 抑止した理由。該当するものをすべて含む。許可なら空
  public let reasons: Set<SensitiveInputReason>

  static let allowed = SensitiveInputDecision(
    allowsRecording: true, allowsCloudTransmission: true, allowsHistory: true, reasons: [])

  static func suppressed(_ reasons: Set<SensitiveInputReason>) -> SensitiveInputDecision {
    SensitiveInputDecision(
      allowsRecording: false, allowsCloudTransmission: false, allowsHistory: false,
      reasons: reasons)
  }
}

/// パスワード欄・機密アプリ・利用者指定の除外アプリで、録音・送信・履歴を抑止する判定（7章, AC-12）。
///
/// セキュア属性の入力欄とシステムのセキュア入力状態を併用し、どちらかに該当するか判定できなければ抑止する。
/// アプリの識別子（bundle ID は ASCII の逆 DNS を前提）は前後の空白を除き、大文字・小文字を区別せずに照合する。
///
/// 呼び出し側の契約: 録音の開始時に判定し、抑止なら録音しない。クラウド送信・履歴保存・挿入の直前にも
/// その時点の入力先で判定し直し、抑止になったら送信・履歴保存をせず、挿入はプレビューへ退避する（AC-09）。
public struct SensitiveInputPolicy: Hashable, Sendable {
  /// 機密アプリ（パスワード管理アプリなど）。既定は空。照合用に正規化済みのため、表示・保存には元の設定値を使う
  public let sensitiveApps: Set<String>
  /// 利用者が除外したアプリ。照合用に正規化済みのため、表示・保存には元の設定値を使う
  public let excludedApps: Set<String>

  public init(sensitiveApps: Set<String> = [], excludedApps: Set<String> = []) {
    self.sensitiveApps = Set(sensitiveApps.compactMap(Self.normalized))
    self.excludedApps = Set(excludedApps.compactMap(Self.normalized))
  }

  /// 前後の空白を除いて小文字にする。空になれば `nil`。
  static func normalized(_ app: String) -> String? {
    let trimmed = app.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
    return trimmed.isEmpty ? nil : String(trimmed).lowercased()
  }

  public func decide(_ context: SensitiveInputContext) -> SensitiveInputDecision {
    var reasons: Set<SensitiveInputReason> = []
    switch context.secureField {
    case .on: reasons.insert(.secureField)
    case .unknown: reasons.insert(.undetermined)
    case .off: break
    }
    switch context.secureEventInput {
    case .on: reasons.insert(.secureEventInput)
    case .unknown: reasons.insert(.undetermined)
    case .off: break
    }
    if let app = context.app.flatMap(Self.normalized) {
      if sensitiveApps.contains(app) {
        reasons.insert(.sensitiveApp)
      }
      if excludedApps.contains(app) {
        reasons.insert(.excludedApp)
      }
    } else {
      reasons.insert(.undetermined)
    }
    return reasons.isEmpty ? .allowed : .suppressed(reasons)
  }
}
