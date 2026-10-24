import Flutter
import UIKit
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate {

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

  private var volumeEventSink: FlutterEventSink?
  private var audioSession: AVAudioSession?
  private var volumeView: MPVolumeView?
  private var silentPlayer: AVAudioPlayer?
  private var previousVolume: Float = 0.5  // 使用者的原始音量，重設目標
  private var isObservingVolume = false
  private var isResettingVolume = false     // 防止自己的重設再次觸發事件

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let applicationSupportsPath = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
    let controller = self.window!.rootViewController as! FlutterViewController

    let channel = FlutterMethodChannel(name: "methods", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
            if call.method == "dataRoot" {
                result(applicationSupportsPath)
            } else if call.method == "documentRoot" {
               result(documentsPath)
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
            } else if call.method == "reassertAudioSession" {
                self.assertAudioSessionCategory()
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

    let volumeChannel = FlutterEventChannel(name: "volume_button", binaryMessenger: controller.binaryMessenger)
    volumeChannel.setStreamHandler(self)

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

  // 產生靜音 WAV 資料（0.1秒，8000Hz，8-bit mono）
  private func makeSilentWavData() -> Data {
    let sampleRate: UInt32 = 8000
    let dataSize: UInt32 = sampleRate / 10  // 0.1 秒
    var d = Data()
    func appendU32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    func appendU16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    d.append(contentsOf: "RIFF".utf8)
    appendU32(36 + dataSize)
    d.append(contentsOf: "WAVE".utf8)
    d.append(contentsOf: "fmt ".utf8)
    appendU32(16)
    appendU16(1)          // PCM
    appendU16(1)          // mono
    appendU32(sampleRate)
    appendU32(sampleRate) // byteRate
    appendU16(1)          // blockAlign
    appendU16(8)          // bitsPerSample
    d.append(contentsOf: "data".utf8)
    appendU32(dataSize)
    d.append(contentsOf: [UInt8](repeating: 0x80, count: Int(dataSize))) // 8-bit 靜音
    return d
  }

  private func assertAudioSessionCategory() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, options: .mixWithOthers)
      try session.setActive(true)
    } catch {}
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    if type == .ended {
      assertAudioSessionCategory()
    }
  }

  private func setupVolumeObserver() {
    assertAudioSessionCategory()
    let session = AVAudioSession.sharedInstance()
    audioSession = session
    previousVolume = session.outputVolume

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: session
    )

    if !isObservingVolume {
      session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
      isObservingVolume = true
    }

    // 播放靜音音效，保持 audio session 活躍以抑制系統音量 HUD
    if silentPlayer == nil {
      if let player = try? AVAudioPlayer(data: makeSilentWavData()) {
        player.numberOfLoops = -1  // 無限循環
        player.volume = 0
        player.play()
        silentPlayer = player
      }
    }

    DispatchQueue.main.async {
      let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
      vv.alpha = 0.01
      if let window = UIApplication.shared.windows.first {
        window.addSubview(vv)
      }
      self.volumeView = vv
      // 不改變音量，保留使用者原始音量作為重設基準
    }
  }

  private func removeVolumeObserver() {
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: audioSession)
    if isObservingVolume {
      audioSession?.removeObserver(self, forKeyPath: "outputVolume")
      isObservingVolume = false
    }
    silentPlayer?.stop()
    silentPlayer = nil
    DispatchQueue.main.async {
      self.volumeView?.removeFromSuperview()
      self.volumeView = nil
    }
    audioSession = nil
  }

  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == "outputVolume",
          let sink = volumeEventSink,
          let newVolume = change?[.newKey] as? Float else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }

    DispatchQueue.main.async {
      // 跳過由我們自己重設音量所觸發的回呼
      if self.isResettingVolume {
        self.isResettingVolume = false
        return
      }

      if newVolume > self.previousVolume {
        sink("UP")
      } else if newVolume < self.previousVolume {
        sink("DOWN")
      }

      // 重設回使用者的原始音量，確保可連續偵測
      self.isResettingVolume = true
      if let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
        slider.value = self.previousVolume
      }
      // previousVolume 維持不變，始終代表使用者進入閱讀前的音量
    }
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    volumeEventSink = events
    setupVolumeObserver()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    volumeEventSink = nil
    removeVolumeObserver()
    return nil
  }
}
