import SwiftUI
import AppKit

extension View {
    /// Drag the window by this view. See WindowDragArea. Pass false where the view is only a
    /// preview inside another window, which must not move.
    func windowDragArea(_ enabled: Bool = true) -> some View { modifier(WindowDragArea(enabled: enabled)) }
}

/// Moves the window when the user drags this view.
///
/// macOS 27 stopped starting background drags for borderless windows whose content is SwiftUI:
/// isMovableByWindowBackground does nothing over an NSHostingView there, and overriding
/// mouseDownCanMoveWindow does not bring it back. So on 27 the drag is driven from SwiftUI, in
/// screen coordinates (NSEvent.mouseLocation), because the gesture's own translation collapses to
/// zero once the window follows the cursor. Controls inside keep their clicks: SwiftUI gives a
/// press to the innermost gesture first, and a drag only begins once the pointer has moved.
/// Earlier systems keep AppKit's own window drag untouched.
struct WindowDragArea: ViewModifier {
    var enabled = true
    @State private var window: NSWindow?
    @State private var grab: Grab?

    private struct Grab {
        var mouse: NSPoint
        var origin: NSPoint
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, #available(macOS 27, *) {
            content
                .background(WindowReader(window: $window))
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { value in
                            guard let window else { return }
                            let mouse = NSEvent.mouseLocation
                            // The gesture starts a few points in; count those too, so the spot
                            // that was grabbed stays exactly under the pointer.
                            let start = grab ?? Grab(mouse: NSPoint(x: mouse.x - value.translation.width,
                                                                    y: mouse.y + value.translation.height),
                                                     origin: window.frame.origin)
                            grab = start
                            window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                                          y: start.origin.y + mouse.y - start.mouse.y))
                        }
                        .onEnded { _ in grab = nil }
                )
        } else {
            content
        }
    }
}

/// Hands the hosting window to SwiftUI. Never takes a click itself.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let found = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(found) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
