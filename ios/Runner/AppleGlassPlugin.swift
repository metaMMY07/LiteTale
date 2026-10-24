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
  private var surface: UIVisualEffectView?
  private var surfaceTint: UInt32?
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
    } else if kind == "surface" {
      let effect: UIVisualEffect
      if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
      else { effect = UIBlurEffect(style: .systemMaterial) }
      let view = UIVisualEffectView(effect: effect)
      view.isUserInteractionEnabled = false
      surface = view; addSubview(view)
      layer.cornerRadius = 20; clipsToBounds = true
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
    if let surface {
      let argb = (config["tint"] as? NSNumber)?.uint32Value
      if #available(iOS 26.0, *), surfaceTint != argb {
        let glass = UIGlassEffect(style: .regular)
        if let argb {
          glass.tintColor = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
            green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255,
            alpha: CGFloat((argb >> 24) & 255) / 255)
        }
        surface.effect = glass
        surfaceTint = argb
      }
      return
    }
    if let button = menuButton {
      menuItems = config["items"] as? [[String: String]] ?? []
      prepare(button, symbol: config["symbol"] as? String ?? "line.3.horizontal.decrease", title: config["label"] as? String ?? "分类")
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

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, let tabs, tabs.parent == nil, let parentController {
      parentController.addChild(tabs)
      tabs.didMove(toParent: parentController)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if let surface { surface.frame = bounds }
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

  deinit {
    if kind == "toolbar" { AppleThemeReveal.shared.cancel() }
    channel.setMethodCallHandler(nil)
    if let tabs, tabs.parent != nil {
      tabs.willMove(toParent: nil)
      tabs.removeFromParent()
    }
  }
}
