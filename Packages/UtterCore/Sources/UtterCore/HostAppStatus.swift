/// 録音・認識・整形に関わる本体アプリの状態（iAC-07）。本体アプリが OS の状態から作る。
///
/// 秘密情報・本文は持たない。キーボード拡張へ渡す場合も、観測した時点の値として扱う。
public struct HostAppStatus: Hashable, Sendable {
  /// 拒否されている権限
  public var deniedPermissions: Set<HostAppPermission>
  public var speechModel: SpeechModelAvailability
  public var network: NetworkReachability
  /// 整形にクラウド AI を使う設定か
  public var usesCloudRefinement: Bool

  public init(
    deniedPermissions: Set<HostAppPermission>,
    speechModel: SpeechModelAvailability,
    network: NetworkReachability,
    usesCloudRefinement: Bool
  ) {
    self.deniedPermissions = deniedPermissions
    self.speechModel = speechModel
    self.network = network
    self.usesCloudRefinement = usesCloudRefinement
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

public enum NetworkReachability: Hashable, Sendable {
  case online
  case offline
}
