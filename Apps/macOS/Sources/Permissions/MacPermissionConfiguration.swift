import UtterCore

/// macOS アプリで有効にする機能と、機能ごとに要る権限（PERM-01）。
///
/// Phase 0 の判定待ちの値（#48 / #41 / #51）は UtterCore に既定値を持たせず、ここで渡す。
/// 判定が出たら `requirements` だけを書き換える。
struct MacPermissionConfiguration {
  /// 利用者が有効にしている機能。修飾キー単独のショートカット・Esc の捕捉は #51 の判定まで使わない（`.keyCombinationsOnly`）ため含めない
  var features: Set<AppFeature>
  var requirements: PermissionRequirements

  /// 判定前の構成。
  ///
  /// - 音声認識（#48）: 判定前は要求しない。要らないかもしれない権限を求めない（PERM-01）側に倒す。
  ///   macOS の STT は STT Worker で動かし、既定のエンジンも判定待ちで未選択のため、要るのに求めない場合の影響はない
  /// - 挿入経路（#41）: 入力欄への直接挿入（AX）だけ、アクセシビリティを渡す（AX の API は許可なしでは使えないため、判定を待たずに決まる。
  ///   初回セットアップのアクセシビリティの手順, #198）。貼り付け・キー入力の経路は要る権限が #41 の判定待ちのため渡さず、
  ///   オンボーディングでは「確認中」として示し要求しない
  /// - 修飾キー単独・Esc（#51）: 機能を有効にしないため、要る権限は使われない
  static let phase0Pending = MacPermissionConfiguration(
    features: [
      .recording, .insertion(.accessibility), .insertion(.pasteboard), .insertion(.keyEvents),
    ],
    requirements: PermissionRequirements(
      transcription: [], insertionRoutes: [.accessibility: [.accessibility]],
      modifierOnlyShortcut: [], escapeCancel: []))
}
