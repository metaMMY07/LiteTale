import Flutter
import UIKit

// Native UIKit chrome. The host/controller containment approach is informed by
// native_liquid_glass (MIT); see third_party/licenses/native_liquid_glass.txt.
final class AppleGlassFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  private weak var parent: UIViewController?

  init(messenger: FlutterBinaryMessenger, parent: UIViewController) {
    self.messenger = messenger
    self.parent = parent
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AppleGlassView(frame: frame, id: viewId,
      config: args as? [String: Any] ?? [:], messenger: messenger, parent: parent)
  }
}

private final class AppleGlassView: UIView, FlutterPlatformView, UITabBarControllerDelegate {
  private let channel: FlutterMethodChannel
  private let kind: String
  private weak var parentController: UIViewController?
  private var tabs: UITabBarController?
  private var segments: UISegmentedControl?
  private var slider: UISlider?
  private var sliderEditing = false
  private var sliderDiscardTouch = false
  private var sliderRevision = 0
  private var sliderGestureRevision = 0
  private var sliderRestingValue: Float = 0
  private var surface: UIVisualEffectView?
  private var surfaceTint: UInt32?
  private var surfaceCapsule = false
  private var surfaceInteractive = false
  private var surfaceRadius: CGFloat = 20
  private var surfaceDark = false
  private var surfaceEffectApplied = false
  private var actionBar: UIStackView?
  private var menuButton: UIButton?
  private var menuItems: [[String: String]] = []
  private var applyingSelection = false
  private let sourceButton = UIButton(type: .system)
  private let themeButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)
  private let titleLabel = UILabel()

  init(frame: CGRect, id: Int64, config: [String: Any],
       messenger: FlutterBinaryMessenger, parent: UIViewController?) {
    channel = FlutterMethodChannel(name: "litetale/apple_glass/\(id)", binaryMessenger: messenger)
    kind = config["kind"] as? String ?? "tabs"
    parentController = parent
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    if kind == "tabs" {
      makeTabs()
    } else if kind == "segments" {
      let control = UISegmentedControl(items: ["推荐", "分类", "排行", "全部"])
      control.addTarget(self, action: #selector(selectSegment), for: .valueChanged)
      segments = control
      addSubview(control)
    } else if kind == "slider" {
      let control = UISlider()
      control.isContinuous = true
      control.addTarget(self, action: #selector(sliderStart), for: .touchDown)
      control.addTarget(self, action: #selector(sliderChange), for: .valueChanged)
      control.addTarget(self, action: #selector(sliderEnd), for: [.touchUpInside, .touchUpOutside])
      control.addTarget(self, action: #selector(sliderCancel), for: .touchCancel)
      // UIKit owns the iOS 26 glass thumb, stretch and release behavior.
      // A thumb image or thumbTintColor would override the system material.
      slider = control
      addSubview(control)
    } else if kind == "surface" || kind == "actions" {
      surfaceCapsule = config["capsule"] as? Bool ?? false
      surfaceInteractive = (config["interactive"] as? Bool ?? false) || kind == "actions"
      surfaceRadius = CGFloat((config["radius"] as? NSNumber)?.doubleValue ?? 20)
      let view = UIVisualEffectView(effect: nil)
      view.isUserInteractionEnabled = false
      surface = view; addSubview(view)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(accessibilityChanged),
        name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        object: nil
      )
      if kind == "actions" {
        let stack = UIStackView()
        stack.distribution = .fillEqually
        actionBar = stack
        addSubview(stack)
      }
    } else if kind == "menu" {
      let button = UIButton(type: .system)
      prepare(button, symbol: "line.3.horizontal.decrease", title: "分类")
      menuButton = button; addSubview(button)
      if #available(iOS 14.0, *) { button.showsMenuAsPrimaryAction = true }
      else { button.addTarget(self, action: #selector(openLegacyMenu), for: .touchUpInside) }
    } else {
      makeToolbar()
    }
    update(config)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let config = call.arguments as? [String: Any] {
        self.update(config)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("Use the Flutter platform-view factory") }
  func view() -> UIView { self }

  private func makeTabs() {
    let controller = UITabBarController()
    let labels = ["发现", "书架", "历史", "我的"]
    let symbols = ["safari", "book.closed", "clock", "person.crop.circle"]
    controller.viewControllers = labels.enumerated().map { index, label in
      let content = UIViewController()
      content.view.backgroundColor = .clear
      content.tabBarItem = UITabBarItem(title: label,
        image: UIImage(systemName: symbols[index]),
        selectedImage: UIImage(systemName: symbols[index] + ".fill"))
      return content
    }
    if #available(iOS 18.0, *) { controller.mode = .tabBar }
    if #available(iOS 17.0, *) { controller.traitOverrides.horizontalSizeClass = .compact }
    controller.view.backgroundColor = .clear
    controller.view.isOpaque = false
    controller.view.clipsToBounds = false
    controller.tabBar.isTranslucent = true
    // Keep iOS 26's system material and selection physics intact.
    controller.delegate = self
    tabs = controller
    addSubview(controller.view)
  }

  private func prepare(_ button: UIButton, symbol: String, title: String? = nil) {
    if #available(iOS 26.0, *) {
      var style = UIButton.Configuration.glass()
      style.image = UIImage(systemName: symbol)
      style.title = title
      style.imagePadding = 4
      style.titleLineBreakMode = .byTruncatingTail
      if title != nil {
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
        style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
          var output = input; output.font = UIFont.preferredFont(forTextStyle: .subheadline); return output
        }
      }
      style.cornerStyle = .capsule
      style.baseForegroundColor = .label
      button.configuration = style
    } else if #available(iOS 15.0, *) {
      var style = UIButton.Configuration.tinted()
      style.image = UIImage(systemName: symbol)
      style.title = title
      style.cornerStyle = .capsule
      button.configuration = style
    } else {
      button.setImage(UIImage(systemName: symbol), for: .normal)
      button.setTitle(title, for: .normal)
    }
    addSubview(button)
  }

  private func makeToolbar() {
    AppleThemeReveal.shared.button = themeButton
    prepare(sourceButton, symbol: "books.vertical", title: "书源")
    prepare(themeButton, symbol: "moon")
    prepare(searchButton, symbol: "magnifyingglass")
    sourceButton.addTarget(self, action: #selector(openSources), for: .touchUpInside)
    themeButton.addTarget(self, action: #selector(changeTheme), for: .touchUpInside)
    searchButton.addTarget(self, action: #selector(openSearch), for: .touchUpInside)
    titleLabel.text = "发现"
    titleLabel.textAlignment = .center
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.adjustsFontForContentSizeCategory = true
    addSubview(titleLabel)
    themeButton.accessibilityLabel = "切换深浅色模式"
    searchButton.accessibilityLabel = "搜索"
  }

  private func update(_ config: [String: Any]) {
    let dark = config["dark"] as? Bool ?? false
    overrideUserInterfaceStyle = dark ? .dark : .light
    let argb = (config["accent"] as? NSNumber)?.uint32Value ?? 0xFFFF2D55
    let color = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
      green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: 1)
    tintColor = color
    if let slider {
      let low = (config["min"] as? NSNumber)?.floatValue ?? 0
      let high = (config["max"] as? NSNumber)?.floatValue ?? 1
      let value = (config["value"] as? NSNumber)?.floatValue ?? low
      guard low.isFinite, high.isFinite, value.isFinite, high > low else { return }
      let revision = config["revision"] as? Int ?? 0
      let enabled = config["enabled"] as? Bool ?? true
      if sliderEditing && (revision != sliderRevision || !enabled) {
        sliderDiscardTouch = true
        sliderCancel()
      }
      sliderRevision = revision
      if slider.minimumValue != low { slider.minimumValue = low }
      if slider.maximumValue != high { slider.maximumValue = high }
      sliderRestingValue = min(high, max(low, value))
      if slider.isEnabled != enabled { slider.isEnabled = enabled }
      if slider.tintColor != color { slider.tintColor = color }
      if slider.minimumTrackTintColor != color { slider.minimumTrackTintColor = color }
      // Flutter echoes drag values to update the label. Feeding these back
      // into a tracking UIKit control interrupts its own presentation physics.
      if !sliderEditing && !slider.isTracking {
        slider.setValue(sliderRestingValue, animated: false)
      }
      return
    }
    if let surface {
      if let actionBar { updateActions(actionBar, config: config) }
      let nextCapsule = config["capsule"] as? Bool ?? false
      let nextInteractive = (config["interactive"] as? Bool ?? false) || kind == "actions"
      let nextRadius = CGFloat((config["radius"] as? NSNumber)?.doubleValue ?? 20)
      let nextArgB = (config["tint"] as? NSNumber)?.uint32Value
      if surfaceCapsule != nextCapsule || surfaceInteractive != nextInteractive ||
          surfaceRadius != nextRadius || surfaceTint != nextArgB || surfaceDark != dark {
        surfaceCapsule = nextCapsule
        surfaceInteractive = nextInteractive
        surfaceRadius = nextRadius
        surfaceTint = nextArgB
        surfaceDark = dark
        surfaceEffectApplied = false
        setNeedsLayout()
      }
      if window != nil && isSurfaceRenderable {
        applySurfaceEffectIfNeeded(view: surface)
      }
      return
    }
    if let button = menuButton {
      menuItems = config["items"] as? [[String: String]] ?? []
      let label = config["label"] as? String ?? "分类"
      if config["textOnly"] as? Bool == true {
        button.contentHorizontalAlignment = .trailing
        if #available(iOS 15.0, *) {
          var style = UIButton.Configuration.plain()
          style.title = label
          style.titleLineBreakMode = .byTruncatingTail
          style.contentInsets = .zero
          style.baseForegroundColor = color
          button.configuration = style
        } else {
          button.setImage(nil, for: .normal)
          button.setTitle(label, for: .normal)
        }
      } else {
        button.contentHorizontalAlignment = .center
        prepare(button, symbol: config["symbol"] as? String ?? "line.3.horizontal.decrease", title: label)
      }
      if #available(iOS 14.0, *) {
        let selected = config["selected"] as? String
        let groups = Array(NSOrderedSet(array: menuItems.map { $0["group"] ?? "" })) as? [String] ?? []
        button.menu = UIMenu(children: groups.map { group in
          UIMenu(title: group, options: .displayInline, children: menuItems.filter { ($0["group"] ?? "") == group }.map { item in
            UIAction(title: item["label"] ?? "", attributes: item["disabled"] == "true" ? .disabled : [], state: item["value"] == selected ? .on : .off) { [weak self] _ in
              self?.channel.invokeMethod("action", arguments: ["action": "select", "value": item["value"] ?? ""])
            }
          })
        })
      }
      return
    }
    if let tabs {
      tabs.overrideUserInterfaceStyle = overrideUserInterfaceStyle
      tabs.view.tintColor = color
      tabs.tabBar.tintColor = color
      let index = config["index"] as? Int ?? 0
      if (0..<4).contains(index) {
        applyingSelection = true
        tabs.selectedIndex = index
        applyingSelection = false
      }
    } else if let segments {
      let labels = config["labels"] as? [String] ?? ["推荐", "分类", "排行", config["lastLabel"] as? String ?? "全部"]
      if (0..<segments.numberOfSegments).map({ segments.titleForSegment(at: $0) ?? "" }) != labels {
        segments.removeAllSegments()
        for (index, title) in labels.enumerated() { segments.insertSegment(withTitle: title, at: index, animated: false) }
      }
      segments.selectedSegmentIndex = config["index"] as? Int ?? 0
      let enabled = config["enabled"] as? [Bool] ?? []
      for index in 0..<segments.numberOfSegments {
        segments.setEnabled(index >= enabled.count || enabled[index], forSegmentAt: index)
      }
    } else {
      let source = config["source"] as? String ?? "书源"
      sourceButton.accessibilityLabel = "切换书源，当前\(source)"
      if #available(iOS 15.0, *) {
        var style = sourceButton.configuration
        style?.title = source
        sourceButton.configuration = style
        var theme = themeButton.configuration
        theme?.image = UIImage(systemName: dark ? "sun.max" : "moon")
        themeButton.configuration = theme
      } else {
        sourceButton.setTitle(source, for: .normal)
        themeButton.setImage(UIImage(systemName: dark ? "sun.max" : "moon"), for: .normal)
      }
    }
  }

  private func updateActions(_ stack: UIStackView, config: [String: Any]) {
    let actions = config["actions"] as? [[String: Any]] ?? []
    while stack.arrangedSubviews.count > actions.count {
      guard let view = stack.arrangedSubviews.last else { break }
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    while stack.arrangedSubviews.count < actions.count {
      let button = UIButton(type: .system)
      button.tintColor = .label
      button.addTarget(self, action: #selector(activateAction(_:)), for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    let symbolStyle = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
    for (view, action) in zip(stack.arrangedSubviews, actions) {
      guard let button = view as? UIButton else { continue }
      button.accessibilityIdentifier = action["id"] as? String
      button.accessibilityLabel = action["label"] as? String
      button.isEnabled = action["enabled"] as? Bool ?? false
      if let symbol = action["symbol"] as? String {
        button.setImage(UIImage(systemName: symbol, withConfiguration: symbolStyle), for: .normal)
      }
    }
  }

  @objc private func activateAction(_ button: UIButton) {
    guard button.isEnabled, let id = button.accessibilityIdentifier else { return }
    channel.invokeMethod("action", arguments: ["action": id])
  }

  private static func isNativeGlassAvailable() -> Bool {
    if #available(iOS 26.0, *) {
      guard let glassClass = NSClassFromString("UIGlassEffect") as? NSObject.Type else {
        return false
      }
      return glassClass.responds(to: Selector(("effectWithStyle:")))
    }
    return false
  }

  private var isSurfaceRenderable: Bool {
    guard window != nil else { return false }
    var opacity: CGFloat = 1
    var node: UIView? = self
    while let current = node {
      if current.isHidden { return false }
      opacity *= current.alpha
      if opacity <= 0.02 { return false }
      node = current.superview
    }
    return true
  }

  private func applySurfaceEffectIfNeeded(view: UIVisualEffectView) {
    guard !surfaceEffectApplied else { return }
    surfaceEffectApplied = true
    view.overrideUserInterfaceStyle = surfaceDark ? .dark : .light
    if UIAccessibility.isReduceTransparencyEnabled {
      view.effect = nil
      view.contentView.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.95)
      if #available(iOS 26.0, *), Self.isNativeGlassAvailable() {
        applySurfaceCorners(to: view, clipView: true)
      } else {
        applyLegacySurfaceCorners(to: view)
      }
      return
    }
    view.contentView.backgroundColor = .clear
    if #available(iOS 26.0, *), Self.isNativeGlassAvailable() {
      // Clear previous UIGlassEffect before assigning updated configuration
      // so offstage re-attachment renders soft unclipped native glass cleanly.
      view.effect = UIVisualEffect()
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = surfaceInteractive
      if let argb = surfaceTint {
        glass.tintColor = UIColor(
          red: CGFloat((argb >> 16) & 255) / 255,
          green: CGFloat((argb >> 8) & 255) / 255,
          blue: CGFloat(argb & 255) / 255,
          alpha: CGFloat((argb >> 24) & 255) / 255
        )
      }
      view.effect = glass
      applySurfaceCorners(to: view, clipView: false)
    } else {
      view.effect = UIBlurEffect(style: .systemChromeMaterial)
      applyLegacySurfaceCorners(to: view)
    }
  }

  @available(iOS 26.0, *)
  private func applySurfaceCorners(to view: UIVisualEffectView, clipView: Bool) {
    clipsToBounds = false
    layer.cornerRadius = 0
    view.clipsToBounds = clipView
    #if compiler(>=6.2)
    if surfaceCapsule {
      view.cornerConfiguration = .capsule()
    } else {
      let corner = UICornerRadius(floatLiteral: Double(surfaceRadius))
      view.cornerConfiguration = .corners(
        topLeftRadius: corner,
        topRightRadius: corner,
        bottomLeftRadius: corner,
        bottomRightRadius: corner
      )
    }
    #endif
  }

  private func applyLegacySurfaceCorners(to view: UIVisualEffectView) {
    let radius = surfaceCapsule ? min(bounds.width, bounds.height) / 2 : surfaceRadius
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    clipsToBounds = true
    view.layer.cornerRadius = radius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
  }

  @objc private func accessibilityChanged() {
    guard surface != nil else { return }
    surfaceEffectApplied = false
    setNeedsLayout()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil, let surface {
      surface.effect = UIVisualEffect()
      surfaceEffectApplied = false
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil && surface != nil {
      setNeedsLayout()
    }
    if window != nil, let tabs, tabs.parent == nil, let parentController {
      parentController.addChild(tabs)
      tabs.didMove(toParent: parentController)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if let surface {
      surface.frame = bounds
      actionBar?.frame = bounds
      if isSurfaceRenderable {
        applySurfaceEffectIfNeeded(view: surface)
      }
      if UIAccessibility.isReduceTransparencyEnabled || !Self.isNativeGlassAvailable() {
        applyLegacySurfaceCorners(to: surface)
      } else if #available(iOS 26.0, *) {
        applySurfaceCorners(to: surface, clipView: false)
      }
    }
    else if let slider {
      slider.frame = bounds.insetBy(dx: 2, dy: 0)
    }
    else if let button = menuButton { button.frame = bounds }
    else if let tabs {
      tabs.view.frame = bounds
    } else if let segments {
      segments.frame = bounds.insetBy(dx: 12, dy: 0)
    } else {
      sourceButton.frame = CGRect(x: 8, y: 6, width: min(136, bounds.width * 0.34), height: 44)
      searchButton.frame = CGRect(x: bounds.width - 52, y: 6, width: 44, height: 44)
      themeButton.frame = CGRect(x: bounds.width - 104, y: 6, width: 44, height: 44)
      let leading = sourceButton.frame.maxX + 8
      let halfWidth = max(0, min(bounds.midX - leading,
        themeButton.frame.minX - 8 - bounds.midX))
      titleLabel.frame = CGRect(x: bounds.midX - halfWidth, y: 6,
        width: halfWidth * 2, height: 44)
    }
  }

  func tabBarController(_ controller: UITabBarController, didSelect viewController: UIViewController) {
    guard !applyingSelection else { return }
    channel.invokeMethod("action", arguments: ["action": "select", "value": controller.selectedIndex])
  }
  @objc private func openSources() { channel.invokeMethod("action", arguments: ["action": "source"]) }
  @objc private func openLegacyMenu() {
    let sheet = UIAlertController(title: "分类", message: nil, preferredStyle: .actionSheet)
    for item in menuItems { sheet.addAction(UIAlertAction(title: item["label"], style: .default) { [weak self] _ in
      self?.channel.invokeMethod("action", arguments: ["action": "select", "value": item["value"] ?? ""])
    }) }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    sheet.popoverPresentationController?.sourceView = menuButton
    parentController?.present(sheet, animated: true)
  }
  @objc private func selectSegment() {
    channel.invokeMethod("action", arguments: ["action": "select", "value": segments?.selectedSegmentIndex ?? 0])
  }
  @objc private func changeTheme() { channel.invokeMethod("action", arguments: ["action": "theme"]) }
  @objc private func openSearch() { channel.invokeMethod("action", arguments: ["action": "search"]) }

  private func sliderAction(_ action: String) {
    guard let slider else { return }
    channel.invokeMethod("action", arguments: ["action": action,
      "value": Double(slider.value), "revision": sliderGestureRevision])
  }

  @objc private func sliderStart() {
    guard slider?.isEnabled == true, !sliderEditing else { return }
    sliderDiscardTouch = false
    sliderEditing = true
    sliderGestureRevision = sliderRevision
    sliderAction("start")
  }

  @objc private func sliderChange() {
    guard let slider, slider.isEnabled, !sliderDiscardTouch else { return }
    // VoiceOver adjustments send valueChanged without touchDown/touchUp.
    let accessibilityAdjustment = !sliderEditing && !slider.isTracking
    if !sliderEditing { sliderStart() }
    sliderAction("change")
    if accessibilityAdjustment { sliderEnd() }
  }

  @objc private func sliderEnd() {
    if sliderDiscardTouch {
      sliderDiscardTouch = false
      slider?.setValue(sliderRestingValue, animated: false)
      return
    }
    guard sliderEditing else { return }
    sliderEditing = false
    sliderAction("end")
  }

  @objc private func sliderCancel() {
    guard sliderEditing else { return }
    sliderEditing = false
    sliderAction("cancel")
    if slider?.isTracking == false { slider?.setValue(sliderRestingValue, animated: false) }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if kind == "toolbar" { AppleThemeReveal.shared.cancel() }
    channel.setMethodCallHandler(nil)
    if let tabs, tabs.parent != nil {
      tabs.willMove(toParent: nil)
      tabs.removeFromParent()
    }
  }
}
