// Direct test of the agent tools, no GUI, no model. Run: swiftc tools.swift tools-check.swift -o /tmp/tc && /tmp/tc
import Foundation

func got(_ name: String, _ args: [String: Any]) -> String {
  let sem = DispatchSemaphore(value: 0); var out = ""
  Tools.run(name, args) { out = $0; sem.signal() }
  sem.wait(); return out
}

@main struct ToolsCheck {
  static func main() {
    // run_command: deterministic, offline.
    let rc = got("run_command", ["command": "echo hello && echo err 1>&2 && exit 3"])
    assert(rc.contains("exit code 3"), "exit code missing: \(rc)")
    assert(rc.contains("hello") && rc.contains("err"), "stdout/stderr missing: \(rc)")

    // stripHTML sanity.
    assert(Tools.stripHTML("<p>a <b>b</b></p><script>x()</script>").contains("a b"))
    assert(!Tools.stripHTML("<script>bad</script>ok").contains("bad"))

    // web_search: live; must not be empty. Reports whether the network was reachable.
    let ws = got("web_search", ["query": "example.com"])
    assert(!ws.isEmpty, "empty search")

    print("run_command: OK")
    print("web_search: " + (ws.contains("Search results") ? "OK (online)" : "no network -> " + String(ws.prefix(60))))
    print("ALL ASSERTS PASSED")
  }
}
