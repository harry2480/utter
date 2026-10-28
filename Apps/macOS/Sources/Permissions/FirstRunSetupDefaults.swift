import Foundation

/// 初回セットアップについて覚えておく値（#198）。今の手順・最後まで進めたか・飛ばした手順・整形の実行先を選んだかだけで、
/// 秘密情報・発話は置かない。
///
/// 途中で閉じても次の起動で続きから始めるため、進むたびに保存する。
@MainActor
final class FirstRunSetupDefaults {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 進み具合。保存していない・知らない値なら最初の手順から（最後まで進めた後なら、まとめの表示から）
  var progress: FirstRunSetupProgress {
    get {
      let isFinished = defaults.bool(forKey: Key.finished)
      let raw = defaults.string(forKey: Key.currentStep)
      let stored = raw.flatMap(FirstRunSetupStep.init(rawValue:))
      let fallback: FirstRunSetupStep? = isFinished ? nil : .microphone
      let current = stored ?? fallback
      return FirstRunSetupProgress(current: current, isFinished: isFinished)
    }
    set {
      defaults.set(newValue.current?.rawValue, forKey: Key.currentStep)
      defaults.set(newValue.isFinished, forKey: Key.finished)
    }
  }

  /// 「あとで」で飛ばした手順。済ませた後も残るが、状態の表示は済みを優先する
  var deferredSteps: Set<FirstRunSetupStep> {
    get {
      let stored = defaults.stringArray(forKey: Key.deferredSteps) ?? []
      return Set(stored.compactMap(FirstRunSetupStep.init(rawValue:)))
    }
    set {
      let values = FirstRunSetupStep.allCases.filter(newValue.contains).map(\.rawValue)
      defaults.set(values, forKey: Key.deferredSteps)
    }
  }

  /// 整形の実行先をこの画面で選んで保存したか
  var hasChosenRefinement: Bool {
    get { defaults.bool(forKey: Key.refinementChosen) }
    set { defaults.set(newValue, forKey: Key.refinementChosen) }
  }

  /// 保存に使う名前。変えない
  private enum Key {
    static let currentStep = "firstRunSetup.currentStep"
    static let finished = "firstRunSetup.finished"
    static let deferredSteps = "firstRunSetup.deferredSteps"
    static let refinementChosen = "firstRunSetup.refinementChosen"
  }
}
