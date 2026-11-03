/// Runs the production event policy with Swift on the macOS device builder.
/// These checks do not simulate MPVolumeView or replace physical-device tests.
@main struct ReaderVolumePolicyChecks {
  static func main() {
    var ordinary = ReaderVolumeState(originalVolume: 0.5)
    precondition(ordinary.observe(oldVolume: 0.5, newVolume: 0.5625) == .up)
    precondition(ordinary.observe(oldVolume: 0.5625, newVolume: 0.5) == nil)
    precondition(ordinary.observe(oldVolume: 0.5, newVolume: 0.4375) == .down)
    precondition(ordinary.observe(oldVolume: 0.4375, newVolume: 0.5) == nil)

    var burst = ReaderVolumeState(originalVolume: 0.5)
    precondition(burst.observe(oldVolume: 0.5, newVolume: 0.5625) == .up)
    precondition(burst.observe(oldVolume: 0.5625, newVolume: 0.625) == .up)
    // Delayed or duplicated restoration must never become a DOWN press.
    precondition(burst.observe(oldVolume: 0.625, newVolume: 0.5) == nil)
    precondition(burst.observe(oldVolume: 0.625, newVolume: 0.5) == nil)

    var muted = ReaderVolumeState(originalVolume: 0)
    precondition(muted.originalVolume == 0 && muted.baseline < 0.001)
    precondition(muted.observe(oldVolume: 0, newVolume: muted.baseline) == nil)
    precondition(muted.observe(oldVolume: muted.baseline, newVolume: 0) == .down)
    precondition(muted.observe(oldVolume: 0, newVolume: muted.baseline) == nil)

    var maximum = ReaderVolumeState(originalVolume: 1)
    precondition(maximum.originalVolume == 1 && maximum.baseline > 0.999)
    precondition(maximum.observe(oldVolume: 1, newVolume: maximum.baseline) == nil)
    precondition(maximum.observe(oldVolume: maximum.baseline, newVolume: 1) == .up)
    precondition(maximum.observe(oldVolume: 1, newVolume: maximum.baseline) == nil)

    var missingOld = ReaderVolumeState(originalVolume: 0.4)
    precondition(missingOld.observe(oldVolume: nil, newVolume: 0.45) == .up)
    precondition(missingOld.observe(oldVolume: nil, newVolume: 0.4) == nil)
    precondition(missingOld.observe(oldVolume: nil, newVolume: 0.35) == .down)
    precondition(missingOld.observe(oldVolume: 0.35, newVolume: .nan) == nil)

    var newRoute = ReaderVolumeState(originalVolume: 0.7)
    precondition(newRoute.originalVolume == 0.7)
    precondition(newRoute.observe(oldVolume: 0.7, newVolume: 0.65) == .down)
    precondition(newRoute.observe(oldVolume: 0.65, newVolume: 0.7) == nil)
    print("ReaderVolumeState: 6 event scenarios passed (hardware not simulated).")
  }
}
