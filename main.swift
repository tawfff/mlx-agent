// mlx-agent: a native Mac window around a chat page that talks to LM Studio.
// The page is served from the app bundle on the localai:// scheme, and /v1/* and
// /api/* are proxied to LM Studio, so LM Studio never needs CORS turned on.
import Cocoa
import WebKit

let lmStudio = URL(string: "http://127.0.0.1:1234")!
let lmsBin = NSHomeDirectory() + "/.lmstudio/bin/lms"
let dataDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/mlx-agent")
let dataFile = dataDir.appendingPathComponent("data.json")

final class Handler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
  struct Pending { let page: WKURLSchemeTask; let req: URLRequest; let retried: Bool; var responded = false }
  lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
  var pending: [Int: Pending] = [:]
  var alive = Set<ObjectIdentifier>()

  func webView(_ w: WKWebView, start t: WKURLSchemeTask) {
    alive.insert(ObjectIdentifier(t))
    let url = t.request.url!
    if url.path.hasPrefix("/v1/") || url.path.hasPrefix("/api/") {
      var r = URLRequest(url: URL(string: url.path + (url.query.map { "?" + $0 } ?? ""), relativeTo: lmStudio)!)
      r.httpMethod = t.request.httpMethod
      r.httpBody = body(t.request)
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.timeoutInterval = 900 // first token can wait on a 30 GB model loading into memory
      send(t, r, retried: false)
    } else if url.path == "/data" {
      if t.request.httpMethod == "PUT" {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let ok = (try? body(t.request)?.write(to: dataFile, options: .atomic)) != nil
        reply(t, Data(), "application/json", ok ? 204 : 500)
      } else {
        reply(t, (try? Data(contentsOf: dataFile)) ?? Data("{}".utf8), "application/json")
      }
    } else if url.path == "/tool" {
      // The page's agent loop posts {name, args}; we run the tool off-main and reply with {result}.
      let obj = (try? JSONSerialization.jsonObject(with: body(t.request) ?? Data())) as? [String: Any] ?? [:]
      Tools.run(obj["name"] as? String ?? "", obj["args"] as? [String: Any] ?? [:]) { result in
        DispatchQueue.main.async {
          let out = (try? JSONSerialization.data(withJSONObject: ["result": result])) ?? Data(#"{"result":""}"#.utf8)
          self.reply(t, out, "application/json")
        }
      }
    } else {
      let root = Bundle.main.resourceURL!.standardizedFileURL
      let file = root.appendingPathComponent(url.path == "/" ? "index.html" : String(url.path.dropFirst())).standardizedFileURL
      guard file.path.hasPrefix(root.path + "/"), let d = try? Data(contentsOf: file) else { return reply(t, Data(), "text/plain", 404) }
      let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "svg": "image/svg+xml", "png": "image/png"]
      reply(t, d, types[file.pathExtension] ?? "application/octet-stream")
    }
  }

  func webView(_ w: WKWebView, stop t: WKURLSchemeTask) {
    alive.remove(ObjectIdentifier(t))
    for (id, p) in pending where p.page === t {
      pending[id] = nil
      session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == id }?.cancel() }
    }
  }

  func body(_ r: URLRequest) -> Data? {
    if let b = r.httpBody { return b }
    guard let s = r.httpBodyStream else { return nil }
    s.open(); defer { s.close() }
    var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
    while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
    return out
  }

  func reply(_ t: WKURLSchemeTask, _ d: Data, _ type: String, _ status: Int = 200) {
    guard alive.remove(ObjectIdentifier(t)) != nil else { return }
    t.didReceive(HTTPURLResponse(url: t.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
    t.didReceive(d)
    t.didFinish()
  }

  func send(_ t: WKURLSchemeTask, _ r: URLRequest, retried: Bool) {
    guard alive.contains(ObjectIdentifier(t)) else { return }
    let task = session.dataTask(with: r)
    pending[task.taskIdentifier] = Pending(page: t, req: r, retried: retried)
    task.resume()
  }

  // LM Studio's server does not survive a restart. If it is down, start it and retry once.
  func startServer(then done: @escaping () -> Void) {
    DispatchQueue.global().async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: lmsBin)
      p.arguments = ["server", "start"]
      try? p.run(); p.waitUntilExit()
      DispatchQueue.main.async(execute: done)
    }
  }

  func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard var p = pending[dataTask.taskIdentifier], let h = response as? HTTPURLResponse else { return completionHandler(.cancel) }
    p.page.didReceive(HTTPURLResponse(url: p.page.request.url!, statusCode: h.statusCode, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": h.value(forHTTPHeaderField: "Content-Type") ?? "application/json"])!)
    p.responded = true
    pending[dataTask.taskIdentifier] = p
    completionHandler(.allow)
  }

  func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    pending[dataTask.taskIdentifier]?.page.didReceive(data)
  }

  func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let p = pending.removeValue(forKey: task.taskIdentifier) else { return }
    if let e = error as? URLError, !p.responded, !p.retried, [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(e.code) {
      return startServer { self.send(p.page, p.req, retried: true) }
    }
    guard alive.remove(ObjectIdentifier(p.page)) != nil else { return }
    if let e = error { p.page.didFailWithError(e) } else { p.page.didFinish() }
  }
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
  let handler = Handler()
  var win: NSWindow!

  func applicationDidFinishLaunching(_ n: Notification) {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(handler, forURLScheme: "localai")
    let web = WKWebView(frame: .zero, configuration: cfg)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.setValue(false, forKey: "drawsBackground")

    win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    win.title = "mlx-agent"
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.appearance = NSAppearance(named: .darkAqua)   // a dark phosphor terminal, always
    // Matches --bg in index.html so the title strip blends into the page.
    win.backgroundColor = NSColor(srgbRed: 0.016, green: 0.027, blue: 0.039, alpha: 1)
    win.minSize = NSSize(width: 640, height: 480)
    win.contentView = web
    win.setFrameAutosaveName("main")
    if !win.setFrameUsingName("main") { win.center() }
    web.load(URLRequest(url: URL(string: "localai://app/")!))
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

  // Links in answers open in the default browser, never inside the app.
  func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let u = a.request.url, u.scheme != "localai" else { return decisionHandler(.allow) }
    if ["http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
    decisionHandler(.cancel)
  }

  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
    if let u = a.request.url, ["http", "https"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
    return nil
  }
}

func menu(_ title: String, _ items: [(String, String, String)]) -> NSMenuItem {
  let m = NSMenu(title: title)
  for (t, sel, key) in items {
    if t == "-" { m.addItem(.separator()); continue }
    m.addItem(withTitle: t, action: Selector(sel), keyEquivalent: key)
  }
  let item = NSMenuItem()
  item.submenu = m
  return item
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
let bar = NSMenu()
bar.addItem(menu("mlx-agent", [("Hide mlx-agent", "hide:", "h"), ("-", "", ""), ("Quit mlx-agent", "terminate:", "q")]))
bar.addItem(menu("Edit", [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("-", "", ""), ("Cut", "cut:", "x"),
                          ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]))
bar.addItem(menu("View", [("Reload", "reload:", "r")]))
bar.addItem(menu("Window", [("Minimize", "performMiniaturize:", "m"), ("Close", "performClose:", "w")]))
app.mainMenu = bar
app.run()
