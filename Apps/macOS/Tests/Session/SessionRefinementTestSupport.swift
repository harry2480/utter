import Foundation
import Synchronization
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// Claude API への送信を数える送信部。実ネットワークには出ず、決めた応答を返す。
final class CountingTransport: HTTPTransport {
  enum Reply: Sendable {
    case success(text: String)
    case status(Int)
  }

  private let reply: Reply
  private let sent = Mutex<[URLRequest]>([])

  init(_ reply: Reply = .success(text: "明日の会議は10時からです。")) {
    self.reply = reply
  }

  /// 送られたリクエストの数
  var count: Int { sent.withLock { $0.count } }

  /// 送られた本文（UTF-8）
  var bodies: [String] {
    sent.withLock { $0.compactMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } } }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    sent.withLock { $0.append(request) }
    let status: Int
    let body: String
    switch reply {
    case .success(let text):
      status = 200
      body = """
        {"id":"msg_1","type":"message","role":"assistant","model":"m",
         "content":[{"type":"text","text":"\(text)"}],
         "stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":15}}
        """
    case .status(let code):
      status = code
      body = #"{"type":"error","error":{"type":"api_error","message":"failed"}}"#
    }
    let url = try #require(request.url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (Data(body.utf8), response)
  }
}

/// 整形の条件（処理系・同意・API キー・予算）をそろえた設定。
enum RefinementSettings {
  /// 2026-10-25 12:00（UTC）
  static let now: Date = {
    var components = DateComponents(year: 2026, month: 10, day: 25, hour: 12)
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
  }()

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    return calendar
  }

  /// クラウド整形の条件がすべてそろった設定
  static func ready(
    mode: RefinementModeSetting = .natural,
    budgetLimit: Decimal = 10,
    historyEnabled: Bool = false,
    excludedApps: [String] = []
  ) -> AppSettings {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    return AppSettings(
      refinementMode: mode,
      refinementEngine: .cloudAI,
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [
          ModelPriceSetting(
            model: AppSettings.defaultRefinementModel, inputPerMillionTokens: 1,
            outputPerMillionTokens: 5)
        ].compactMap { $0 }),
      monthlyBudget: MonthlyBudgetSetting(limitAmount: budgetLimit, currencyCode: "USD"),
      consentState: consent,
      historyEnabled: historyEnabled,
      excludedApps: excludedApps)
  }

  /// 保存済みの API キー
  static func apiKeyStore() -> StubAPIKeyStore {
    StubAPIKeyStore(key: try? APIKey("sk-test-secret"))
  }
}

extension RefinementModeSetting {
  init(_ mode: RefinementMode) {
    switch mode {
    case .raw: self = .raw
    case .natural: self = .natural
    case .structured: self = .structured
    }
  }
}

/// 整形の経路を記録する。
@MainActor
final class StubRefinementReporter: SessionRefinementReporting {
  private(set) var routes: [SessionRefinementRoute] = []

  func refinementFinished(_ route: SessionRefinementRoute, session: SessionID) {
    routes.append(route)
  }
}
