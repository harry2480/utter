import Foundation
import Observation
import UtterAI
import UtterPersistence

/// iOS ホームの文体の切り替えと、整形先・認識先の表示（TXT-01, AC-06, #201）。
///
/// 文体は `AppSettingsStore`（版 2 の `refinementMode`）に保存する。整形と予算の画面・同意の画面と同じ保存先を渡し、
/// 保存の基準には保存先の最新の値を使って、ほかの画面の項目を残す。整形先は保存済みの処理系と同意から表示するだけで、
/// 送信はしない（送信の可否は `CloudRefinement` が送信の直前に決める）。
@MainActor
@Observable
public final class HomeSettingsModel {
  /// 選んでいる文体
  public private(set) var style: RefinementMode
  /// 認識の行き先
  public let speechDestination: ProcessingDestination
  /// 直前の文体の保存に失敗した（書き込めなかった）か
  public private(set) var saveFailed = false

  /// 最後に読み込んだ・保存した設定
  private var settings: AppSettings
  @ObservationIgnored private let store: AppSettingsStore

  /// - Parameters:
  ///   - store: 設定の保存先。クラウド整形・整形と予算の画面・同意の画面と同じものを渡す
  ///   - speechEngine: 使う STT エンジン
  public init(store: AppSettingsStore, speechEngine: SpeechEngineSelection) {
    self.store = store
    let settings = store.load()
    self.settings = settings
    style = RefinementMode(settings.refinementMode)
    speechDestination = ProcessingDestination(speechEngine: speechEngine)
  }

  /// 選んでいる文体のときの整形先
  public var refinementDestination: ProcessingDestination {
    refinementDestination(for: style)
  }

  /// 指定した文体のときの整形先（録音中のチップは、録音を始めたときの文体で出す）
  public func refinementDestination(for mode: RefinementMode) -> ProcessingDestination {
    ProcessingDestination(refinementFor: mode, settings: settings)
  }

  /// 保存済みの値を読み直す。設定を閉じたとき・前面に来たときに呼び、ほかの画面で変わった値を反映する
  public func reload() {
    settings = store.load()
    style = RefinementMode(settings.refinementMode)
    saveFailed = false
  }

  /// 文体を選んで保存する。保存できなければ選ぶ前の文体のままにする
  public func select(_ style: RefinementMode) {
    var latest = store.load()
    latest.refinementMode = RefinementModeSetting(style)
    do {
      try store.save(latest)
    } catch {
      saveFailed = true
      return
    }
    settings = latest
    self.style = style
    saveFailed = false
  }
}
