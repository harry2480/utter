import Foundation

/// 初回セットアップについて覚えておく値（#198）。今の手順・終えたか・整形の実行先の選択だけで、秘密情報・発話は置かない。
///
/// 途中で閉じても次の起動で続きから始めるため、進むたびに保存する。
@MainActor
final class FirstRunSetupDefaults {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 進み具合。保存していない・知らない値なら最初の手順から
  var progress: FirstRunSetupProgress {
    get {
      let stored = defaults.string(forKey: Key.currentStep)
      let current = stored.flatMap(FirstRunSetupStep.init(rawValue:)) ?? .microphone
      let isFinished = defaults.bool(forKey: Key.finished)
      return FirstRunSetupProgress(current: current, isFinished: isFinished)
    }
    set {
      defaults.set(newValue.current.rawValue, forKey: Key.currentStep)
      defaults.set(newValue.isFinished, forKey: Key.finished)
    }
  }

  /// 整形の実行先の手順での選択。まだ選んでいなければ `nil`
  var refinementDecision: FirstRunRefinementDecision? {
    get {
      let stored = defaults.string(forKey: Key.refinementDecision)
      return stored.flatMap(FirstRunRefinementDecision.init(rawValue:))
    }
    set { defaults.set(newValue?.rawValue, forKey: Key.refinementDecision) }
  }

  /// 保存に使う名前。変えない
  private enum Key {
    static let currentStep = "firstRunSetup.currentStep"
    static let finished = "firstRunSetup.finished"
    static let refinementDecision = "firstRunSetup.refinementDecision"
  }
}
