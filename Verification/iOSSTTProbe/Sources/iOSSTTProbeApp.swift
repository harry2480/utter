import SwiftUI

/// Phase i0 検証（#54）: iOS の STT・メモリ・発熱を実機で計測する使い捨てアプリ。
@main
struct IOSSTTProbeApp: App {
  @State private var model = ProbeModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .task { await model.onAppear() }
    }
  }
}
