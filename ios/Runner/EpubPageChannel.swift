import Flutter
import UIKit
import WebKit
import Network

/// Bounded, offline WebKit counterpart of Android's CSS/Foliate channel.
/// The loopback origin is private to this renderer; it never serves source
/// sessions, cookies, filesystem paths or unregistered publication resources.
final class EpubPageChannel: NSObject {
  private let channel: FlutterMethodChannel
  private weak var parent: UIViewController?
  private var sessions: [String: EpubWebSession] = [:]
  private var order: [String] = []
  private var pending: FlutterResult?
  private var active: String?
  private var generation = 0
  private var deadline: DispatchWorkItem?
  private var listener: NWListener?
  private var port: UInt16?
  private var serverReady: ((UInt16?) -> Void)?
  private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var connections = 0
  private let processPool = WKProcessPool()
  private let encoder = DispatchQueue(label: "litetale.epub.png", qos: .userInitiated)

  init(parent: UIViewController, messenger: FlutterBinaryMessenger) {
    self.parent = parent
    channel = FlutterMethodChannel(name: "litetale/epub_pages", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func asset(_ name: String) -> Data? {
    let key = FlutterDartProject.lookupKey(forAsset: "lib/assets/" + name)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: path))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "capabilities" {
      result(["engine": "webkit-foliate", "os": UIDevice.current.systemVersion, "pool": sessions.count])
      return
    }
    if call.method == "close" {
      let ids = args["all"] as? Bool == true ? Array(sessions.keys) : args["ids"] as? [String] ?? []
      for id in ids { remove(id) }
      if let active, ids.contains(active) { fail("closed", "阅读器已关闭") }
      result(nil)
      return
    }
    guard pending == nil else { result(FlutterError(code: "busy", message: "阅读器正在排版", details: nil)); return }
    guard let id = args["id"] as? String,
          id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      result(FlutterError(code: "invalid", message: "页面编号无效", details: nil)); return
    }
    switch call.method {
    case "prepare":
      if let session = sessions[id], let metadata = session.metadata {
        touch(id); result(metadata); return
      }
      guard let html = args["html"] as? String, html.utf8.count <= 12 * 1024 * 1024,
            var options = args["options"] as? [String: Any],
            let width = options["width"] as? NSNumber, let height = options["height"] as? NSNumber,
            (100...3000).contains(width.doubleValue), (100...5000).contains(height.doubleValue) else {
        result(FlutterError(code: "invalid", message: "本地页面参数无效", details: nil)); return
      }
      var resources: [String: Data] = [:]
      var total = 0
      for (name, raw) in args["resources"] as? [String: Any] ?? [:] {
        guard name.range(of: "^[a-f0-9]{64}\\.(png|jpe?g|gif|webp|bmp|avif|ttf|otf|woff2?)$", options: .regularExpression) != nil,
              let typed = raw as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid", message: "本地资源无效", details: nil)); return
        }
        total += typed.data.count
        guard total <= 40 * 1024 * 1024 else {
          result(FlutterError(code: "invalid", message: "本地资源过大", details: nil)); return
        }
        resources[name] = typed.data
      }
      let font = (args["userFont"] as? FlutterStandardTypedData)?.data
      guard (font?.count ?? 0) <= 64 * 1024 * 1024,
            let paginator = asset("epub_foliate_paginator.js"),
            let engine = asset("epub_page_engine.js"),
            let serif = asset("fonts/LXGWNeoZhiSongPlus.ttf") else {
        result(FlutterError(code: "invalid", message: "本地排版资源缺失或过大", details: nil)); return
      }
      begin(id, result: result)
      let token = generation
      startServer { [weak self] port in
        guard let self, self.valid(id, token) else { return }
        guard let port, let parent = self.parent, let container = parent.view.superview else {
          self.fail("epub_server", "无法启动离线排版组件"); return
        }
        while self.order.count >= 3, let first = self.order.first { self.remove(first) }
        let base = "http://127.0.0.1:\(port)/\(self.nonce)/\(id)"
        options["chapterUrl"] = base + "/chapter"
        let session = EpubWebSession(id: id, base: base, html: html, options: options,
          resources: resources, font: font, paginator: paginator, engine: engine, serif: serif,
          processPool: self.processPool, owner: self)
        self.sessions[id] = session; self.touch(id)
        // Keep WebKit in a live window, below Flutter, without a transparent
        // on-screen copy of the publication or an offscreen raster tile strip.
        container.insertSubview(session.host, belowSubview: parent.view)
        session.start()
      }
    case "capture":
      guard let session = sessions[id], let metadata = session.metadata else {
        result(FlutterError(code: "missing_session", message: "页面需要重新排版", details: nil)); return
      }
      let page = (args["page"] as? NSNumber)?.intValue ?? -1
      guard page >= 0, page < (metadata["count"] as? Int ?? 0) else {
        result(FlutterError(code: "invalid", message: "页码无效", details: nil)); return
      }
      touch(id); begin(id, result: result)
      let token = generation
      session.web.evaluateJavaScript("EpubEngine.select(\(page)).catch(e=>EpubEngine.error=String(e));null") { [weak self] _, error in
        guard let self, self.valid(id, token) else { return }
        if error != nil { self.fail("epub_layout", "本地页面切换失败") }
        else { self.poll(session, capture: true, token: token) }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func touch(_ id: String) { order.removeAll { $0 == id }; order.append(id) }
  private func remove(_ id: String) { sessions.removeValue(forKey: id)?.destroy(); order.removeAll { $0 == id } }
  private func begin(_ id: String, result: @escaping FlutterResult) {
    generation += 1; active = id; pending = result
    let token = generation
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.valid(id, token) else { return }
      self.remove(id); self.fail("epub_timeout", "本地 CSS 排版超时，请重试")
    }
    deadline = task; DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: task)
  }
  fileprivate func valid(_ id: String, _ token: Int) -> Bool { pending != nil && active == id && generation == token }
  private func finish(_ value: Any?) {
    deadline?.cancel(); deadline = nil
    let result = pending; pending = nil; active = nil; generation += 1
    result?(value)
  }
  fileprivate func fail(_ code: String, _ message: String) {
    finish(FlutterError(code: code, message: message, details: nil))
  }
  fileprivate func loaded(_ session: EpubWebSession) {
    guard active == session.id, pending != nil else { return }
    let token = generation
    guard let data = try? JSONSerialization.data(withJSONObject: session.options),
          let json = String(data: data, encoding: .utf8) else { fail("invalid", "排版参数无效"); return }
    session.web.evaluateJavaScript("startEpub(\(json));null") { [weak self] _, error in
      guard let self, self.valid(session.id, token) else { return }
      if error != nil { self.fail("epub_layout", "本章 CSS 排版失败") }
      else { self.poll(session, capture: false, token: token) }
    }
  }
  fileprivate func terminated(_ session: EpubWebSession) {
    let wasActive = active == session.id
    remove(session.id)
    if wasActive { fail("epub_process", "本地排版组件已退出，请重试") }
  }
  private func poll(_ session: EpubWebSession, capture: Bool, token: Int) {
    guard valid(session.id, token) else { return }
    let expression = capture
      ? "({ready:!!window.EpubEngine?.ready,selected:!!window.EpubEngine?.selected,error:window.EpubEngine?.error})"
      : "(window.EpubEngine?.ready?{ready:true,error:window.EpubEngine.error,pages:window.EpubEngine.pages,textLength:window.EpubEngine.textLength,text:window.EpubEngine.text}:{ready:false,error:window.EpubEngine?.error})"
    session.web.evaluateJavaScript(expression) { [weak self] raw, error in
      guard let self, self.valid(session.id, token) else { return }
      guard error == nil, let info = raw as? [String: Any], info["error"] as? String == nil else {
        self.remove(session.id); self.fail("epub_layout", "本章 CSS 排版失败"); return
      }
      if info["ready"] as? Bool != true || (capture && info["selected"] as? Bool != true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in self?.poll(session, capture: capture, token: token) }
      } else if capture {
        // select() waits two animation frames before setting selected. WebKit's
        // snapshot waits for screen updates as a final compositor fence.
        let config = WKSnapshotConfiguration(); config.rect = session.web.bounds
        session.web.takeSnapshot(with: config) { [weak self] image, error in
          guard let self, self.valid(session.id, token) else { return }
          guard error == nil, let image else { self.fail("epub_capture", "无法绘制本地页面"); return }
          self.encoder.async { [weak self] in
            let bytes = image.pngData()
            DispatchQueue.main.async {
              guard let self, self.valid(session.id, token) else { return }
              if let bytes { self.finish(FlutterStandardTypedData(bytes: bytes)) }
              else { self.fail("epub_capture", "本地页面编码失败") }
            }
          }
        }
      } else {
        guard let pages = info["pages"] as? [[String: Any]], !pages.isEmpty, pages.count <= 12000,
              let text = info["text"] as? String, text.utf16.count <= 12 * 1024 * 1024 else {
          self.fail("epub_layout", "本地 CSS 分页结果无效"); return
        }
        var ranges: [[String: Int]] = []
        for page in pages {
          guard let start = page["start"] as? NSNumber, let end = page["end"] as? NSNumber,
                start.intValue >= 0, end.intValue >= start.intValue, end.intValue <= 32 * 1024 * 1024 else {
            self.fail("epub_layout", "本地阅读位置无效"); return
          }
          ranges.append(["start": start.intValue, "end": end.intValue])
        }
        let metadata: [String: Any] = ["count": ranges.count, "ranges": ranges, "text": text,
          "textLength": (info["textLength"] as? NSNumber)?.intValue ?? text.utf16.count]
        session.metadata = metadata; self.finish(metadata)
      }
    }
  }

  private func startServer(_ ready: @escaping (UInt16?) -> Void) {
    if let port { ready(port); return }
    serverReady = ready
    guard listener == nil else { return }
    do {
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let server = try NWListener(using: params)
      listener = server
      server.stateUpdateHandler = { [weak self, weak server] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.port = server?.port?.rawValue
          let callback = self.serverReady; self.serverReady = nil; callback?(self.port)
        case .failed:
          let callback = self.serverReady; self.serverReady = nil
          self.listener?.cancel(); self.listener = nil; callback?(nil)
        default: break
        }
      }
      server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      server.start(queue: .main)
    } catch { serverReady = nil; ready(nil) }
  }
  private func accept(_ connection: NWConnection) {
    guard connections < 64 else { connection.cancel(); return }
    connections += 1
    var finished = false
    let close = { [weak self] in
      guard !finished else { return }; finished = true
      connection.cancel(); self?.connections -= 1
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: close)
    receive(connection, data: Data(), close: close)
  }
  private func receive(_ connection: NWConnection, data: Data, close: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] chunk, _, complete, error in
      guard let self, error == nil else { close(); return }
      var header = data; header.append(chunk ?? Data())
      guard header.count <= 16384 else { close(); return }
      guard header.range(of: Data("\r\n\r\n".utf8)) != nil else {
        if complete { close() } else { self.receive(connection, data: header, close: close) }; return
      }
      let request = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
      guard request.count == 3, request[0] == "GET" else { close(); return }
      let parts = request[1].split(separator: "/").map(String.init)
      var body = Data(); var mime = "text/plain"; var ok = false
      if parts.count >= 3, parts[0] == self.nonce, let session = self.sessions[parts[1]],
         let response = session.resource(Array(parts.dropFirst(2))) {
        body = response.1; mime = response.0; ok = true
      }
      let response = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; frame-src 'self'; img-src 'self' data:; font-src 'self'\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
        guard error == nil else { close(); return }
        connection.send(content: body, completion: .contentProcessed { _ in close() })
      })
    }
  }
}

fileprivate final class EpubWebSession: NSObject, WKNavigationDelegate {
  let id: String, base: String
  let web: WKWebView, host: UIView
  let options: [String: Any]
  var metadata: [String: Any]?
  private let html: String, paginator: Data, engine: Data, serif: Data
  private let resources: [String: Data], font: Data?
  private weak var owner: EpubPageChannel?
  private var started = false
  init(id: String, base: String, html: String, options: [String: Any], resources: [String: Data],
       font: Data?, paginator: Data, engine: Data, serif: Data,
       processPool: WKProcessPool, owner: EpubPageChannel) {
    self.id = id; self.base = base; self.options = options; self.resources = resources; self.font = font
    self.html = html.replacingOccurrences(of: "https://litetale-epub.invalid", with: base)
    self.paginator = paginator; self.serif = serif
    self.engine = Data((String(data: engine, encoding: .utf8) ?? "")
      .replacingOccurrences(of: "https://litetale-epub.invalid", with: base).utf8)
    self.owner = owner
    let frame = CGRect(x: 0, y: 0, width: (options["width"] as? NSNumber)?.doubleValue ?? 390,
      height: (options["height"] as? NSNumber)?.doubleValue ?? 844)
    host = UIView(frame: frame)
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.processPool = processPool
    config.allowsInlineMediaPlayback = false
    web = WKWebView(frame: frame, configuration: config)
    super.init()
    host.clipsToBounds = true; host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true
    web.navigationDelegate = self; web.isOpaque = true
    web.scrollView.isScrollEnabled = false; web.scrollView.contentInsetAdjustmentBehavior = .never
    web.scrollView.bounces = false; web.isAccessibilityElement = false
    host.addSubview(web)
  }
  func start() { if let url = URL(string: base + "/index") { web.load(URLRequest(url: url)) } }
  func destroy() { web.stopLoading(); web.navigationDelegate = nil; host.removeFromSuperview() }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !started else { return }; started = true; owner?.loaded(self)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    owner?.terminated(self)
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url?.absoluteString ?? ""
    decisionHandler(url.hasPrefix(base + "/") || url == "about:blank" ? .allow : .cancel)
  }
  func resource(_ path: [String]) -> (String, Data)? {
    guard let first = path.first else { return nil }
    switch first {
    case "index":
      guard path.count == 1 else { return nil }
      return ("text/html; charset=utf-8", Data("""
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src 'self';style-src 'unsafe-inline';frame-src 'self';img-src 'self' data:;font-src 'self';">
      <script type="module" src="\(base)/paginator.js"></script><script src="\(base)/engine.js"></script></head><body></body></html>
      """.utf8))
    case "chapter": return path.count == 1 ? ("text/html; charset=utf-8", Data(html.utf8)) : nil
    case "paginator.js": return path.count == 1 ? ("text/javascript", paginator) : nil
    case "engine.js": return path.count == 1 ? ("text/javascript", engine) : nil
    case "reader-serif.ttf": return path.count == 1 ? ("font/ttf", serif) : nil
    case "user-font": return path.count == 1 ? ("font/ttf", font ?? Data()) : nil
    case "resource":
      guard path.count == 2, let bytes = resources[path[1]] else { return nil }
      let ext = path[1].split(separator: ".").last.map(String.init) ?? ""
      let mime: String
      switch ext {
      case "jpg", "jpeg": mime = "image/jpeg"
      case "ttf", "otf", "woff", "woff2": mime = "font/" + ext
      default: mime = "image/" + ext
      }
      return (mime, bytes)
    default: return nil
    }
  }
}
