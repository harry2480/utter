import UtterCore
import UtterPersistence

/// キーボードに表示する文言。判定は UtterCore / UtterPersistence が行い、ここは表示する文字列にするだけ。
///
/// 本文は含めない（プレビューの本文は画面に表示するだけで、ここでは扱わない）。
enum KeyboardMessages {
  static func notice(_ notice: KeyboardNotice) -> String {
    let message: String
    switch notice {
    case .restrictedInputField(let restrictions):
      message = "\(restrictionDescription(restrictions))では、音声入力の結果を挿入しません。"
    case .fullAccessRequired:
      message = "フルアクセスが無効なため、本体アプリの結果を読めません。"
    case .sharedContainerUnavailable:
      message = "本体アプリの結果を読めません（App Group の署名・設定の不備）。"
    case .sharingNotConfigured:
      message = "このビルドでは本体アプリでの共有が未設定のため、結果を表示しません。"
    case .permissionDenied(let permission):
      message = "本体アプリで\(permissionName(permission))が許可されていないため、録音・認識できません。"
    case .speechModelNotDownloaded:
      message = "音声認識モデルが未取得のため、認識できません。"
    case .speechModelNotDownloadedOffline:
      message = "音声認識モデルが未取得で、オフラインのため取得もできません。"
    case .cloudRefinementOffline:
      message = "オフラインのため、クラウド AI では整形できません（端末内で整形します）。"
    }
    let remedies = notice.remedies.map(remedy)
    return ([message] + remedies.map { "→ \($0)" }).joined(separator: "\n")
  }

  static func remedy(_ remedy: KeyboardRemedy) -> String {
    switch remedy {
    case .switchToSystemKeyboard:
      "地球儀キーで標準キーボードに切り替えてください"
    case .enableFullAccess:
      "設定 > 一般 > キーボード > キーボード > utter で「フルアクセスを許可」をオンにしてください"
    case .reinstallWithValidSigning:
      "本体アプリとキーボードを、App Group を含む同じ署名で入れ直してください"
    case .rebuildWithAppGroup:
      "Config/Local.xcconfig で App Group を設定してビルドし直してください"
    case .allowPermission(let permission):
      "設定 > utter で\(permissionName(permission))を許可してください"
    case .downloadSpeechModel:
      "本体アプリで音声認識モデルを取得してください"
    case .connectToNetwork:
      "ネットワークに接続してください"
    }
  }

  static func preview(_ preview: SharedResultPreview) -> String {
    switch preview {
    case .notFound:
      "本体アプリの結果はありません。"
    case .insertable:
      "本体アプリの結果です。挿入先を確かめてから「挿入」を押してください。"
    case .needsConfirmation:
      "前回の挿入を確認できませんでした。入力欄に入っていなければ「再挿入」を押してください。"
    case .notInsertable(let reason):
      notInsertable(reason)
    }
  }

  static let previewLoading = "本体アプリの結果を読み込んでいます…"

  static let previewLoadFailed = "本体アプリの結果を読めませんでした。「更新」で読み直してください。"

  static func outcome(_ outcome: SharedResultInsertionOutcome?) -> String {
    switch outcome {
    case .inserted:
      "挿入しました。"
    case .insertionUnknown:
      "挿入を確認できませんでした。入力欄を確かめてください（自動では再挿入しません）。"
    case .notInserted(let reason):
      notInsertable(reason)
    case .notFound:
      "本体アプリの結果はありません。"
    case nil:
      "結果を読み書きできなかったため、挿入していません。"
    }
  }

  static let restrictedAtInsertion = "この入力欄では挿入しません。地球儀キーで標準キーボードに切り替えてください。"

  /// 本体アプリへの移動と、元のアプリへの手動復帰の案内（iOS-03, iAC-05）
  static let hostAppGuide =
    "音声入力は本体アプリ「utter」で録音します。画面下端を左右にスワイプするか App スイッチャーで utter に切り替え、"
    + "録音が終わったらこのアプリに戻って utter キーボードから挿入してください。"

  /// 共有結果を表示できない状態での案内。キーボードから挿入できるとは書かない
  static let hostAppGuideWithoutSharing =
    "音声入力は本体アプリ「utter」で録音します。画面下端を左右にスワイプするか App スイッチャーで utter に切り替えてください。"

  static let hostAppOpenFailed = "本体アプリを開けませんでした。上の手順で手動で切り替えてください。"

  private static func notInsertable(_ reason: SharedResultInsertability) -> String {
    switch reason {
    case .insertable, .needsConfirmation:
      "挿入できます。"
    case .expired:
      "結果の有効期限が切れたため、挿入しません。本体アプリでもう一度録音してください。"
    case .consumed:
      "この結果は挿入済みです。"
    case .sessionMismatch:
      "待っている録音の結果ではないため、挿入しません。"
    case .inProgress:
      "挿入中です。"
    case .invalidTimestamp:
      "端末の時刻が結果の作成時より前のため、挿入しません。"
    }
  }

  private static func restrictionDescription(_ restrictions: Set<KeyboardFieldRestriction>)
    -> String
  {
    if restrictions.contains(.secureTextEntry) {
      return "パスワードなどの入力欄"
    }
    if restrictions.contains(.phoneNumber) {
      return "電話番号の入力欄"
    }
    return "種類を確認できない入力欄"
  }

  private static func permissionName(_ permission: HostAppPermission) -> String {
    switch permission {
    case .microphone: "マイク"
    case .speechRecognition: "音声認識"
    }
  }
}
