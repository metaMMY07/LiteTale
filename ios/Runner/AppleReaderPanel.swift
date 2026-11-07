import Flutter
import SwiftUI
import UIKit
import PhotosUI

/// One native presentation/scrolling hierarchy. Mixing a native UISlider per
/// Flutter row exhausts the engine's overlay slices and can hide intervening
/// labels. Keep the whole form native, including its text and separators.
final class AppleReaderPanelChannel: NSObject {
  private let channel: FlutterMethodChannel
  private weak var parent: UIViewController?
  private var activeSession: Int?
  private var activeController: UIViewController?

  init(parent: UIViewController, messenger: FlutterBinaryMessenger) {
    self.parent = parent
    channel = FlutterMethodChannel(name: "litetale/reader_panel", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "supported" {
        if #available(iOS 15.0, *) { result(true) } else { result(false) }
        return
      }
      #if targetEnvironment(simulator)
      // A narrow offline acceptance bridge. Never compiled into the device IPA.
      if #available(iOS 15.0, *), call.method.hasPrefix("test"),
         let navigation = activeController as? UINavigationController,
         let form = navigation.viewControllers.first as? AppleReaderFormController {
        let input = call.arguments as? [String: Any] ?? [:]
        if call.method == "testInspect" {
          if input["expand"] as? Bool == true {
            navigation.sheetPresentationController?.animateChanges {
              navigation.sheetPresentationController?.selectedDetentIdentifier = .large
            }
          }
          func scrolls(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrolls($0) }
          }
          let scroll = scrolls(form.view).max { $0.contentSize.height < $1.contentSize.height }
          if let fraction = input["scroll"] as? Double, let scroll {
            let maxY = max(-scroll.adjustedContentInset.top,
              scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: maxY * CGFloat(min(1, max(0, fraction)))), animated: false)
          }
          result(["titles": form.model.sections.flatMap { $0.rows.map { $0.title } },
            "scrollHeight": scroll?.contentSize.height ?? 0, "nativeForm": true,
            "appearance": form.appearanceSnapshot])
        } else if call.method == "testCommit", let id = input["id"] as? String,
                  let value = input["value"],
                  let row = form.model.sections.flatMap({ $0.rows }).first(where: { $0.id == id }) {
          form.model.commit(row, value); result(nil)
        } else if call.method == "testSelect", let id = input["id"] as? String {
          form.model.selectRow?(id); result(nil)
        } else if call.method == "testClose" {
          form.onClose?(nil); result(nil)
        } else { result(FlutterMethodNotImplemented) }
        return
      }
      #endif
      guard let args = call.arguments as? [String: Any], let session = args["session"] as? Int else {
        result(FlutterError(code: "invalid_panel", message: "Missing reader session", details: nil)); return
      }
      if call.method == "dismiss" {
        guard activeSession == session, let controller = activeController else { result(nil); return }
        controller.dismiss(animated: true) { [weak self] in self?.finish(session, selection: nil) }
        result(nil)
      } else if call.method == "present", #available(iOS 15.0, *),
                let configuration = args["configuration"] as? [String: Any] {
        guard activeSession == nil, let presenter = self.parent, presenter.presentedViewController == nil else {
          result(FlutterError(code: "panel_busy", message: "Another panel is already presented", details: nil)); return
        }
        let controller = AppleReaderFormController(configuration: configuration)
        controller.model.sendChange = { [weak self] event, reply in
          guard let self, activeSession == session else { reply(nil); return }
          var event = event; event["session"] = session
          channel.invokeMethod("change", arguments: event, result: reply)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        navigation.overrideUserInterfaceStyle = configuration["dark"] as? Bool == true ? .dark : .light
        navigation.view.tintColor = readerColor(configuration["accent"])
        if let sheet = navigation.sheetPresentationController {
          sheet.detents = [.medium(), .large()]
          sheet.selectedDetentIdentifier = .medium
          sheet.prefersGrabberVisible = true
          sheet.prefersScrollingExpandsWhenScrolledToEdge = true
          sheet.prefersEdgeAttachedInCompactHeight = true
          if #available(iOS 26.0, *) { sheet.prefersPageSizing = false }
        }
        controller.onClose = { [weak self, weak navigation] selection in
          navigation?.dismiss(animated: true) { self?.finish(session, selection: selection) }
        }
        controller.onInteractiveDismiss = { [weak self] in self?.finish(session, selection: nil) }
        navigation.presentationController?.delegate = controller
        activeSession = session; activeController = navigation
        presenter.present(navigation, animated: true)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func finish(_ session: Int, selection: [String: Any]?) {
    guard activeSession == session else { return }
    activeSession = nil; activeController = nil
    var args: [String: Any] = ["session": session]
    if let selection { args["selection"] = selection }
    channel.invokeMethod("dismissed", arguments: args)
  }
}

final class AppleReaderSettingsFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  weak var parent: UIViewController?
  init(messenger: FlutterBinaryMessenger, parent: UIViewController) {
    self.messenger = messenger; self.parent = parent
  }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    if #available(iOS 15.0, *) {
      return AppleReaderSettingsHost(frame: frame, id: viewId, configuration: args as? [String: Any] ?? [:],
        messenger: messenger, parent: parent)
    }
    return EmptyReaderSettingsHost()
  }
}

private final class EmptyReaderSettingsHost: NSObject, FlutterPlatformView {
  func view() -> UIView { UIView() }
}

@available(iOS 15.0, *)
private final class AppleReaderSettingsHost: NSObject, FlutterPlatformView {
  private let controller: AppleReaderFormController
  private let channel: FlutterMethodChannel
  init(frame: CGRect, id: Int64, configuration: [String: Any], messenger: FlutterBinaryMessenger, parent: UIViewController?) {
    controller = AppleReaderFormController(configuration: configuration)
    channel = FlutterMethodChannel(name: "litetale/reader_settings/\(id)", binaryMessenger: messenger)
    super.init()
    controller.view.frame = frame
    parent?.addChild(controller)
    controller.didMove(toParent: parent)
    controller.model.sendChange = { [weak self] event, reply in
      guard let self else { reply(nil); return }
      channel.invokeMethod("change", arguments: event, result: reply)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "update", let configuration = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented); return
      }
      controller.model.apply(configuration)
      result(nil)
    }
  }
  func view() -> UIView { controller.view }
  deinit {
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    channel.setMethodCallHandler(nil)
  }
}

private func readerColor(_ value: Any?) -> UIColor {
  guard let argb = (value as? NSNumber)?.uint32Value else { return .systemBlue }
  return UIColor(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
    blue: CGFloat(argb & 255) / 255, alpha: CGFloat((argb >> 24) & 255) / 255)
}

private struct ReaderFormRow: Identifiable {
  let data: [String: Any]
  var id: String { data["id"] as? String ?? "" }
  var kind: String { data["kind"] as? String ?? "" }
  var title: String { data["title"] as? String ?? "" }
  var detail: String { data["description"] as? String ?? "" }
  var number: Double { (data["value"] as? NSNumber)?.doubleValue ?? 0 }
  var boolean: Bool { data["value"] as? Bool ?? false }
  var text: String { data["value"] as? String ?? "" }
  var enabled: Bool { data["enabled"] as? Bool ?? true }
  var choices: [String] { data["choices"] as? [String] ?? [] }
  var minimum: Double { (data["min"] as? NSNumber)?.doubleValue ?? 0 }
  var maximum: Double { (data["max"] as? NSNumber)?.doubleValue ?? 1 }
  var step: Double { (data["step"] as? NSNumber)?.doubleValue ?? 1 }
  func caption(_ value: Double) -> String {
    let decimals = step < 0.1 ? 2 : step < 1 ? 1 : 0
    return String(format: "%.*f", decimals, value) + " " + (data["unit"] as? String ?? "")
  }
}

private struct ReaderFormSection: Identifiable {
  let id: Int
  let title: String
  let rows: [ReaderFormRow]
}

@available(iOS 15.0, *)
private final class ReaderFormModel: ObservableObject {
  @Published var sections: [ReaderFormSection] = []
  @Published var pending = Set<String>()
  var accent = UIColor.systemBlue
  @Published var dark = false
  var title = "阅读设置"
  var appearanceChanged: (() -> Void)?
  var interfaceStyle: UIUserInterfaceStyle { dark ? .dark : .light }
  var background: UIColor {
    UIColor.systemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: interfaceStyle))
  }
  var rowBackground: UIColor {
    UIColor.secondarySystemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: interfaceStyle))
  }
  var sendChange: (([String: Any], @escaping FlutterResult) -> Void)?
  var chooseColor: ((ReaderFormRow) -> Void)?
  var choosePhoto: ((ReaderFormRow) -> Void)?
  var selectRow: ((String) -> Void)?
  var showError: ((String) -> Void)?

  func apply(_ config: [String: Any]) {
    accent = readerColor(config["accent"])
    dark = config["dark"] as? Bool ?? false
    title = config["title"] as? String ?? "阅读设置"
    sections = (config["sections"] as? [[String: Any]] ?? []).enumerated().map { index, section in
      ReaderFormSection(id: index, title: section["title"] as? String ?? "",
        rows: (section["rows"] as? [[String: Any]] ?? []).map { ReaderFormRow(data: $0) })
    }
    appearanceChanged?()
  }

  func commit(_ row: ReaderFormRow, _ value: Any) {
    guard row.enabled, !pending.contains(row.id), let sendChange else { return }
    pending.insert(row.id)
    sendChange(["id": row.id, "value": value]) { [weak self] reply in
      // Method-channel replies run on the platform main thread.
      guard let self else { return }
      pending.remove(row.id)
      if let result = reply as? [String: Any] {
        if let configuration = result["configuration"] as? [String: Any] { apply(configuration) }
        if let error = result["error"] as? String { showError?(error) }
      } else if let error = reply as? FlutterError {
        showError?(error.message ?? "保存设置失败")
      }
    }
  }
}

@available(iOS 15.0, *)
private struct ReaderNativeForm: View {
  @ObservedObject var model: ReaderFormModel
  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        Form {
          ForEach(model.sections) { section in
            Section {
              ForEach(section.rows) { row in
                ReaderNativeRow(model: model, row: row, width: geometry.size.width).id(row.id)
                  .listRowBackground(Color(model.rowBackground))
              }
            } header: {
              if !section.title.isEmpty { Text(section.title) }
            }
          }
        }
        .modifier(ReaderFormScrollBackground())
        .background(Color(model.background))
        .tint(Color(model.accent))
        .onAppear {
          if let selected = model.sections.flatMap({ $0.rows }).first(where: { $0.kind == "chapter" && $0.boolean }) {
            DispatchQueue.main.async { proxy.scrollTo(selected.id, anchor: .center) }
          }
        }
      }
    }
    // UIKit's presenting window can have the opposite appearance from the app.
    // Give SwiftUI's labels AND list surfaces the same explicit environment.
    .environment(\.colorScheme, model.dark ? .dark : .light)
    .preferredColorScheme(model.dark ? .dark : .light)
  }
}

@available(iOS 15.0, *)
private struct ReaderFormScrollBackground: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 16.0, *) { content.scrollContentBackground(.hidden) }
    else { content }
  }
}

@available(iOS 15.0, *)
private struct ReaderNativeRow: View {
  @ObservedObject var model: ReaderFormModel
  let row: ReaderFormRow
  let width: CGFloat
  @Environment(\.sizeCategory) private var sizeCategory
  @State private var draft: Double
  @State private var editing = false
  init(model: ReaderFormModel, row: ReaderFormRow, width: CGFloat) {
    self.model = model; self.row = row; self.width = width
    _draft = State(initialValue: row.number)
  }
  private var stacked: Bool { width < 360 || sizeCategory.isAccessibilityCategory }
  private var labels: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.title).font(.body).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
      if !row.detail.isEmpty {
        Text(row.detail + (row.kind == "slider" ? " · " + row.caption(draft) : ""))
          .font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private var accessory: some View {
    switch row.kind {
    case "slider":
      Slider(value: $draft, in: row.minimum...row.maximum, step: row.step, onEditingChanged: { active in
        editing = active
        if !active { model.commit(row, draft) }
      }).accessibilityLabel(row.title)
        .accessibilityValue(row.caption(draft))
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: draft = min(row.maximum, draft + row.step)
          case .decrement: draft = max(row.minimum, draft - row.step)
          @unknown default: return
          }
          model.commit(row, draft)
        }
        // Preserve the system's iOS 26 glass thumb and stretch/release physics.
        .frame(width: stacked ? nil : min(180, width * 0.41))
    case "toggle":
      Toggle(row.title, isOn: Binding(get: { row.boolean }, set: { model.commit(row, $0) }))
        .labelsHidden().tint(Color(UIColor.systemGreen))
    case "choice":
      Menu {
        ForEach(row.choices, id: \.self) { choice in
          Button { model.commit(row, choice) } label: {
            if choice == row.text { Label(choice, systemImage: "checkmark") } else { Text(choice) }
          }
        }
      } label: { Text(row.text).lineLimit(2) }
    case "color":
      Button { model.chooseColor?(row) } label: {
        Circle().fill(Color(readerColor(row.data["value"])))
          .overlay(Circle().stroke(Color(UIColor.separator), lineWidth: 1)).frame(width: 30, height: 30)
      }.accessibilityLabel(row.title)
    case "photo":
      Button("选择") { model.choosePhoto?(row) }
    default: EmptyView()
    }
  }
  var body: some View {
    Group {
      if row.kind == "chapter" {
        Button { model.selectRow?(row.id) } label: {
          HStack {
            Text(row.title).font(.body).foregroundColor(row.boolean ? Color(model.accent) : .primary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if row.boolean { Image(systemName: "checkmark").foregroundColor(Color(model.accent)) }
          }.padding(.vertical, 6)
        }
      } else if row.kind == "action" {
        Button { model.selectRow?(row.id) } label: {
          HStack(spacing: 12) {
            Image(systemName: row.data["icon"] as? String ?? "bookmark")
              .foregroundColor(Color(model.accent)).frame(width: 28)
              .accessibilityHidden(true)
            Text(row.title).foregroundColor(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
              .foregroundColor(.secondary).accessibilityHidden(true)
          }.padding(.vertical, 8)
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: row.data["icon"] as? String ?? "slider.horizontal.3")
            .font(.system(size: 22)).foregroundColor(Color(model.accent)).frame(width: 28, height: 28)
            .accessibilityHidden(true)
          if stacked && row.kind == "slider" {
            VStack(alignment: .leading, spacing: 10) { labels; accessory }
          } else {
            labels
            accessory
          }
        }.padding(.vertical, 10)
      }
    }
    .disabled(!row.enabled || model.pending.contains(row.id))
    .accessibilityIdentifier("reader-setting-" + row.id)
    .onChange(of: row.number) { value in if !editing { draft = value } }
  }
}

@available(iOS 15.0, *)
private final class AppleReaderFormController: UIViewController, UIAdaptivePresentationControllerDelegate,
  UIColorPickerViewControllerDelegate, PHPickerViewControllerDelegate {
  let model = ReaderFormModel()
  private var hosting: UIHostingController<ReaderNativeForm>?
  private var colorRow: ReaderFormRow?
  private var photoRow: ReaderFormRow?
  var onClose: (([String: Any]?) -> Void)?
  var onInteractiveDismiss: (() -> Void)?

  init(configuration: [String: Any]) {
    super.init(nibName: nil, bundle: nil)
    model.apply(configuration)
    overrideUserInterfaceStyle = model.dark ? .dark : .light
    model.appearanceChanged = { [weak self] in self?.updateAppearance() }
    model.chooseColor = { [weak self] row in self?.pickColor(row) }
    model.choosePhoto = { [weak self] row in self?.pickPhoto(row) }
    model.selectRow = { [weak self] id in self?.onClose?(["id": id]) }
    model.showError = { [weak self] message in
      let alert = UIAlertController(title: "无法保存", message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "知道了", style: .default))
      self?.present(alert, animated: true)
    }
  }
  required init?(coder: NSCoder) { fatalError("Use reader configuration") }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = model.title
    if navigationController != nil {
      navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.onClose?(nil) })
    }
    let content = UIHostingController(rootView: ReaderNativeForm(model: model))
    content.overrideUserInterfaceStyle = model.interfaceStyle
    content.view.backgroundColor = .clear
    addChild(content); view.addSubview(content.view)
    content.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.view.topAnchor.constraint(equalTo: view.topAnchor), content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    content.didMove(toParent: self); hosting = content
    updateAppearance()
  }
  private func updateAppearance() {
    // Resolve the root surface with the sheet's traits, never the light host
    // window's traits. Reapply after a preference reply changes appearance.
    overrideUserInterfaceStyle = model.interfaceStyle
    hosting?.overrideUserInterfaceStyle = model.interfaceStyle
    viewIfLoaded?.backgroundColor = model.background
    viewIfLoaded?.tintColor = model.accent
    navigationController?.overrideUserInterfaceStyle = model.interfaceStyle
    navigationController?.viewIfLoaded?.backgroundColor = model.background
    navigationController?.viewIfLoaded?.tintColor = model.accent
  }
  #if targetEnvironment(simulator)
  var appearanceSnapshot: [String: Any] {
    ["dark": model.dark, "controllerStyle": traitCollection.userInterfaceStyle.rawValue,
      "hostingStyle": hosting?.traitCollection.userInterfaceStyle.rawValue ?? 0]
  }
  #endif
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onInteractiveDismiss?() }
  private func pickColor(_ row: ReaderFormRow) {
    colorRow = row
    let picker = UIColorPickerViewController()
    picker.supportsAlpha = false; picker.selectedColor = readerColor(row.data["value"]); picker.delegate = self
    present(picker, animated: true)
  }
  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    guard let row = colorRow else { return }; colorRow = nil
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    viewController.selectedColor.getRed(&r, green: &g, blue: &b, alpha: &a)
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
    let argb = 0xff000000 | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    model.commit(row, Int64(argb))
  }
  private func pickPhoto(_ row: ReaderFormRow) {
    photoRow = row
    var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
    present(picker, animated: true)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let row = photoRow; photoRow = nil
    picker.dismiss(animated: true)
    guard let row, let provider = results.first?.itemProvider else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
      DispatchQueue.main.async {
        guard let self, let image = object as? UIImage else {
          if let error { self?.model.showError?(error.localizedDescription) }; return
        }
        let scale = min(1, 3072 / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = normalized.pngData(), data.count <= 64 * 1024 * 1024 else {
          self.model.showError?("背景图片过大或无法读取"); return
        }
        self.model.commit(row, FlutterStandardTypedData(bytes: data))
      }
    }
  }
}
