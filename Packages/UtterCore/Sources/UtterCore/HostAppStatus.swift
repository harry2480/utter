import Foundation

/// 録音・認識・整形に関わる本体アプリの状態（iAC-07）。本体アプリが OS の状態から作る。
///
/// 秘密情報・本文は持たない。キーボード拡張では観測時刻から鮮度を判定し、古ければ使わない。
/// ネットワークは古くなりやすいため持たず、拡張側で観測する（`KeyboardEnvironment.network`）。
public struct HostAppStatus: Hashable, Sendable {
  /// 本体アプリがこの状態を観測した時刻。端末の再起動をまたいで判定するため実時刻で持つ
  public var observedAt: Date
  /// 拒否されている権限
  public var deniedPermissions: Set<HostAppPermission>
  public var speechModel: SpeechModelAvailability
  /// 整形にクラウド AI を使う設定か
  public var usesCloudRefinement: Bool

  public init(
    observedAt: Date,
    deniedPermissions: Set<HostAppPermission>,
    speechModel: SpeechModelAvailability,
    usesCloudRefinement: Bool
  ) {
    self.observedAt = observedAt
    self.deniedPermissions = deniedPermissions
    self.speechModel = speechModel
    self.usesCloudRefinement = usesCloudRefinement
  }

  /// `now` の時点で、観測から `maximumAge` 以内か。観測時刻が `now` より後（時刻の巻き戻り）なら判定できないため古いとみなす
  public func isFresh(at now: Date, maximumAge: Duration) -> Bool {
    let components = maximumAge.components
    let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    return (observedAt...observedAt.addingTimeInterval(max(seconds, 0))).contains(now)
  }
}

/// 本体アプリが録音・認識に使う権限。
public enum HostAppPermission: Hashable, Sendable, CaseIterable {
  case microphone
  /// 音声認識（使う STT が要求する場合）
  case speechRecognition
}

/// 端末内 STT モデルの取得状況。
public enum SpeechModelAvailability: Hashable, Sendable {
  case ready
  /// 未取得（取得中・取得失敗を含む）。取得するまで認識できない
  case notDownloaded
}
