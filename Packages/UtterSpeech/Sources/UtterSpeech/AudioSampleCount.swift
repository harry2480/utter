/// 時間とサンプル数の換算。
enum AudioSampleCount {
  /// `duration` に収まるサンプル数。1サンプルに満たなければ 1。
  /// 浮動小数点の誤差で1サンプル少なくならないよう、整数で計算する
  static func samples(in duration: Duration, sampleRate: Int) -> Int {
    let (seconds, attoseconds) = duration.components
    let rate = Int128(max(0, sampleRate))
    let count = Int128(seconds) * rate + Int128(attoseconds) * rate / 1_000_000_000_000_000_000
    return Int(max(1, min(count, Int128(Int.max / 2))))
  }
}
