import Flutter
import UIKit

/// A window snapshot includes both Flutter and UIKit platform views. A Flutter
/// RepaintBoundary alone cannot capture the native glass toolbar and tab bar.
final class AppleThemeReveal {
  static let shared = AppleThemeReveal()
  weak var button: UIView?
  private var overlay: UIView?
  private var origin = CGPoint.zero
  private var cleanup: DispatchWorkItem?
  private var channel: FlutterMethodChannel?

  func install(messenger: FlutterBinaryMessenger, window: @escaping () -> UIWindow?) {
    let channel = FlutterMethodChannel(name: "litetale/theme_reveal", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(false); return }
      switch call.method {
      case "prepare": result(self.prepare(window()))
      case "animate": self.animate(); result(nil)
      case "cancel": self.cancel(); result(nil)
      case "status": result(self.overlay != nil)
#if targetEnvironment(simulator)
      // drawHierarchy renders model layers. Freeze the actual compositor path
      // first so integration screenshots can observe an intermediate CA frame.
      case "freezeForCapture": result(self.freezeForCapture())
#endif
      case "details": result([
        "visible": self.overlay != nil,
        "width": Double(self.overlay?.bounds.width ?? 0),
        "maskWidth": Double(self.overlay?.layer.mask?.bounds.width ?? 0),
        "animating": self.overlay?.layer.mask?.animation(forKey: "theme-reveal") != nil,
        "reducedMotion": UIAccessibility.isReduceMotionEnabled
      ] as [String: Any])
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

#if targetEnvironment(simulator)
  private func freezeForCapture() -> Bool {
    guard let mask = overlay?.layer.mask as? CAShapeLayer,
          let current = mask.presentation() as? CAShapeLayer,
          let path = current.path else { return false }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    mask.path = path
    mask.removeAnimation(forKey: "theme-reveal")
    CATransaction.commit()
    return true
  }
#endif

  private func prepare(_ window: UIWindow?) -> Bool {
    guard let window else { return false }
    // Freeze pixels, not a live snapshot layer: Flutter's Metal surface can
    // change underneath snapshotView(). Use UIKit's full-window capture.
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    let snapshot = UIImageView(image: image)
    // Capture the currently presented mixture before removing an interrupted
    // reveal, so another tap starts from the visible result rather than a target.
    cancel()
    origin = button?.convert(CGPoint(x: button?.bounds.midX ?? 0, y: button?.bounds.midY ?? 0), to: window)
      ?? CGPoint(x: window.bounds.maxX - 76, y: window.safeAreaInsets.top + 28)
    snapshot.frame = window.bounds
    snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    snapshot.isUserInteractionEnabled = false; snapshot.accessibilityElementsHidden = true
    window.addSubview(snapshot); overlay = snapshot
    let task = DispatchWorkItem { [weak self, weak snapshot] in
      if self?.overlay === snapshot { self?.cancel() }
    }
    cleanup = task; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    return true
  }

  private func animate() {
    guard let snapshot = overlay else { return }
    cleanup?.cancel()
    if UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.15, animations: { snapshot.alpha = 0 }) { [weak self, weak snapshot] _ in
        if self?.overlay === snapshot { self?.cancel() }
      }
      return
    }
    let rect = snapshot.bounds
    let radius = hypot(max(abs(origin.x), abs(rect.width - origin.x)),
      max(abs(origin.y), abs(rect.height - origin.y))) + 2
    func path(_ radius: CGFloat) -> CGPath {
      let shape = UIBezierPath(rect: rect)
      shape.append(UIBezierPath(ovalIn: CGRect(x: origin.x - radius, y: origin.y - radius,
        width: radius * 2, height: radius * 2)))
      return shape.cgPath
    }
    let mask = CAShapeLayer()
    mask.frame = snapshot.bounds
    mask.fillColor = UIColor.black.cgColor
    mask.fillRule = .evenOdd
    mask.path = path(radius)
    snapshot.layer.mask = mask
    let animation = CABasicAnimation(keyPath: "path")
    animation.fromValue = path(0.1); animation.toValue = path(radius)
    // Preserve the app's established 680ms easeInOutSine theme reveal.
    animation.duration = 0.68
    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
    mask.add(animation, forKey: "theme-reveal")
    let task = DispatchWorkItem { [weak self, weak snapshot] in
      if self?.overlay === snapshot { self?.cancel() }
    }
    cleanup = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
  }

  func cancel() { cleanup?.cancel(); cleanup = nil; overlay?.removeFromSuperview(); overlay = nil }
}
