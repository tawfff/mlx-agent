import Foundation

// The agent's hands. Every tool runs here, natively, so the page stays sandboxed and
// cross-origin fetches (search, page reads) work without any CORS juggling.
// ponytail: run_command has no per-command sandbox; it runs as the user. The page gates
// it behind an explicit Approve click, which is the only thing standing between the model
// and your shell. Upgrade path: an allowlist or a real sandbox profile.
enum Tools {
  static let q = DispatchQueue(label: "localai.tools", attributes: .concurrent)
  static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"

  static func run(_ name: String, _ args: [String: Any], done: @escaping (String) -> Void) {
    q.async {
      switch name {
      case "web_search": done(webSearch(args["query"] as? String ?? ""))
      case "fetch_url":   done(fetchURL(args["url"] as? String ?? ""))
      case "run_command": done(runCommand(args["command"] as? String ?? ""))
      default: done("Unknown tool: \(name)")
      }
    }
  }

  static func httpGet(_ s: String) -> (Int, Data)? {
    guard let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { return nil }
    var r = URLRequest(url: u); r.timeoutInterval = 45
    r.setValue(ua, forHTTPHeaderField: "User-Agent")
    r.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
    let sem = DispatchSemaphore(value: 0); var out: (Int, Data)?
    URLSession.shared.dataTask(with: r) { d, resp, _ in
      if let d = d { out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d) }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 50)
    return out
  }

  static func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
      (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
  }

  static func stripHTML(_ html: String) -> String {
    var s = html
    for p in ["<script[^>]*>.*?</script>", "<style[^>]*>.*?</style>", "<!--.*?-->", "<[^>]+>"] {
      s = matches(p, s).reduce(s) { $0.replacingOccurrences(of: $1[0], with: " ") }
    }
    let ents = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " "]
    for (e, c) in ents { s = s.replacingOccurrences(of: e, with: c) }
    s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func webSearch(_ query: String) -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return "No query given." }
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    guard let (_, data) = httpGet("https://html.duckduckgo.com/html/?q=\(enc)"), let html = String(data: data, encoding: .utf8) else {
      return "Search failed (could not reach DuckDuckGo)."
    }
    let links = matches("class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", html)
    let snips = matches("class=\"result__snippet\"[^>]*>(.*?)</a>", html)
    if links.isEmpty { return "No results found for: \(q)" }
    var lines: [String] = []
    for (i, m) in links.prefix(5).enumerated() {
      var href = m[1]
      if let r = matches("uddg=([^&]+)", href).first, let dec = r[1].removingPercentEncoding { href = dec }
      if href.hasPrefix("//") { href = "https:" + href }
      let title = stripHTML(m[2])
      let snip = i < snips.count ? stripHTML(snips[i][1]) : ""
      lines.append("\(i + 1). \(title)\n   \(href)\n   \(snip)")
    }
    return "Search results for \"\(q)\":\n\n" + lines.joined(separator: "\n\n")
  }

  static func fetchURL(_ urlString: String) -> String {
    var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "No URL given." }
    if !s.contains("://") { s = "https://" + s }
    // Reddit's logged-out www pages are JS-walled; old.reddit serves plain readable HTML.
    // The .json API is left on www (old.reddit ignores it) so the model can still read raw JSON.
    if s.lowercased().contains("reddit.com"), !s.lowercased().contains(".json") {
      s = s.replacingOccurrences(of: "://www.reddit.com", with: "://old.reddit.com")
           .replacingOccurrences(of: "://reddit.com", with: "://old.reddit.com")
    }
    guard let (status, data) = httpGet(s) else { return "Could not fetch \(s)." }
    guard let raw = String(data: data, encoding: .utf8) else { return "Fetched \(s) (status \(status)) but it was not text." }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? raw : stripHTML(raw)
    let clipped = body.count > 4000 ? String(body.prefix(4000)) + "\n...[truncated]" : body
    return "Fetched \(s) (status \(status)):\n\n\(clipped)"
  }

  static func runCommand(_ cmd: String) -> String {
    let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
    if c.isEmpty { return "No command given." }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", c]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    // Drain concurrently so large output can't fill the pipe and deadlock before exit.
    var collected = Data(); let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData; if d.isEmpty { return }
      lock.lock(); collected.append(d); lock.unlock()
    }
    do { try p.run() } catch { return "Failed to start: \(error.localizedDescription)" }
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { p.waitUntilExit(); sem.signal() }
    if sem.wait(timeout: .now() + 300) == .timedOut { p.terminate(); return "Command timed out after 300s (5 min)." }
    pipe.fileHandleForReading.readabilityHandler = nil
    if let rest = try? pipe.fileHandleForReading.readToEnd() { lock.lock(); collected.append(rest); lock.unlock() }
    lock.lock(); let data = collected; lock.unlock()
    var out = String(data: data, encoding: .utf8) ?? ""
    if out.count > 4000 { out = String(out.prefix(4000)) + "\n...[truncated]" }
    return "exit code \(p.terminationStatus)\n\(out.isEmpty ? "(no output)" : out)"
  }
}
