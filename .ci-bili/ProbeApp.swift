import Foundation
import UIKit
import WebKit

@main
@MainActor
final class ProbeApp: UIResponder, UIApplicationDelegate, WKNavigationDelegate {
    var window: UIWindow?
    private let destination = URL(string: "https://www.bilinovel.net/novel/3605/209868.html")!
    private var web: WKWebView?
    private var scenario = 0
    private let profiles = ["mobile", "desktop", "mobile-compatibility"]
    private var results: [[String: Any]] = []
    private var sampling = false
    private var summaryScript = ""

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let control = UIViewController()
        control.view.backgroundColor = .systemBackground
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = control
        self.window = window
        window.makeKeyAndVisible()

        guard let scriptURL = Bundle.main.url(forResource: "chapter-script", withExtension: "json"),
              let scriptData = try? Data(contentsOf: scriptURL),
              let source = (try? JSONSerialization.jsonObject(with: scriptData, options: .fragmentsAllowed)) as? String else {
            complete(["error": "missing-probe"])
            return true
        }
        summaryScript = #"""
        (() => {
          const result = JSON.parse(\#(source));
          const content = String(result.content ?? "");
          const compact = content.replace(new RegExp("[\\s\\u00ad\\u200b-\\u200f\\u202a-\\u202e\\u2060\\u2066-\\u2069\\ufeff]", "g"), "");
          return JSON.stringify({
            guardRecognized: new RegExp("[网網]站[阅閱閲][读讀]器[升昇][级級].{0,24}[浏瀏][览覽]器似乎[无無]法完美使用本(?:[网網])?站.{0,120}(?:Chrome.{0,48}Safari|Safari.{0,48}Chrome).{0,40}原生[浏瀏][览覽]器", "i").test(compact),
            ready: result.ready === true,
            paragraphs: content.split("\n").filter(Boolean).length,
            length: content.length,
            browserNotice: /[网網]站[阅閱閲][读讀]器[升昇][级級]/.test(compact) &&
              /Chrome/i.test(compact) && /Safari/i.test(compact),
            accessDenied: result.accessDenied === true,
            verificationRequired: result.verificationRequired === true,
            contentIncomplete: result.contentIncomplete === true,
            nextPage: typeof result.next === "string",
            hasSafariProductToken: /Safari\//.test(navigator.userAgent),
            visibility: document.visibilityState,
            documentState: document.readyState
          });
        })()
        """#
        startScenario()
        return true
    }

    private func startScenario() {
        sampling = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = scenario == 1 ? .desktop : .mobile
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 768), configuration: configuration)
        view.navigationDelegate = self
        web = view

        let startedScenario = scenario
        if scenario == 2 {
            view.evaluateJavaScript("navigator.userAgent") { [weak self, weak view] value, error in
                guard let self, let view, web === view else { return }
                guard error == nil, let agent = value as? String, agent.contains("AppleWebKit/") else {
                    finish(view, result: ["agentUnavailable": true])
                    return
                }
                view.customUserAgent = agent + " Safari/604.1 LiteTale"
                view.load(URLRequest(url: destination, timeoutInterval: 18))
            }
        } else {
            view.load(URLRequest(url: destination, timeoutInterval: 18))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 23) { [weak self, weak view] in
            guard let self, let view, web === view, scenario == startedScenario else { return }
            finish(view, result: ["timeout": true])
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if action.targetFrame?.isMainFrame == true && action.request.url != destination {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard web === webView, !sampling, webView.url == destination else { return }
        sampling = true
        sample(webView, samples: [])
    }

    private func sample(_ view: WKWebView, samples: [[String: Any]]) {
        guard web === view else { return }
        view.evaluateJavaScript(summaryScript) { [weak self, weak view] value, error in
            guard let self, let view, web === view else { return }
            guard error == nil, let value = value as? String,
                  let decoded = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] else {
                finish(view, result: ["probeError": true, "samples": samples])
                return
            }
            let observations = samples + [decoded]
            if observations.count >= 3 || decoded["accessDenied"] as? Bool == true {
                finish(view, result: ["samples": observations])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak view] in
                guard let self, let view else { return }
                sample(view, samples: observations)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(webView, result: ["loadError": (error as NSError).code])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(webView, result: ["loadError": (error as NSError).code])
    }

    private func finish(_ view: WKWebView, result: [String: Any]) {
        guard web === view else { return }
        let attached = view.window != nil
        web = nil
        view.stopLoading()
        view.removeFromSuperview()
        results.append(result.merging(["profile": profiles[scenario], "attachedToWindow": attached]) { current, _ in current })
        scenario += 1
        let explicitlyDenied = (result["samples"] as? [[String: Any]])?.last?["accessDenied"] as? Bool == true
        if scenario < profiles.count && !explicitlyDenied {
            startScenario()
        } else {
            complete(["scenarios": results])
        }
    }

    private func complete(_ output: [String: Any]) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("probe.json"), options: .atomic)
    }
}
