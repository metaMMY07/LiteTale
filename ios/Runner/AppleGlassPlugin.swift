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
      segments.selectedSegmentIndex = config["index"] as? Int ?? 0
      segments.setTitle(config["lastLabel"] as? String ?? "全部", forSegmentAt: 3)
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
    if let tabs {
      tabs.view.frame = bounds
    } else if let segments {
      segments.frame = bounds.insetBy(dx: 12, dy: 4)
    } else {
      sourceButton.frame = CGRect(x: 8, y: 6, width: min(136, bounds.width * 0.34), height: 44)
      searchButton.frame = CGRect(x: bounds.width - 52, y: 6, width: 44, height: 44)
      themeButton.frame = CGRect(x: bounds.width - 104, y: 6, width: 44, height: 44)
      let leading = sourceButton.frame.maxX + 8
      titleLabel.frame = CGRect(x: leading, y: 6, width: max(0, themeButton.frame.minX - leading - 8), height: 44)
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let tabs, !tabs.tabBar.frame.contains(tabs.view.convert(point, from: self)) { return nil }
    return super.hitTest(point, with: event)
  }

  func tabBarController(_ controller: UITabBarController, didSelect viewController: UIViewController) {
    guard !applyingSelection else { return }
    channel.invokeMethod("action", arguments: ["action": "select", "value": controller.selectedIndex])
  }
  @objc private func openSources() { channel.invokeMethod("action", arguments: ["action": "source"]) }
  @objc private func selectSegment() {
    channel.invokeMethod("action", arguments: ["action": "select", "value": segments?.selectedSegmentIndex ?? 0])
  }
  @objc private func changeTheme() { channel.invokeMethod("action", arguments: ["action": "theme"]) }
  @objc private func openSearch() { channel.invokeMethod("action", arguments: ["action": "search"]) }

  deinit {
    channel.setMethodCallHandler(nil)
    if let tabs, tabs.parent != nil {
      tabs.willMove(toParent: nil)
      tabs.removeFromParent()
    }
  }
}
