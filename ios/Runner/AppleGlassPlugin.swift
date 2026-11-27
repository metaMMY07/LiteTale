import CoreText
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

final class AppleGlassModalCoordinator {
  static let shared = AppleGlassModalCoordinator()
  static let didChangeNotification = Notification.Name("AppleGlassModalCoordinatorDidChange")

  private var activeSessions = Set<Int>()
  var isModalPresented: Bool { !activeSessions.isEmpty }

  func begin(session: Int) {
    let wasEmpty = activeSessions.isEmpty
    activeSessions.insert(session)
    if wasEmpty {
      NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
  }

  func end(session: Int) {
    let removed = activeSessions.remove(session) != nil
    if removed && activeSessions.isEmpty {
      NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
  }
}

/// Renders bundled Flutter icon-font glyphs (such as CupertinoIcons) with the
/// exact advance-width and even-leading baseline centering used by Flutter's
/// `Icon` widget, so live UIKit Liquid Glass controls match Flutter's preview
/// glyphs without shape, stroke-weight, or size jumps across state changes.
private final class AppleGlassIconGlyphRenderer {
  static let shared = AppleGlassIconGlyphRenderer()

  private struct CacheKey: Hashable {
    let family: String
    let codePoint: Int
    let sizeMilliPoints: Int
    let scaleMilli: Int
  }

  private lazy var fontAssetsByFamily: [String: String] = {
    var mapping: [String: String] = [
      "packages/cupertino_icons/CupertinoIcons": "packages/cupertino_icons/assets/CupertinoIcons.ttf",
      "CupertinoIcons": "packages/cupertino_icons/assets/CupertinoIcons.ttf",
      "MaterialIcons": "fonts/MaterialIcons-Regular.otf",
    ]
    let manifestKey = FlutterDartProject.lookupKey(forAsset: "FontManifest.json")
    if let path = Bundle.main.path(forResource: manifestKey, ofType: nil),
       let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
      for entry in entries {
        if let family = entry["family"] as? String,
           let fonts = entry["fonts"] as? [[String: Any]],
           let asset = fonts.first?["asset"] as? String {
          mapping[family] = asset
        }
      }
    }
    return mapping
  }()

  private var cgFonts: [String: CGFont] = [:]
  private var images: [CacheKey: UIImage] = [:]

  private func cgFont(forFamily family: String) -> CGFont? {
    if let cached = cgFonts[family] { return cached }
    guard let asset = fontAssetsByFamily[family] else { return nil }
    let resourceKey = FlutterDartProject.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: resourceKey, ofType: nil),
          let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
          let font = CGFont(provider) else {
      return nil
    }
    cgFonts[family] = font
    return font
  }

  func image(family: String?, codePoint: Int?, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
    guard let family, !family.isEmpty,
          let codePoint, codePoint > 0,
          pointSize > 0,
          let scalar = UnicodeScalar(codePoint) else {
      return nil
    }
    let resolvedScale = scale > 0 ? scale : UIScreen.main.scale
    let key = CacheKey(
      family: family,
      codePoint: codePoint,
      sizeMilliPoints: Int((pointSize * 1000).rounded()),
      scaleMilli: Int((resolvedScale * 1000).rounded())
    )
    if let cached = images[key] { return cached }
    guard let baseFont = cgFont(forFamily: family) else { return nil }

    let ctFont = CTFontCreateWithGraphicsFont(baseFont, pointSize, nil, nil)
    let characters = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
          var glyph = glyphs.first, glyph != 0 else {
      return nil
    }

    let ascent = CTFontGetAscent(ctFont)
    let descent = CTFontGetDescent(ctFont)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
    var boundingRect = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &boundingRect, 1)

    let advanceWidth = advance.width
    let midX = advanceWidth / 2
    let midY = (ascent - descent) / 2
    let halfSpanX = min(
      18,
      max(
        pointSize / 2,
        max(abs(boundingRect.minX - midX), abs(boundingRect.maxX - midX)) + 1
      )
    )
    let halfSpanY = min(
      18,
      max(
        pointSize / 2,
        max(abs(boundingRect.minY - midY), abs(boundingRect.maxY - midY)) + 1
      )
    )
    let canvasSize = CGSize(width: ceil(halfSpanX * 2), height: ceil(halfSpanY * 2))

    let format = UIGraphicsImageRendererFormat()
    format.scale = resolvedScale
    format.opaque = false
    let rendered = UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
      let cg = context.cgContext
      cg.translateBy(x: 0, y: canvasSize.height)
      cg.scaleBy(x: 1, y: -1)
      cg.setFillColor(UIColor.black.cgColor)
      var position = CGPoint(
        x: (canvasSize.width - advanceWidth) / 2,
        y: (canvasSize.height - ascent + descent) / 2
      )
      CTFontDrawGlyphs(ctFont, &glyph, &position, 1, cg)
    }.withRenderingMode(.alwaysTemplate)

    images[key] = rendered
    return rendered
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
  private var modalBackdrop: UIView?
  private var keepGlassInSheets = false
  private var buttonTint: UIColor?
  private var isDark = false
  private var actionBar: UIStackView?
  private var glassButton: UIButton?
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
      let effect: UIVisualEffect
      if #available(iOS 26.0, *) {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = kind == "actions"
        effect = glass
      }
      else { effect = UIBlurEffect(style: .systemMaterial) }
      let view = UIVisualEffectView(effect: effect)
      view.isUserInteractionEnabled = kind == "actions"
      surface = view; addSubview(view)
      layer.cornerRadius = 20
      if kind == "actions" {
        let stack = UIStackView()
        stack.distribution = .fillEqually
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        actionBar = stack
        view.contentView.addSubview(stack)
      }
    } else if kind == "button" {
      let button = UIButton(type: .system)
      button.addTarget(self, action: #selector(pressGlassButton), for: .touchUpInside)
      glassButton = button
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
    if kind == "surface" || kind == "actions" || kind == "button" {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(modalPresentationChanged),
        name: AppleGlassModalCoordinator.didChangeNotification,
        object: nil
      )
    }
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

  private func prepare(
    _ button: UIButton,
    symbol: String?,
    glyphImage: UIImage? = nil,
    title: String? = nil,
    tint: UIColor? = nil,
    foreground: UIColor = .label
  ) {
    let traits = UITraitCollection(traitsFrom: [
      traitCollection,
      UITraitCollection(userInterfaceStyle: isDark ? .dark : .light),
    ])
    let effectiveForeground = (button.isEnabled ? foreground : foreground.withAlphaComponent(0.38))
      .resolvedColor(with: traits)
    let image: UIImage?
    if let glyphImage {
      image = glyphImage.withTintColor(effectiveForeground, renderingMode: .alwaysOriginal)
    } else {
      let symbolImage = symbol.flatMap { UIImage(systemName: $0) }
      image = tint == nil
        ? symbolImage
        : symbolImage?.withTintColor(foreground, renderingMode: .alwaysOriginal)
    }
    button.tintColor = tint
    if #available(iOS 15.0, *) {
      var style: UIButton.Configuration
      if #available(iOS 26.0, *) {
        style = tint == nil ? .glass() : .prominentGlass()
      } else {
        style = .tinted()
      }
      style.image = image
      style.title = title
      style.imagePadding = (glyphImage != nil && title == nil) ? 0 : 4
      if glyphImage != nil && title == nil {
        style.contentInsets = .zero
      }
      style.titleLineBreakMode = .byTruncatingTail
      if title != nil {
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
        style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
          var output = input
          output.font = UIFont.preferredFont(forTextStyle: .subheadline)
          return output
        }
      }
      style.cornerStyle = .capsule
      style.baseForegroundColor = foreground
      if let tint {
        style.baseBackgroundColor = tint
        style.imageColorTransformer = UIConfigurationColorTransformer { _ in foreground }
      } else if glyphImage != nil {
        style.imageColorTransformer = UIConfigurationColorTransformer { _ in effectiveForeground }
      }
      button.configuration = style
    } else {
      button.setImage(image, for: .normal)
      button.setTitle(title, for: .normal)
    }
    if button.superview !== self { addSubview(button) }
  }

  private func colorFromARGB(_ value: Any?) -> UIColor? {
    guard let argb = (value as? NSNumber)?.uint32Value else { return nil }
    return UIColor(red: CGFloat((argb >> 16) & 255) / 255,
      green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255,
      alpha: CGFloat((argb >> 24) & 255) / 255)
  }

  @objc private func pressGlassButton() {
    channel.invokeMethod("action", arguments: ["action": "press"])
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
    let semiboldTitle = UIFont.systemFont(ofSize: 17, weight: .semibold)
    titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: semiboldTitle)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    addSubview(titleLabel)
    themeButton.accessibilityLabel = "切换深浅色模式"
    searchButton.accessibilityLabel = "搜索"
  }

  private func ensureModalBackdrop() -> UIView {
    if let modalBackdrop { return modalBackdrop }
    let backdrop = UIView()
    backdrop.isUserInteractionEnabled = false
    backdrop.isHidden = true
    backdrop.alpha = 0
    backdrop.clipsToBounds = true
    insertSubview(backdrop, at: 0)
    modalBackdrop = backdrop
    return backdrop
  }

  private func layoutModalBackdrop() {
    guard let backdrop = modalBackdrop else { return }
    backdrop.frame = bounds
    if kind == "button" || surfaceCapsule {
      let radius = min(bounds.width, bounds.height) / 2
      backdrop.layer.cornerRadius = radius
      backdrop.layer.cornerCurve = .circular
    } else {
      backdrop.layer.cornerRadius = 20
      backdrop.layer.cornerCurve = .continuous
    }
  }

  @objc private func modalPresentationChanged() {
    syncModalBackdrop(animated: !AppleGlassModalCoordinator.shared.isModalPresented)
  }

  private func syncModalBackdrop(animated: Bool) {
    let supportsBackdrop = !keepGlassInSheets &&
      (kind == "surface" || kind == "actions" || (kind == "button" && buttonTint == nil))
    guard supportsBackdrop else {
      modalBackdrop?.isHidden = true
      modalBackdrop?.alpha = 0
      return
    }
    if AppleGlassModalCoordinator.shared.isModalPresented {
      let backdrop = ensureModalBackdrop()
      backdrop.layer.removeAllAnimations()
      backdrop.backgroundColor = isDark
        ? UIColor(white: 0.16, alpha: 0.84)
        : UIColor(white: 1.0, alpha: 0.84)
      layoutModalBackdrop()
      backdrop.isHidden = false
      backdrop.alpha = 1
      return
    }
    guard let backdrop = modalBackdrop, !backdrop.isHidden else { return }
    let hide = {
      backdrop.alpha = 0
    }
    let complete: (Bool) -> Void = { _ in
      if !AppleGlassModalCoordinator.shared.isModalPresented {
        backdrop.isHidden = true
      }
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      // Wait one runloop tick so UIKit's UIGlassEffect restores its live backdrop
      // after modal sheet dismissal before fading out the temporary backing.
      DispatchQueue.main.async {
        guard !AppleGlassModalCoordinator.shared.isModalPresented else { return }
        UIView.animate(
          withDuration: 0.14,
          delay: 0,
          options: [.beginFromCurrentState, .allowUserInteraction],
          animations: hide,
          completion: complete
        )
      }
    } else {
      hide()
      complete(true)
    }
  }

  private func update(_ config: [String: Any]) {
    keepGlassInSheets = config["keepGlassInSheets"] as? Bool ?? false
    // Keep the effect inside Flutter's composited rectangle, including while a
    // Flutter sheet paints its barrier above the view.
    clipsToBounds = kind == "surface" || keepGlassInSheets
    let dark = config["dark"] as? Bool ?? false
    isDark = dark
    overrideUserInterfaceStyle = dark ? .dark : .light
    let argb = (config["accent"] as? NSNumber)?.uint32Value ?? 0xFFFF2D55
    let color = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
      green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: 1)
    tintColor = color
    if let button = glassButton {
      button.accessibilityLabel = config["label"] as? String
      button.isEnabled = config["enabled"] as? Bool ?? false
      if config["selected"] as? Bool == true {
        button.accessibilityTraits.insert(.selected)
      } else {
        button.accessibilityTraits.remove(.selected)
      }
      let resolvedTint = colorFromARGB(config["tint"])
      buttonTint = resolvedTint
      let displayScale = window?.screen.scale ?? UIScreen.main.scale
      let glyphImage = AppleGlassIconGlyphRenderer.shared.image(
        family: config["iconFontFamily"] as? String,
        codePoint: (config["iconCodePoint"] as? NSNumber)?.intValue,
        pointSize: CGFloat((config["iconSize"] as? NSNumber)?.doubleValue ?? 24),
        scale: displayScale
      )
      prepare(
        button,
        symbol: config["symbol"] as? String,
        glyphImage: glyphImage,
        tint: resolvedTint,
        foreground: colorFromARGB(config["foreground"]) ?? .label
      )
      syncModalBackdrop(animated: false)
      return
    }
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
      surfaceCapsule = config["capsule"] as? Bool ?? false
      setNeedsLayout()
      let argb = (config["tint"] as? NSNumber)?.uint32Value
      if #available(iOS 26.0, *), surfaceTint != argb {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = actionBar != nil
        if let argb {
          glass.tintColor = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
            green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255,
            alpha: CGFloat((argb >> 24) & 255) / 255)
        }
        surface.effect = glass
        surfaceTint = argb
      }
      syncModalBackdrop(animated: false)
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
          style.background.backgroundColor = .clear
          style.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
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
      button.backgroundColor = .clear
      button.tintColor = .label
      if #available(iOS 13.4, *) { button.isPointerInteractionEnabled = false }
      button.addTarget(self, action: #selector(activateAction(_:)), for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    let traits = UITraitCollection(traitsFrom: [
      traitCollection,
      UITraitCollection(userInterfaceStyle: isDark ? .dark : .light),
    ])
    let baseForeground = colorFromARGB(config["foreground"]) ?? .label
    let displayScale = window?.screen.scale ?? UIScreen.main.scale
    let symbolStyle = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
    for (view, action) in zip(stack.arrangedSubviews, actions) {
      guard let button = view as? UIButton else { continue }
      let enabled = action["enabled"] as? Bool ?? false
      button.accessibilityIdentifier = action["id"] as? String
      button.accessibilityLabel = action["label"] as? String
      button.isEnabled = enabled
      button.tintColor = baseForeground.resolvedColor(with: traits)
      if let glyphImage = AppleGlassIconGlyphRenderer.shared.image(
        family: action["iconFontFamily"] as? String,
        codePoint: (action["iconCodePoint"] as? NSNumber)?.intValue,
        pointSize: CGFloat((action["iconSize"] as? NSNumber)?.doubleValue ?? 20),
        scale: displayScale
      ) {
        let normalColor = baseForeground.resolvedColor(with: traits)
        let disabledColor = baseForeground.withAlphaComponent(0.38).resolvedColor(with: traits)
        button.setImage(glyphImage.withTintColor(normalColor, renderingMode: .alwaysOriginal), for: .normal)
        button.setImage(glyphImage.withTintColor(disabledColor, renderingMode: .alwaysOriginal), for: .disabled)
      } else if let symbol = action["symbol"] as? String {
        button.setImage(nil, for: .disabled)
        button.setImage(UIImage(systemName: symbol, withConfiguration: symbolStyle), for: .normal)
      }
    }
  }

  @objc private func activateAction(_ button: UIButton) {
    guard button.isEnabled, let id = button.accessibilityIdentifier else { return }
    channel.invokeMethod("action", arguments: ["action": id])
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, let tabs, tabs.parent == nil, let parentController {
      parentController.addChild(tabs)
      tabs.didMove(toParent: parentController)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutModalBackdrop()
    if let surface {
      surface.frame = bounds
      actionBar?.frame = surface.contentView.bounds
      if surfaceCapsule {
        // Match Flutter's StadiumBorder on both the glass and its host. An
        // outer clip alone leaves the material using its rectangular outline.
        let radius = min(bounds.width, bounds.height) / 2
        layer.cornerRadius = radius
        layer.cornerCurve = .circular
        surface.layer.cornerRadius = radius
        surface.layer.cornerCurve = .circular
        surface.clipsToBounds = kind == "surface"
        surface.contentView.layer.cornerRadius = radius
        surface.contentView.layer.cornerCurve = .circular
        surface.contentView.clipsToBounds = true
      } else {
        layer.cornerRadius = 20
        surface.layer.cornerRadius = 0
        surface.contentView.layer.cornerRadius = 20
        surface.contentView.layer.cornerCurve = .continuous
        surface.contentView.clipsToBounds = true
      }
    }
    else if let slider {
      slider.frame = bounds.insetBy(dx: 2, dy: 0)
    }
    else if let button = glassButton ?? menuButton { button.frame = bounds }
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
