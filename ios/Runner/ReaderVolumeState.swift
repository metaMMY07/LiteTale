/// Pure event policy shared by the device bridge and its executable checks.
/// iOS reports output volume, not a consumable hardware-button event.
struct ReaderVolumeState {
  enum Direction: String { case up = "UP", down = "DOWN" }
  static let tolerance: Float = 0.000001
  let originalVolume: Float
  let baseline: Float
  private var lastVolume: Float

  init(originalVolume: Float) {
    let volume = originalVolume.isFinite ? min(1, max(0, originalVolume)) : 0.5
    self.originalVolume = volume
    // Leave tiny headroom at the two limits, instead of changing the user's
    // audio by a whole hardware step before they have pressed anything.
    baseline = min(0.9999, max(0.0001, volume))
    lastVolume = volume
  }

  mutating func observe(oldVolume: Float?, newVolume: Float) -> Direction? {
    guard newVolume.isFinite else { return nil }
    let previous = oldVolume.flatMap { $0.isFinite ? $0 : nil } ?? lastVolume
    lastVolume = newVolume
    // A restoration can be delayed or repeated. It must never become an
    // opposite-direction page key just because 250 milliseconds elapsed.
    guard abs(newVolume - baseline) > Self.tolerance else { return nil }
    let delta = newVolume - previous
    if delta > Self.tolerance { return .up }
    if delta < -Self.tolerance { return .down }
    return nil
  }
}
