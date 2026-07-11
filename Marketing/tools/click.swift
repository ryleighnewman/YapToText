import CoreGraphics
import Foundation
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let pt = CGPoint(x: x, y: y)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)!
    e.post(tap: .cghidEventTap)
    usleep(60000)
}
