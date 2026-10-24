import Flutter
import UIKit

/// Public iOS document handoff. The user chooses Books in the system sheet;
/// applications cannot silently import into another application's library.
final class AppleBooksChannel: NSObject {
  private let channel: FlutterMethodChannel
  private weak var parent: UIViewController?
  private weak var activity: UIActivityViewController?
  private var pending: FlutterResult?

  init(parent: UIViewController, messenger: FlutterBinaryMessenger) {
    self.parent = parent
    channel = FlutterMethodChannel(name: "litetale/apple_books", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "打开组件已关闭", details: nil)); return }
      switch call.method {
      case "open": self.open(call.arguments as? [String: Any] ?? [:], result: result)
      case "status": result(self.activity?.presentingViewController != nil)
      case "cancel":
        if let activity = self.activity {
          activity.dismiss(animated: false) { [weak self] in self?.finish(completed: false); result(nil) }
        } else { self.finish(completed: false); result(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func open(_ args: [String: Any], result: @escaping FlutterResult) {
    guard pending == nil else { result(FlutterError(code: "busy", message: "系统打开菜单已显示", details: nil)); return }
    guard let path = args["path"] as? String else { result(FlutterError(code: "invalid", message: "EPUB 文件无效", details: nil)); return }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
    guard url.path.hasPrefix(home), url.pathExtension.lowercased() == "epub",
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          let size = attrs[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 256 * 1024 * 1024 else {
      result(FlutterError(code: "missing_file", message: "原 EPUB 已不可用，请重新导入", details: nil)); return
    }
    let item = BooksDocument(url: url, title: args["title"] as? String ?? "EPUB 电子书")
    let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    sheet.completionWithItemsHandler = { [weak self] type, completed, _, _ in
      self?.finish(completed: completed, activity: type?.rawValue ?? "")
    }
    pending = result; activity = sheet
    presentWhenReady(sheet, attempt: 0)
  }

  private func presentWhenReady(_ sheet: UIActivityViewController, attempt: Int) {
    guard pending != nil, activity === sheet else { return }
    guard var presenter = parent else { failWindow(); return }
    while let top = presenter.presentedViewController { presenter = top }
    // Document pickers can return the file before their dismissal completes.
    if presenter.isBeingDismissed || presenter.isBeingPresented || presenter is UIDocumentPickerViewController || UIApplication.shared.applicationState != .active {
      guard attempt < 12 else { failWindow(); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.presentWhenReady(sheet, attempt: attempt + 1) }
      return
    }
    guard presenter.viewIfLoaded?.window != nil else { failWindow(); return }
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private func failWindow() {
    let result = pending; pending = nil; activity = nil
    result?(FlutterError(code: "no_window", message: "请关闭当前窗口后重试", details: nil))
  }

  private func finish(completed: Bool, activity: String = "") {
    let result = pending; pending = nil; self.activity = nil
    result?(["completed": completed, "activity": activity])
  }
}

private final class BooksDocument: NSObject, UIActivityItemSource {
  let url: URL
  let title: String
  init(url: URL, title: String) { self.url = url; self.title = title }
  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }
  func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }
  func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }
  func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { "org.idpf.epub-container" }
}
