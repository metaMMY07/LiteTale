import AVFoundation
import Flutter
import UIKit

final class ReaderSpeechChannel: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private lazy var synthesizer: AVSpeechSynthesizer = {
    let engine = AVSpeechSynthesizer()
    engine.delegate = self
    engine.usesApplicationAudioSession = true
    return engine
  }()
  private lazy var session = AVAudioSession.sharedInstance()
  private var observers: [NSObjectProtocol] = []
  private var sink: FlutterEventSink?
  private var utterance: AVSpeechUtterance?
  private var utteranceID: String?
  private var ownsAudioSession = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "litetale/reader_speech", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "speech_unavailable", message: "系统朗读不可用", details: nil))
          return
        }
        self.handle(call, result: result)
      }
    FlutterEventChannel(name: "litetale/reader_speech/events", binaryMessenger: messenger)
      .setStreamHandler(self)
    let notifications = NotificationCenter.default
    observers = [
      notifications.addObserver(forName: AVAudioSession.interruptionNotification,
        object: nil, queue: .main) { [weak self] in self?.audioInterrupted($0) },
      notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
        object: nil, queue: .main) { [weak self] in self?.audioRouteChanged($0) },
      notifications.addObserver(forName: UIApplication.willResignActiveNotification,
        object: nil, queue: .main) { [weak self] _ in self?.interrupt() },
    ]
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    stop()
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "voices":
      let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
        ($0.language, $0.name) < ($1.language, $1.name)
      }.map { voice in
        ["id": voice.identifier, "name": voice.name, "language": voice.language]
      }
      result(["limit": 1000, "voices": voices])
    case "speak":
      speak(call.arguments, result: result)
    case "pause":
      result(owns(call.arguments) && synthesizer.pauseSpeaking(at: .immediate))
    case "resume":
      result(owns(call.arguments) && UIApplication.shared.applicationState == .active && synthesizer.continueSpeaking())
    case "stop":
      if owns(call.arguments) { stop() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func owns(_ argument: Any?) -> Bool {
    guard let id = argument as? String else { return false }
    return id == utteranceID
  }

  private func speak(_ argument: Any?, result: FlutterResult) {
    guard let args = argument as? [String: Any],
          let id = args["id"] as? String, let text = args["text"] as? String,
          !text.isEmpty, text.utf16.count <= 1000,
          let rate = args["rate"] as? Double, rate.isFinite else {
      stop()
      result(FlutterError(code: "invalid_speech", message: "朗读内容无效", details: nil))
      return
    }
    guard UIApplication.shared.applicationState == .active else {
      result(FlutterError(code: "speech_inactive", message: "请返回阅读器继续朗读", details: nil))
      return
    }
    let voice: AVSpeechSynthesisVoice?
    if let identifier = args["voice"] as? String {
      voice = AVSpeechSynthesisVoice(identifier: identifier)
    } else {
      voice = AVSpeechSynthesisVoice(language: "zh-CN") ??
        AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh-") }
    }
    guard let voice else {
      stop()
      result(FlutterError(code: "voice_unavailable", message: "该语音不可用，请在系统设置安装或选择其他音色", details: nil))
      return
    }

    clearUtterance()
    do {
      if !ownsAudioSession {
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        ownsAudioSession = true
      }
    } catch {
      result(FlutterError(code: "speech_audio", message: "无法启用朗读音频，请重试", details: nil))
      return
    }
    let next = AVSpeechUtterance(string: text)
    next.voice = voice
    next.rate = min(AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
    utteranceID = id
    utterance = next
    synthesizer.speak(next)
    result(nil)
  }

  private func clearUtterance() {
    let hadUtterance = utterance != nil
    utteranceID = nil
    utterance = nil
    if hadUtterance && (synthesizer.isSpeaking || synthesizer.isPaused) {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func stop() {
    clearUtterance()
    if ownsAudioSession {
      ownsAudioSession = false
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func interrupt() {
    guard let id = utteranceID else { return }
    stop()
    sink?(["id": id, "type": "interrupted"])
  }

  private func audioInterrupted(_ notification: Notification) {
    guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          type == AVAudioSession.InterruptionType.began.rawValue else { return }
    interrupt()
  }

  private func audioRouteChanged(_ notification: Notification) {
    guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
    interrupt()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish spoken: AVSpeechUtterance) {
    send("done", for: spoken)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel spoken: AVSpeechUtterance) {
    send("interrupted", for: spoken)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance spoken: AVSpeechUtterance) {
    send("range", for: spoken, start: range.location)
  }

  private func send(_ type: String, for spoken: AVSpeechUtterance, start: Int? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.utterance === spoken, let id = self.utteranceID else { return }
      if type == "interrupted" { self.stop() }
      var event: [String: Any] = ["id": id, "type": type]
      if let start { event["start"] = start }
      self.sink?(event)
    }
  }
}
