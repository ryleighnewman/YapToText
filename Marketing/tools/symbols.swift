import AppKit
let names = ["accessibility", "voiceover", "waveform.and.mic", "keyboard.fill", "ear.fill", "textformat.size"]
let out = CommandLine.arguments[1]
for n in names {
    guard let sym = NSImage(systemSymbolName: n, accessibilityDescription: nil) else { print("miss \(n)"); continue }
    let cfg = NSImage.SymbolConfiguration(pointSize: 200, weight: .medium)
    guard let img = sym.withSymbolConfiguration(cfg) else { continue }
    let size = NSSize(width: 320, height: 320)
    let canvas = NSImage(size: size)
    canvas.lockFocus()
    let ar = img.size.width / img.size.height
    let w: CGFloat = ar > 1 ? 280 : 280 * ar
    let h = w / ar
    let rect = NSRect(x: (320 - w)/2, y: (320 - h)/2, width: w, height: h)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor(calibratedRed: 0.557, green: 0.557, blue: 0.576, alpha: 1).set()
    rect.fill(using: .sourceAtop)
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(out)/sym-\(n.replacingOccurrences(of: ".", with: "-")).png"))
    print("ok \(n)")
}
