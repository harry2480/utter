import Testing
import UtterCore

@testable import UtterAI

/// 応答検証が受け入れるべき整形の評価セット（4.1節, TXT-02）。
///
/// 応答検証の閾値（4.1節）を決めるため、`NoAnswerEvaluationSet`（弾くべき応答）と対にして使う。
/// 整形後の文は手書きの模範出力で、実際のクラウド AI の応答ではない。
/// 発話と整形後の文は架空の文で、実在の個人情報や実際の発話を含めない。
struct AcceptableRefinementSample: Sendable, CustomTestStringConvertible {
  /// 整形の種類。閾値のどの検査に近づくかの観点で分ける
  enum Kind: Hashable, Sendable, CaseIterable {
    /// フィラー（えー、あのー）の大幅な削除。文字数比の下限に近づく
    case fillerRemoval
    /// Structured の箇条書き化・番号付け。記号と改行が増え、述語が落ちる
    case structuring
    /// 自己訂正で言い直す前の語を除いて短くなる
    case selfCorrection
    /// 丁寧体化・敬語化で長くなる。文字数比の上限と、重なりの割合の下限に近づく
    case politeExpansion
    /// 数字・URL・コード・辞書語を含む。保護対象の検査に当たる
    case protectedContent
    /// 日本語と英語の混在、英語のみの発話
    case mixedLanguage
    /// Raw の出力（発話そのまま）。Raw はクラウドに送らないが、退避先の結果として検証を通ることを確かめる
    case passthrough
  }

  /// 評価セット内で一意な識別子。テストの表示名に使う（本文は表示名に出さない）
  let id: String
  let kind: Kind
  let mode: RefinementMode
  let style: RefinementStyle
  /// 発話の STT テキスト
  let utterance: String
  /// 整形として妥当な応答（手書きの模範出力）
  let refined: String
  let dictionaryTerms: [String]

  init(
    _ id: String, _ kind: Kind, _ mode: RefinementMode, style: RefinementStyle = .standard,
    utterance: String, refined: String, dictionaryTerms: [String] = []
  ) {
    self.id = id
    self.kind = kind
    self.mode = mode
    self.style = style
    self.utterance = utterance
    self.refined = refined
    self.dictionaryTerms = dictionaryTerms
  }

  var request: RefinementRequest {
    RefinementRequest(text: utterance, mode: mode, style: style, dictionaryTerms: dictionaryTerms)
  }

  var testDescription: String { id }
}

/// 整形として妥当でも、既定の応答検証が棄却する整形（4.1節）。
///
/// 閾値（`RefinementValidationConfiguration`）では直せない検査に当たるもので、既知の問題として記録する。
/// 受け入れられるようになったらテストが知らせるため、そのときは `samples` へ移す。
struct FalselyRejectedRefinement: Sendable, CustomTestStringConvertible {
  let id: String
  let utterance: String
  let refined: String
  /// 現在棄却している検査
  let failure: RefinementValidationFailure
  /// 閾値で直せない理由
  let reason: String

  var testDescription: String { id }
}

enum AcceptableRefinementEvaluationSet {
  /// 1区分あたりの最小件数（暫定）
  static let minimumSamplesPerKind = 3

  static let samples: [AcceptableRefinementSample] =
    fillerRemovals + structurings + selfCorrections + politeExpansions + protectedContents
    + mixedLanguages + passthroughs

  static let fillerRemovals: [AcceptableRefinementSample] = [
    .init(
      "F01", .fillerRemoval, .natural,
      utterance: "えーとあのー明日の会議なんですけどえーまあちょっと遅れるかもしれないです",
      refined: "明日の会議ですが、少し遅れるかもしれません。"),
    .init(
      "F02", .fillerRemoval, .natural,
      utterance: "あのーそのーえっとーですねー資料はえー共有フォルダに入れておきました",
      refined: "資料は共有フォルダに入れておきました。"),
    .init(
      "F03", .fillerRemoval, .natural, style: .concise,
      utterance: "うーんなんていうかまあえーとーとりあえず了解です",
      refined: "とりあえず了解です。"),
    // ほぼすべてがフィラーの発話。文字数比の下限の境界
    .init(
      "F04", .fillerRemoval, .natural, style: .concise,
      utterance: "えーっとあのーうーんそうですねーまあはい",
      refined: "はい。"),
    .init(
      "F05", .fillerRemoval, .structured,
      utterance: "えーっとですねえー今日やることはあのーメールの返信とえー資料作成とまあ会議の準備です",
      refined: "今日やること\n- メールの返信\n- 資料作成\n- 会議の準備"),
    .init(
      "F06", .fillerRemoval, .natural,
      utterance: "um so like basically I think we should uh ship it on Friday you know",
      refined: "I think we should ship it on Friday."),
  ]

  static let structurings: [AcceptableRefinementSample] = [
    .init(
      "B01", .structuring, .structured, style: .document,
      utterance: "今日の議事録ですけど予算は承認されて次回は来週金曜で担当は鈴木さんです",
      refined: "今日の議事録\n- 予算は承認\n- 次回は来週金曜\n- 担当は鈴木さん"),
    // 漢数字の序数を数字の番号に置き換える（数字の追加は保護対象の検査で問題にしない）
    .init(
      "B02", .structuring, .structured,
      utterance: "やることは三つあって一つ目がテスト二つ目がレビュー三つ目がリリースです",
      refined: "やること\n1. テスト\n2. レビュー\n3. リリース"),
    .init(
      "B03", .structuring, .structured, style: .document,
      utterance: "買うものは牛乳と卵と食パンとあとバナナ",
      refined: "買うもの\n- 牛乳\n- 卵\n- 食パン\n- バナナ"),
    .init(
      "B04", .structuring, .structured, style: .document,
      utterance: "まず背景として既存の仕組みでは処理が遅いという問題がありますそこで今回はキャッシュを導入して応答時間を短くすることを提案します",
      refined: "背景\n既存の仕組みでは処理が遅いという問題があります。\n\n提案\nキャッシュを導入して応答時間を短くすることを提案します。"),
    .init(
      "B05", .structuring, .structured, style: .technical,
      utterance: "the agenda is budget review hiring and the roadmap",
      refined: "Agenda:\n- Budget review\n- Hiring\n- Roadmap"),
    // 箇条書き化しても文末の質問は残す
    .init(
      "B06", .structuring, .structured,
      utterance: "確認したいのは日程と場所と参加人数なんですがいつまでに決まりそうですか",
      refined: "確認したいこと\n- 日程\n- 場所\n- 参加人数\n\nいつまでに決まりそうですか？"),
  ]

  static let selfCorrections: [AcceptableRefinementSample] = [
    .init(
      "S01", .selfCorrection, .natural,
      utterance: "来週の月曜、いや火曜に打ち合わせをお願いします",
      refined: "来週の火曜に打ち合わせをお願いします。"),
    .init(
      "S02", .selfCorrection, .natural,
      utterance: "資料は田中さん、じゃなくて佐藤さんに送ってください",
      refined: "資料は佐藤さんに送ってください。"),
    .init(
      "S03", .selfCorrection, .natural,
      utterance: "えっと駅の東口、あ違う西口で待ち合わせしましょう",
      refined: "駅の西口で待ち合わせしましょう。"),
    .init(
      "S04", .selfCorrection, .structured,
      utterance: "持ち物はノートとペンと、あ、ペンじゃなくて鉛筆と、あと消しゴム",
      refined: "持ち物\n- ノート\n- 鉛筆\n- 消しゴム"),
    .init(
      "S05", .selfCorrection, .natural, style: .concise,
      utterance: "今回の件なんですけど最初はA案で進めようと思ってたんですけどやっぱりちょっと考え直してB案で進めることにしました",
      refined: "今回の件は、B案で進めることにしました。"),
  ]

  static let politeExpansions: [AcceptableRefinementSample] = [
    .init(
      "P01", .politeExpansion, .natural, style: .polite,
      utterance: "了解です明日送ります",
      refined: "承知しました。明日お送りいたします。"),
    .init(
      "P02", .politeExpansion, .natural, style: .polite,
      utterance: "資料見ました問題ないです",
      refined: "資料を拝見しました。問題ございません。"),
    // 重なりの割合の下限に最も近い
    .init(
      "P03", .politeExpansion, .natural, style: .polite,
      utterance: "それでいいです",
      refined: "それで問題ございません。"),
    .init(
      "P04", .politeExpansion, .natural, style: .polite,
      utterance: "明日休みます",
      refined: "明日はお休みをいただきます。"),
    .init(
      "P05", .politeExpansion, .natural, style: .polite,
      utterance: "その件ちょっと確認して後で連絡します",
      refined: "その件につきましては、確認のうえ、後ほどご連絡いたします。"),
    .init(
      "P06", .politeExpansion, .natural, style: .polite,
      utterance: "これ明日までにできる",
      refined: "こちらは明日までにできますか？"),
    .init(
      "P07", .politeExpansion, .natural, style: .polite,
      utterance: "見積もり送ったので見てください",
      refined: "お見積もりをお送りいたしましたので、ご確認いただけますと幸いです。"),
    // 文字数比の上限に最も近い
    .init(
      "P08", .politeExpansion, .natural, style: .polite,
      utterance: "会議室取れたか教えて",
      refined: "会議室が取れたかどうか、教えていただけますでしょうか。"),
  ]

  static let protectedContents: [AcceptableRefinementSample] = [
    .init(
      "N01", .protectedContent, .natural,
      utterance: "えー見積もりは120万円で納期は3月15日です",
      refined: "見積もりは120万円で、納期は3月15日です。"),
    .init(
      "N02", .protectedContent, .natural,
      utterance: "詳細は https://example.com/docs/setup を見てください",
      refined: "詳細は https://example.com/docs/setup をご覧ください。"),
    .init(
      "N03", .protectedContent, .natural, style: .command,
      utterance: "えっと `git status` を実行してから push してください",
      refined: "`git status` を実行してから push してください。"),
    .init(
      "N04", .protectedContent, .natural, style: .technical,
      utterance: "Utter の設定は GRDB に保存するようにしてえーテストも追加します",
      refined: "Utter の設定は GRDB に保存するようにして、テストも追加します。",
      dictionaryTerms: ["Utter", "GRDB"]),
    .init(
      "N05", .protectedContent, .structured,
      utterance: "手順はまず1番目にアプリを開いて2番目に設定を押して3番目に保存です",
      refined: "手順\n1. アプリを開く\n2. 設定を押す\n3. 保存する"),
    .init(
      "N06", .protectedContent, .structured, style: .command,
      utterance: "このコマンドを実行してください ```swift build``` そのあと ```swift test```",
      refined: "このコマンドを実行してください。\n```swift build```\nそのあと：\n```swift test```"),
    .init(
      "N07", .protectedContent, .natural, style: .technical,
      utterance: "iOS 26 で Swift 6.2 を使います",
      refined: "iOS 26 で Swift 6.2 を使います。"),
    // 全角数字を半角にそろえる（保護対象の検査は全角・半角を同一とみなす）
    .init(
      "N08", .protectedContent, .natural,
      utterance: "会議室は３階の３０２です",
      refined: "会議室は3階の302です。"),
    // STT がかなで出した語を辞書の表記にそろえる
    .init(
      "N09", .protectedContent, .natural, style: .technical,
      utterance: "くばねてぃすのクラスタを再起動します",
      refined: "Kubernetes のクラスタを再起動します。",
      dictionaryTerms: ["Kubernetes"]),
  ]

  static let mixedLanguages: [AcceptableRefinementSample] = [
    .init(
      "M01", .mixedLanguage, .natural, style: .concise,
      utterance: "明日の meeting は zoom でやりましょう",
      refined: "明日の meeting は Zoom でやりましょう。"),
    .init(
      "M02", .mixedLanguage, .natural, style: .technical,
      utterance: "えーこの PR の review お願いできますか",
      refined: "この PR のレビューをお願いできますか？"),
    // カタカナで出た英語の製品名を英字に戻す。重なりの割合が下がる
    .init(
      "M03", .mixedLanguage, .natural, style: .technical,
      utterance: "スウィフトユーアイで画面を作ります",
      refined: "SwiftUI で画面を作ります。"),
    .init(
      "M04", .mixedLanguage, .natural, style: .technical,
      utterance: "この API の rate limit っていくつですか",
      refined: "この API の rate limit はいくつですか？"),
    .init(
      "M05", .mixedLanguage, .natural, style: .polite,
      utterance: "thank you for the update 来週また連絡します",
      refined: "Thank you for the update. 来週また連絡します。"),
    .init(
      "M06", .mixedLanguage, .natural, style: .polite,
      utterance: "could you send me the slides by tomorrow",
      refined: "Could you send me the slides by tomorrow?"),
  ]

  static let passthroughs: [AcceptableRefinementSample] = [
    .init(
      "R01", .passthrough, .raw,
      utterance: "えーと明日の会議は10時からです",
      refined: "えーと明日の会議は10時からです"),
    .init(
      "R02", .passthrough, .raw,
      utterance: "明日の天気はどうですか",
      refined: "明日の天気はどうですか"),
    .init(
      "R03", .passthrough, .raw,
      utterance: "詳細は https://example.com/a を見て `make test` を実行して",
      refined: "詳細は https://example.com/a を見て `make test` を実行して"),
  ]

  /// 整形として妥当でも、既定の応答検証が棄却する整形。閾値を決めるとき（4.1節）の判断材料にする
  static let falselyRejected: [FalselyRejectedRefinement] = [
    FalselyRejectedRefinement(
      id: "X01", utterance: "会議は3時、いや4時からにしましょう",
      refined: "会議は4時からにしましょう。",
      failure: .protectedContentChanged,
      reason: "自己訂正で言い直す前の数字を除くと、保護対象の検査が数字の欠落とみなす。数字の保持は閾値ではなく保護対象の検査の規則"),
    FalselyRejectedRefinement(
      id: "X02", utterance: "予算は10000円です",
      refined: "予算は10,000円です。",
      failure: .protectedContentChanged,
      reason: "桁区切りの付与は、保護対象の検査が別の値として扱う。閾値ではなく保護対象の検査の規則"),
  ]
}
