import Foundation
import Speech

/// SpeechAnalyzer（SpeechTranscriber）の音声認識モデルの取得状態（PERM-03）。
public enum SpeechModelAvailability: Hashable, Sendable {
  /// この端末・ロケールでは使えない
  case unsupported
  /// 対応しているが、モデルを取得していない
  case notInstalled
  /// 取得中
  case downloading
  /// 取得済みで、すぐに使える
  case installed

  init(_ status: AssetInventory.Status) {
    switch status {
    case .unsupported: self = .unsupported
    case .supported: self = .notInstalled
    case .downloading: self = .downloading
    case .installed: self = .installed
    @unknown default: self = .unsupported
    }
  }
}

/// SpeechAnalyzer の音声認識モデル（OS が管理するアセット）の状態の確認と、取得の要求（PERM-03）。
///
/// 認識（`SpeechAnalyzerRecognizer`）はモデルを取得しない。未取得なら `failed(.modelUnavailable)` で終える。
/// 取得はネットワークを使うため、`install()` を利用者の明示的な操作（設定画面の「取得」ボタンなど）を起点にだけ呼ぶ。
/// モデルは Apple のサーバーから OS が取得・保存・削除する（取得元の表示は呼び出し側の責務）。
public struct SpeechAnalyzerAssets: Sendable {
  public let locale: Locale

  public init(locale: Locale = SpeechAnalyzerRecognizer.defaultLocale) {
    self.locale = locale
  }

  /// 現在の取得状態。ネットワークは使わない。
  public func availability() async -> SpeechModelAvailability {
    guard SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else { return .unsupported }
    let transcriber = SpeechAnalyzerSession.makeTranscriber(locale: supported)
    return SpeechModelAvailability(await AssetInventory.status(forModules: [transcriber]))
  }

  /// モデルを取得する。取得済みなら何もしない。利用者の明示的な操作を起点にだけ呼ぶ（ネットワークを使う）。
  ///
  /// - Throws: 対応していない・取得に失敗した場合は `SpeechRecognitionError`、タスクがキャンセルされたら `CancellationError`
  public func install() async throws {
    guard SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else { throw SpeechRecognitionError.modelUnavailable }
    // ロケールを予約しないと取得したアセットを OS が削除しうる。予約できなくても取得の要求の側で扱われる場合があるため続ける
    // （Probe の install と同じ扱い）
    let reserved = await AssetInventory.reservedLocales
    if !reserved.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) {
      _ = try? await AssetInventory.reserve(locale: supported)
    }
    try Task.checkCancellation()
    let transcriber = SpeechAnalyzerSession.makeTranscriber(locale: supported)
    do {
      guard
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
      else { return }
      try await request.downloadAndInstall()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TranscriptionRun.classify(error)
    }
  }

  /// このアプリが `install()` でしたロケールの予約を解除する（PERM-03, #199）。ネットワークは使わない。
  ///
  /// 公開 API（`AssetInventory`）には、取得したモデルをアプリからすぐに削除する方法がない。予約を解除すると、
  /// ほかのアプリが使っていなければ macOS が後で削除する（すぐには消えず、消えるまでは認識に使える）。
  /// `reservedLocales` は `reserve(locale:)` に渡したロケールの variant を返しうるため、識別子の完全一致がなければ
  /// 言語と地域、次に言語が同じ予約を解除する（utter が予約するのは認識に使う1つのロケールだけ）。
  /// - Returns: 予約を解除したら `true`。予約していない・この端末で使えない場合は `false`
  public func releaseReservation() async -> Bool {
    guard SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else { return false }
    let reserved = await AssetInventory.reservedLocales
    guard let match = Self.reservation(matching: supported, in: reserved) else { return false }
    // 確かめてから解除するまでに予約が消えていれば `false`（予約していなかった）
    return await AssetInventory.release(reservedLocale: match)
  }

  /// `locale` に対応する予約。識別子が同じもの、言語と地域が同じもの、言語が同じものの順に探す
  static func reservation(matching locale: Locale, in reserved: [Locale]) -> Locale? {
    let target = locale.identifier(.bcp47)
    if let exact = reserved.first(where: { $0.identifier(.bcp47) == target }) {
      return exact
    }
    let sameLanguage = reserved.filter {
      $0.language.languageCode != nil && $0.language.languageCode == locale.language.languageCode
    }
    return sameLanguage.first(where: { $0.region == locale.region }) ?? sameLanguage.first
  }
}
