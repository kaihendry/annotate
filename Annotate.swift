// Annotate — draw boxes, arrows and text on a screenshot.
// Build: swiftc -O Annotate.swift -o annotate
// Usage: ./annotate             screenshot to clipboard (⌃⇧⌘4) — it loads
//                               automatically; annotate, ⌘Q → result is in clipboard
//        ./annotate [image.png] annotate an existing file
// Tools: B box · A arrow · T text (click, type, ⏎ to commit, ⎋ to cancel)
// Keys:  ⌘O open · ⌘V paste · ⌘Z undo · ⌘C copy result · ⌘S save PNG · ⌘Q quit
// On quit the annotated image is copied to the clipboard.
//
// Headless (for scripts/agents — coordinates in pixels, origin top-left):
//   ./annotate in.png --box x,y,w,h --arrow x1,y1,x2,y2 --text x,y,string --out out.png
//   (shape flags are repeatable)

import AppKit
import UniformTypeIdentifiers

enum Shape {
    case box(NSRect)
    case arrow(NSPoint, NSPoint)
    case text(String, NSPoint)
}

enum Tool: String {
    case box = "Box (B)", arrow = "Arrow (A)", text = "Text (T)"
}

final class Canvas: NSView, NSTextFieldDelegate {
    var image: NSImage? {
        didSet {
            shapes = []
            draft = nil
            setFrameSize(image?.size ?? NSSize(width: 480, height: 300))
            needsDisplay = true
        }
    }
    var tool = Tool.box { didSet { window?.subtitle = tool.rawValue } }
    var shapes: [Shape] = []
    private var draft: Shape?
    private var anchor = NSPoint.zero
    private var editor: NSTextField?

    private static let textFont =
        NSFont(name: "JetBrainsMono-Bold", size: 28)
        ?? .monospacedSystemFont(ofSize: 28, weight: .bold)
    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: textFont,
        .foregroundColor: NSColor.systemRed,
    ]
    private static let haloAttrs: [NSAttributedString.Key: Any] = [
        .font: textFont,
        .strokeColor: NSColor.white,
        .strokeWidth: 25, // outline-only stroke, % of font size
    ]
    private static let strokeWidth: CGFloat = 5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() { window?.subtitle = tool.rawValue }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": tool = .box
        case "a": tool = .arrow
        case "t": tool = .text
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            let hint = NSAttributedString(
                string: "Screenshot to clipboard (⌃⇧⌘4) to load it here · ⌘O open · ⌘V paste",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 14)])
            let size = hint.size()
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2))
            return
        }
        image.draw(in: bounds)
        render(shapes + (draft.map { [$0] } ?? []))
    }

    private func render(_ shapes: [Shape]) {
        for shape in shapes {
            switch shape {
            case .box(let rect):
                strokeWithHalo(NSBezierPath(rect: rect))
            case .arrow(let from, let to):
                let path = NSBezierPath()
                path.move(to: from)
                path.line(to: to)
                let angle = atan2(to.y - from.y, to.x - from.x)
                for wing in [angle + 2.6, angle - 2.6] {
                    path.move(to: to)
                    path.line(to: NSPoint(x: to.x + 22 * cos(wing),
                                          y: to.y + 22 * sin(wing)))
                }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                strokeWithHalo(path)
            case .text(let string, let at):
                let halo = NSAttributedString(string: string, attributes: Self.haloAttrs)
                let size = halo.size()
                // keep the whole string inside the image
                let p = NSPoint(x: max(0, min(at.x, bounds.width - size.width)),
                                y: max(0, min(at.y, bounds.height - size.height)))
                halo.draw(at: p)
                NSAttributedString(string: string, attributes: Self.textAttrs).draw(at: p)
            }
        }
    }

    private func strokeWithHalo(_ path: NSBezierPath) {
        NSColor.white.setStroke()
        path.lineWidth = Self.strokeWidth + 4
        path.stroke()
        NSColor.systemRed.setStroke()
        path.lineWidth = Self.strokeWidth
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        commitEditor()
        guard image != nil else { return }
        anchor = convert(event.locationInWindow, from: nil)
        if tool == .text { beginText(at: anchor) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard image != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .box:
            draft = .box(NSRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)))
        case .arrow:
            draft = .arrow(anchor, p)
        case .text:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch draft {
        case .box(let r) where r.width > 3 && r.height > 3:
            shapes.append(draft!)
        case .arrow(let a, let b) where hypot(b.x - a.x, b.y - a.y) > 5:
            shapes.append(draft!)
        default:
            break
        }
        draft = nil
        needsDisplay = true
    }

    func undo() {
        if editor != nil {
            cancelEditor()
        } else {
            _ = shapes.popLast()
        }
        needsDisplay = true
    }

    // MARK: text entry

    private func beginText(at p: NSPoint) {
        let field = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - 6,
                                              width: max(220, bounds.width - p.x), height: 40))
        field.font = Self.textFont
        field.textColor = .systemRed
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "text ⏎"
        field.delegate = self
        field.target = self
        field.action = #selector(editorCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
    }

    @objc private func editorCommitted() { commitEditor() }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditor()
            return true
        }
        return false
    }

    private func commitEditor() {
        guard let field = editor else { return }
        editor = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !string.isEmpty {
            shapes.append(.text(string, NSPoint(x: field.frame.minX + 2,
                                                y: field.frame.minY + 4)))
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelEditor() {
        editor?.stringValue = ""
        commitEditor()
    }

    /// Original image with annotations burned in, at full pixel resolution.
    func rendered() -> NSBitmapImageRep? {
        commitEditor()
        guard let image else { return nil }
        let pxW = image.representations.map(\.pixelsWide).max() ?? 0
        let pxH = image.representations.map(\.pixelsHigh).max() ?? 0
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW > 0 ? pxW : Int(image.size.width),
            pixelsHigh: pxH > 0 ? pxH : Int(image.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        // flip the export context so shapes use the same coordinates as the view
        NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: image.size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        render(shapes)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
    private var window: NSWindow!
    private var pbWatcher: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        window = NSWindow(contentRect: canvas.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Annotate"
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        window.contentView = scroll
        window.center()

        let args = CommandLine.arguments.dropFirst()
        if let path = args.first(where: { !$0.hasPrefix("-") }),
           let img = NSImage(contentsOfFile: path) {
            load(img, title: (path as NSString).lastPathComponent)
        } else if let img = Self.clipboardImage() {
            load(img, title: "Annotate (pasted)")
        } else {
            watchPasteboard()
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        if canvas.image != nil { copyImage() }
    }

    // Reading pasteboard *content* without user intent triggers the macOS
    // paste-consent alert (15.4+), so check the type list (metadata, no
    // alert) before touching the data.
    private static func clipboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        guard pb.availableType(from: [.png, .tiff, .pdf]) != nil else { return nil }
        return NSImage(pasteboard: pb)
    }

    // No screencapture here — MDM machines often block Screen Recording
    // permission. Wait for the user to screenshot with the system tool
    // (⌃⇧⌘4) and pick the image up from the clipboard.
    private func watchPasteboard() {
        let pb = NSPasteboard.general
        var seen = pb.changeCount
        pbWatcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard pb.changeCount != seen else { return }
            seen = pb.changeCount
            guard let img = Self.clipboardImage() else { return }
            self?.load(img, title: "Annotate (pasted)")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func load(_ image: NSImage, title: String) {
        pbWatcher?.invalidate()
        pbWatcher = nil
        canvas.image = image
        window.title = title
        if let screen = window.screen ?? NSScreen.main {
            let avail = screen.visibleFrame.insetBy(dx: 40, dy: 40)
            window.setContentSize(NSSize(width: min(image.size.width, avail.width),
                                         height: min(image.size.height, avail.height)))
            window.center()
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Annotate",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open…", #selector(openImage), "o"))
        fileMenu.addItem(item("Save As PNG…", #selector(saveImage), "s"))
        main.addItem(submenu(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", #selector(undoShape), "z"))
        editMenu.addItem(item("Copy Annotated Image", #selector(copyImage), "c"))
        editMenu.addItem(item("Paste Image", #selector(pasteImage), "v"))
        main.addItem(submenu(editMenu))

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            load(img, title: url.lastPathComponent)
        }
    }

    @objc private func saveImage() {
        guard let data = canvas.rendered()?.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "annotated.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    @objc private func undoShape() { canvas.undo() }

    @objc private func copyImage() {
        // write data eagerly so the clipboard survives the app quitting
        guard let rep = canvas.rendered(),
              let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
    }

    @objc private func pasteImage() {
        guard let img = NSImage(pasteboard: .general) else { return }
        load(img, title: "Annotate (pasted)")
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

// Render annotations onto a PNG without showing a window, then exit.
func runHeadless(_ args: [String]) -> Never {
    var input: String?
    var out: String?
    var specs: [(flag: String, value: String)] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--box", "--arrow", "--text", "--out":
            guard i + 1 < args.count else { fail("missing value for \(args[i])") }
            if args[i] == "--out" { out = args[i + 1] } else { specs.append((args[i], args[i + 1])) }
            i += 2
        default:
            input = args[i]
            i += 1
        }
    }
    guard let input, let out, let image = NSImage(contentsOfFile: input) else {
        fail("usage: annotate in.png [--box x,y,w,h] [--arrow x1,y1,x2,y2] [--text x,y,string]... --out out.png")
    }

    // CLI coordinates are image pixels (top-left origin); canvas works in points
    let pxW = image.representations.map(\.pixelsWide).max() ?? 0
    let scale = pxW > 0 ? image.size.width / CGFloat(pxW) : 1

    func nums(_ s: String, _ n: Int) -> [CGFloat] {
        let parts = s.split(separator: ",")
        guard parts.count == n else { fail("expected \(n) comma-separated numbers: \(s)") }
        return parts.map {
            guard let v = Double($0.trimmingCharacters(in: .whitespaces)) else { fail("bad number in: \(s)") }
            return CGFloat(v) * scale
        }
    }

    var shapes: [Shape] = []
    for spec in specs {
        switch spec.flag {
        case "--box":
            let v = nums(spec.value, 4)
            shapes.append(.box(NSRect(x: v[0], y: v[1], width: v[2], height: v[3])))
        case "--arrow":
            let v = nums(spec.value, 4)
            shapes.append(.arrow(NSPoint(x: v[0], y: v[1]), NSPoint(x: v[2], y: v[3])))
        default:
            let parts = spec.value.split(separator: ",", maxSplits: 2).map(String.init)
            guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]) else {
                fail("expected x,y,text: \(spec.value)")
            }
            shapes.append(.text(parts[2], NSPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale)))
        }
    }

    let canvas = Canvas(frame: .zero)
    canvas.image = image
    canvas.shapes = shapes
    guard let data = canvas.rendered()?.representation(using: .png, properties: [:]) else {
        fail("render failed")
    }
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail("write failed: \(error)") }
    exit(0)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains("--out") { runHeadless(cliArgs) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
