import Flutter
import UIKit
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate {

  private func systemColors(_ style: UIUserInterfaceStyle) -> [String: Int] {
    let traits = UITraitCollection(traitsFrom: [UIScreen.main.traitCollection, UITraitCollection(userInterfaceStyle: style)])
    let values: [String: UIColor] = [
      "ios-blue": .systemBlue, "ios-indigo": .systemIndigo, "ios-purple": .systemPurple,
      "ios-pink": .systemPink, "ios-red": .systemRed, "ios-orange": .systemOrange,
      "ios-yellow": .systemYellow, "ios-green": .systemGreen, "ios-teal": .systemTeal,
      "background": .systemGroupedBackground, "surface": .secondarySystemGroupedBackground,
      "tertiarySurface": .tertiarySystemGroupedBackground, "label": .label,
      "secondaryLabel": .secondaryLabel, "separator": .separator,
      "opaqueSeparator": .opaqueSeparator, "fill": .tertiarySystemFill,
    ]
    return values.mapValues { color in
      let resolved = color.resolvedColor(with: traits)
      var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
      resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
      return (byte(alpha) << 24) | (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }
  }

  private enum LauncherIcon: String, CaseIterable {
    case iris, blue, rose, orange, teal, green

    var assetName: String? {
      self == .iris ? nil : "AppIcon" + rawValue.capitalized
    }

    static func selected(assetName: String?) -> LauncherIcon {
      allCases.first { $0.assetName == assetName } ?? .iris
    }
  }

  private var isChangingLauncherIcon = false
  private var paletteChannel: FlutterMethodChannel?
  private var readerImages: ReaderImageChannel?
  private var readerPanel: AppleReaderPanelChannel?

  private var readerSpeech: ReaderSpeechChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let applicationSupportsPath = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
    let controller = self.window!.rootViewController as! FlutterViewController
    let palette = FlutterMethodChannel(name: "litetale/apple_palette", binaryMessenger: controller.binaryMessenger)
    palette.setMethodCallHandler { [weak self] call, result in
      guard call.method == "colors", let self else { result(FlutterMethodNotImplemented); return }
      result(["light": self.systemColors(.light), "dark": self.systemColors(.dark)])
    }
    paletteChannel = palette
    readerImages = ReaderImageChannel(parent: controller, messenger: controller.binaryMessenger)
    readerPanel = AppleReaderPanelChannel(parent: controller, messenger: controller.binaryMessenger)
    readerSpeech = ReaderSpeechChannel(messenger: controller.binaryMessenger)
    AppleThemeReveal.shared.install(messenger: controller.binaryMessenger, window: { [weak self] in self?.window })

    let channel = FlutterMethodChannel(name: "methods", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
            if call.method == "dataRoot" {
                result(applicationSupportsPath)
            } else if call.method == "documentRoot" {
               result(documentsPath)
            } else if call.method == "iosSystemVersion" {
                result(UIDevice.current.systemVersion)
            } else if call.method == "testSourceDocumentPicker" {
                #if targetEnvironment(simulator)
                // Simulator acceptance drives the real file_selector picker;
                // this bridge is absent from the device IPA.
                guard let picker = controller.presentedViewController as? UIDocumentPickerViewController else {
                    result(false)
                    return
                }
                let args = call.arguments as? [String: Any]
                if let path = args?["selectPath"] as? String {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    let root = URL(fileURLWithPath: applicationSupportsPath).standardizedFileURL.path + "/"
                    guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else {
                        result(FlutterError(code: "invalid_fixture", message: "Expected an app-owned source fixture", details: nil))
                        return
                    }
                    picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [url])
                    picker.dismiss(animated: true)
                } else if args?["cancel"] as? Bool == true {
                    picker.delegate?.documentPickerWasCancelled?(picker)
                    picker.dismiss(animated: true)
                }
                result(true)
                #else
                result(FlutterMethodNotImplemented)
                #endif
            } else if call.method == "getKeepScreenOn" {
                result(application.isIdleTimerDisabled)
            }
            else if call.method == "setKeepScreenOn" {
                if let args = call.arguments as? Bool {
                    DispatchQueue.main.async { () -> Void in
                        application.isIdleTimerDisabled = args
                    }
                }
                result(nil as Any?)
            } else {
                result(FlutterMethodNotImplemented)
            }
    }

    let iconChannel = FlutterMethodChannel(
      name: "litetale/launcher_icon", binaryMessenger: controller.binaryMessenger
    )
    iconChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Application is unavailable", details: nil))
        return
      }
      self.handleLauncherIcon(call, result: result)
    }

    if let registrar = registrar(forPlugin: "LiteTaleAppleGlass") {
      registrar.register(
        AppleReaderSettingsFactory(messenger: controller.binaryMessenger, parent: controller),
        withId: "litetale/reader_settings")
      registrar.register(
        AppleGlassFactory(messenger: controller.binaryMessenger, parent: controller),
        withId: "litetale/apple_glass"
      )
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleLauncherIcon(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let application = UIApplication.shared
    switch call.method {
    case "getIcon":
      result(LauncherIcon.selected(assetName: application.alternateIconName).rawValue)
    case "setIcon":
      guard let name = call.arguments as? String, let icon = LauncherIcon(rawValue: name) else {
        result(FlutterError(code: "invalid_icon", message: "Unknown launcher icon", details: nil))
        return
      }
      if application.alternateIconName == icon.assetName {
        result(icon.rawValue)
        return
      }
      guard application.supportsAlternateIcons, !isChangingLauncherIcon else {
        result(FlutterError(code: "icon_unavailable", message: "Icon change is unavailable", details: nil))
        return
      }
      isChangingLauncherIcon = true
      application.setAlternateIconName(icon.assetName) { [weak self] error in
        DispatchQueue.main.async {
          self?.isChangingLauncherIcon = false
          if let error {
            result(FlutterError(code: "icon_change_failed", message: error.localizedDescription, details: nil))
          } else {
            result(icon.rawValue)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

}

/// Image export stays separate from source account sessions.
private final class ReaderImageChannel: NSObject {
  private let channel: FlutterMethodChannel
  private weak var parent: UIViewController?
  private var pending: FlutterResult?

  init(parent: UIViewController, messenger: FlutterBinaryMessenger) {
    self.parent = parent
    channel = FlutterMethodChannel(name: "litetale/reader_images", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: "图片窗口已关闭", details: nil)); return }
      self.handle(call, result: result)
    }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "save" || call.method == "export" else { result(FlutterMethodNotImplemented); return }
    guard pending == nil else { result(FlutterError(code: "image_busy", message: "请先完成当前保存", details: nil)); return }
    guard let args = call.arguments as? [String: Any], let typed = args["bytes"] as? FlutterStandardTypedData,
          !typed.data.isEmpty, typed.data.count <= 20 * 1024 * 1024,
          let name = args["name"] as? String, !name.isEmpty, name.count <= 150,
          !name.contains("/"), !name.contains("\\"),
          let mime = args["mime"] as? String,
          ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/avif"].contains(mime) else {
      result(FlutterError(code: "invalid_image", message: "图片数据无效", details: nil)); return
    }
    pending = result
    if call.method == "export" { export(typed.data, name: name); return }
    guard #available(iOS 14, *) else { finishError("当前系统请使用导出原图"); return }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      DispatchQueue.main.async {
        guard let self else { return }
        guard status == .authorized || status == .limited else { self.finishError("未获得添加照片的权限，请使用导出原图"); return }
        PHPhotoLibrary.shared().performChanges({
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = name
          PHAssetCreationRequest.forAsset().addResource(with: .photo, data: typed.data, options: options)
        }) { [weak self] success, _ in
          DispatchQueue.main.async {
            guard let self else { return }
            if success { self.finish("saved") } else { self.finishError("未能保存到相册，请使用导出原图") }
          }
        }
      }
    }
  }
  private func export(_ data: Data, name: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-image-" + UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent(name)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        DispatchQueue.main.async {
          guard let self else { return }
          guard let parent = self.parent, parent.presentedViewController == nil else {
            self.removeTemporary(url, directory: directory); self.finishError("请关闭当前系统窗口后重试"); return
          }
          let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
          if let popover = sheet.popoverPresentationController {
            popover.sourceView = parent.view
            popover.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.maxY - 80, width: 1, height: 1)
            popover.permittedArrowDirections = []
          }
          sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
            DispatchQueue.main.async {
              guard let self else { return }
              self.removeTemporary(url, directory: directory)
              if error != nil { self.finishError("图片导出失败") }
              else { self.finish(completed ? "exported" : "cancelled") }
            }
          }
          parent.present(sheet, animated: true)
        }
      } catch {
        DispatchQueue.main.async { self?.removeTemporary(url, directory: directory); self?.finishError("无法准备图片文件") }
      }
    }
  }
  private func removeTemporary(_ file: URL, directory: URL) {
    // Only this operation's one temporary file and now-empty directory.
    DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: directory) }
  }
  private func finish(_ status: String) { let result = pending; pending = nil; result?(status) }
  private func finishError(_ message: String) { let result = pending; pending = nil; result?(FlutterError(code: "image_save", message: message, details: nil)) }
}
