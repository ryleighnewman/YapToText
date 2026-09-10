// Windows owned by ONE pid, as JSON. The video rig runs a second copy of YapToText beside the
// user's own; matching on the process name would find theirs too, so every lookup is by pid.
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? -1
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var out: [String] = []
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int) == pid,
          let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let name = (w[kCGWindowName as String] as? String ?? "").replacingOccurrences(of: "\"", with: "")
    out.append("{\"id\":\(num),\"name\":\"\(name)\",\"layer\":\(layer),\"x\":\(Int(b["X"] as? Double ?? 0)),\"y\":\(Int(b["Y"] as? Double ?? 0)),\"w\":\(Int(b["Width"] as? Double ?? 0)),\"h\":\(Int(b["Height"] as? Double ?? 0))}")
}
print("[" + out.joined(separator: ",") + "]")
