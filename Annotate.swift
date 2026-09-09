// Annotate — draw boxes, arrows and text on a screenshot.
// Build: swiftc -O Annotate.swift -o annotate
// Usage: ./annotate             screenshot to clipboard (⌃⇧⌘4) — it loads
//                               automatically; annotate, ⌘Q → result is in clipboard
//        ./annotate [image.png] annotate an existing file
// Tools: A move · B box · R arrow · T text (click, type, ⏎ to commit, ⎋ to cancel)
// Keys:  ⌘O open · ⌘V paste · ⌘Z undo · ⌘C copy result · ⌘S save PNG · ⌘Q quit
// On quit the annotated image is copied to the clipboard.
// Colour: defaults write com.hendry.annotate colour RRGGBB (default red),
//         or per run: -colour RRGGBB
//
// Headless (for scripts/agents — coordinates in pixels, origin top-left):
//   ./annotate in.png --box x,y,w,h --arrow x1,y1,x2,y2 --text x,y,string --out out.png
//   (shape flags are repeatable)

import AppKit
import UniformTypeIdentifiers

enum Shape: Equatable {
    case box(NSRect)
    case arrow(NSPoint, NSPoint)
    case text(String, NSPoint)

    func movedBy(dx: CGFloat, dy: CGFloat, in bounds: NSRect) -> Shape {
        func offset(_ point: NSPoint) -> NSPoint {
            NSPoint(x: point.x + dx, y: point.y + dy)
        }
        switch self {
        case .box(let rect):
            return .box(rect.offsetBy(dx: dx, dy: dy))
        case .arrow(let from, let to):
            return .arrow(offset(from), offset(to))
        case .text(let string, let at):
            let start = AnnotationRenderer.textRect(string, at: at, in: bounds).origin
            let end = AnnotationRenderer.textRect(string, at: offset(start), in: bounds).origin
            return start == end ? self : .text(string, end)
        }
    }
}

enum Tool: String, CaseIterable {
    case move = "Move (A)", box = "Box (B)", arrow = "Arrow (R)", text = "Text (T)"
}

// MARK: - Shared GUI / headless rendering

enum AnnotationRenderer {
    // Annotation colour: defaults write com.hendry.annotate colour RRGGBB
    // (or a one-off -colour RRGGBB argument, via NSArgumentDomain).
    static let accent: NSColor = {
        var hex = UserDefaults.standard.string(forKey: "colour")
            ?? CFPreferencesCopyAppValue("colour" as CFString,
                                         "com.hendry.annotate" as CFString) as? String
            ?? ""
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .systemRed }
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }()

    static let textFont =
        NSFont(name: "JetBrainsMono-Bold", size: 28)
        ?? .monospacedSystemFont(ofSize: 28, weight: .bold)
    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: textFont,
        .foregroundColor: accent,
    ]
    private static let haloAttrs: [NSAttributedString.Key: Any] = [
        .font: textFont,
        .strokeColor: NSColor.white,
        .strokeWidth: 25, // outline-only stroke, % of font size
    ]
    private static let strokeWidth: CGFloat = 5

    static func draw(_ shapes: [Shape], in bounds: NSRect) {
        // Draw geometry first, then labels. Keep the stored order for undo.
        for shape in shapes {
            switch shape {
            case .box(let rect):
                strokeWithHalo(NSBezierPath(rect: rect))
            case .arrow(let from, let to):
                let path = NSBezierPath()
                path.move(to: from)
                path.line(to: to)
                for wing in arrowWings(from: from, to: to) {
                    path.move(to: to)
                    path.line(to: wing)
                }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                strokeWithHalo(path)
            case .text:
                break
            }
        }
        for case .text(let string, let at) in shapes {
            let halo = NSAttributedString(string: string, attributes: Self.haloAttrs)
            let p = textRect(string, at: at, in: bounds).origin
            halo.draw(at: p)
            NSAttributedString(string: string, attributes: Self.textAttrs).draw(at: p)
        }
    }

    // Share visible geometry between drawing, picking, and moving labels.
    static func textRect(_ string: String, at: NSPoint, in bounds: NSRect) -> NSRect {
        let size = NSAttributedString(string: string, attributes: haloAttrs).size()
        let origin = NSPoint(x: max(0, min(at.x, bounds.width - size.width)),
                             y: max(0, min(at.y, bounds.height - size.height)))
        return NSRect(origin: origin, size: size)
    }

    private static func arrowWings(from: NSPoint, to: NSPoint) -> [NSPoint] {
        let angle = atan2(to.y - from.y, to.x - from.x)
        return [angle + 2.6, angle - 2.6].map {
            NSPoint(x: to.x + 22 * cos($0), y: to.y + 22 * sin($0))
        }
    }

    static func contains(_ shape: Shape, point: NSPoint, in bounds: NSRect,
                         tolerance: CGFloat) -> Bool {
        let tolerance = max(tolerance, (strokeWidth + 4) / 2)
        switch shape {
        case .box(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .arrow(let from, let to):
            return ([from] + arrowWings(from: from, to: to)).contains { end in
                let dx = end.x - to.x, dy = end.y - to.y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0
                    ? max(0, min(1, ((point.x - to.x) * dx + (point.y - to.y) * dy) / lengthSquared)) : 0
                return hypot(point.x - to.x - t * dx, point.y - to.y - t * dy) <= tolerance
            }
        case .text(let string, let at):
            return textRect(string, at: at, in: bounds)
                .insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func strokeWithHalo(_ path: NSBezierPath) {
        NSColor.white.setStroke()
        path.lineWidth = Self.strokeWidth + 4
        path.stroke()
        Self.accent.setStroke()
        path.lineWidth = Self.strokeWidth
        path.stroke()
    }

    /// Original image with annotations burned in, at full pixel resolution.
    static func bitmap(image: NSImage, shapes: [Shape]) -> NSBitmapImageRep? {
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
        draw(shapes, in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

// MARK: - Canvas interaction

final class Canvas: NSView, NSTextFieldDelegate {
    var image: NSImage? {
        didSet {
            cancelOperation(nil)
            removeEditor()
            shapes = []
            history = []
            setFrameSize(image?.size ?? NSSize(width: 480, height: 300))
            needsDisplay = true
        }
    }
    var tool = Tool.box {
        didSet {
            commitEditor()
            cancelOperation(nil)
            toolPicker.selectedSegment = Tool.allCases.firstIndex(of: tool)!
        }
    }
    lazy var toolPicker: NSSegmentedControl = {
        let picker = NSSegmentedControl(labels: Tool.allCases.map(\.rawValue),
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(selectTool(_:)))
        picker.selectedSegment = Tool.allCases.firstIndex(of: tool)!
        picker.setAccessibilityLabel("Annotation tool")
        picker.setToolTip("Drag text, an arrow, or a box edge. ⌘Z undoes; Esc cancels.", forSegment: 0)
        picker.setToolTip("Click to type. Return commits; Esc cancels.", forSegment: 3)
        return picker
    }()
    var shapes: [Shape] = []
    private var history: [[Shape]] = []
    private var moving: (index: Int, before: [Shape])?
    private var draft: Shape?
    private var anchor: NSPoint?
    private var editor: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    @objc private func selectTool(_ sender: NSSegmentedControl) {
        tool = Tool.allCases[sender.selectedSegment]
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .move
                      ? (moving == nil ? .openHand : .closedHand) : .arrow)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": tool = .box
        case "a": tool = .move
        case "r": tool = .arrow
        case "t": tool = .text
        case "\u{1b}": cancelOperation(nil)
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
        AnnotationRenderer.draw(shapes + (draft.map { [$0] } ?? []), in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        commitEditor()
        guard image != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        if tool == .text { beginText(at: point) }
        if tool == .move, let index = shape(at: point) {
            moving = (index, shapes)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard image != nil, let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .move:
            guard let moving else { return }
            shapes[moving.index] = moving.before[moving.index]
                .movedBy(dx: p.x - anchor.x, dy: p.y - anchor.y, in: bounds)
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
        defer {
            moving = nil
            anchor = nil
            draft = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if let moving {
            if shapes != moving.before { history.append(moving.before) }
            return
        }
        guard let draft else { return }
        switch draft {
        case .box(let r) where r.width > 3 && r.height > 3:
            append(draft)
        case .arrow(let a, let b) where hypot(b.x - a.x, b.y - a.y) > 5:
            append(draft)
        default:
            break
        }
    }

    private func shape(at point: NSPoint) -> Int? {
        let tolerance = 6 / (enclosingScrollView?.magnification ?? 1)
        let hits = shapes.indices.reversed().filter {
            AnnotationRenderer.contains(shapes[$0], point: point, in: bounds, tolerance: tolerance)
        }
        return hits.first { if case .text = shapes[$0] { return true }; return false } ?? hits.first
    }

    private func append(_ shape: Shape) {
        history.append(shapes)
        shapes.append(shape)
    }

    override func cancelOperation(_ sender: Any?) {
        if let moving { shapes = moving.before }
        moving = nil
        draft = nil
        anchor = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    @objc func undo(_ sender: Any?) {
        if let textView = editor?.currentEditor() as? NSTextView {
            // Undo can reach the canvas through the field editor's responder
            // chain. Keep it in the active text editing session in that case.
            textView.undoManager?.undo()
        } else if moving != nil || draft != nil {
            cancelOperation(sender)
        } else if let previous = history.popLast() {
            shapes = previous
        }
        needsDisplay = true
    }

    // MARK: text entry

    private func beginText(at p: NSPoint) {
        let field = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - 6,
                                              width: max(220, bounds.width - p.x), height: 40))
        field.font = AnnotationRenderer.textFont
        field.textColor = AnnotationRenderer.accent
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "text ⏎"
        field.delegate = self
        field.target = self
        field.action = #selector(commitEditor)
        addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.allowsUndo = true
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            removeEditor()
            return true
        }
        return false
    }

    @objc private func commitEditor() {
        guard let field = editor else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !string.isEmpty {
            append(.text(string, NSPoint(x: field.frame.minX + 2,
                                        y: field.frame.minY + 4)))
        }
        removeEditor()
    }

    private func removeEditor() {
        guard let field = editor else { return }
        editor = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Commit pending text before exporting the image.
    func rendered() -> NSBitmapImageRep? {
        commitEditor()
        guard let image else { return nil }
        return AnnotationRenderer.bitmap(image: image, shapes: shapes)
    }
}

// MARK: - Application and clipboard

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
    private let scroll = NSScrollView()
    private var window: NSWindow!
    private var pbWatcher: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        setAppIcon()
        buildMenu()
        window = NSWindow(contentRect: canvas.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Annotate"
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        window.contentView = scroll
        let picker = canvas.toolPicker
        picker.sizeToFit()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = NSView(frame: NSRect(x: 0, y: 0,
                                              width: picker.frame.width + 24, height: 38))
        picker.translatesAutoresizingMaskIntoConstraints = false
        accessory.view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: accessory.view.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: accessory.view.centerYAnchor),
        ])
        window.addTitlebarAccessoryViewController(accessory)
        window.contentMinSize = NSSize(width: picker.fittingSize.width + 24, height: 120)
        window.center()

        // first non-flag argument is the file to open; -colour takes a value
        let args = Array(CommandLine.arguments.dropFirst())
        if let path = args.indices.first(where: { i in
               !args[i].hasPrefix("-") && (i == 0 || args[i - 1] != "-colour")
           }).map({ args[$0] }),
           let img = NSImage(contentsOfFile: path) {
            load(img, title: (path as NSString).lastPathComponent)
        } else if !pasteFromClipboard() {
            watchPasteboard()
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setAppIcon() {
        let executable = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        // Support the app bundle, a source checkout, and the installed CLI.
        let candidates = [
            Bundle.main.url(forResource: "Annotate", withExtension: "icns"),
            directory.appendingPathComponent("Resources/Annotate.icns"),
            directory.deletingLastPathComponent()
                .appendingPathComponent("share/annotate/Annotate.icns"),
        ]
        for case let url? in candidates {
            if let icon = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = icon
                return
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        if canvas.image != nil { copyImage() }
    }

    // Reading pasteboard *content* without user intent triggers the macOS
    // paste-consent alert (15.4+), so check the type list (metadata, no
    // alert) before touching the data.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        guard pb.availableType(from: [.png, .tiff, .pdf]) != nil,
              let img = NSImage(pasteboard: pb) else { return false }
        load(img, title: "Annotate (pasted)")
        return true
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
            if self?.pasteFromClipboard() == true {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func load(_ image: NSImage, title: String) {
        pbWatcher?.invalidate()
        pbWatcher = nil
        // Size from pixels, not embedded DPI — clipboard metadata often
        // disagrees with the captured area on scaled displays.
        let pxW = image.representations.map(\.pixelsWide).max() ?? 0
        let pxH = image.representations.map(\.pixelsHigh).max() ?? 0
        if pxW > 0, pxH > 0 {
            let scale = window.backingScaleFactor
            image.size = NSSize(width: CGFloat(pxW) / scale, height: CGFloat(pxH) / scale)
        }
        canvas.image = image
        window.title = title
        if let screen = window.screen ?? NSScreen.main {
            let avail = screen.visibleFrame.insetBy(dx: 40, dy: 40)
            let chrome = window.frame.height - window.contentLayoutRect.height
            // shrink to fit the screen instead of showing scrollbars
            let fit = min(1, avail.width / image.size.width,
                          (avail.height - chrome) / image.size.height)
            window.setContentSize(NSSize(width: max(window.contentMinSize.width, image.size.width * fit),
                                         height: image.size.height * fit))
            scroll.magnification = fit
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
        fileMenu.addItem(withTitle: "Open…", action: #selector(openImage), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save As PNG…", action: #selector(saveImage), keyEquivalent: "s")
        main.addItem(submenu(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        // Nil targets let the active text editor handle standard editing commands.
        // When the canvas is focused, copy/paste fall back to the app delegate.
        editMenu.addItem(withTitle: "Undo", action: #selector(Canvas.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu))

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
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

    @objc private func copy(_ sender: Any?) { copyImage() }

    private func copyImage() {
        // write data eagerly so the clipboard survives the app quitting
        guard let rep = canvas.rendered(),
              let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
    }

    @objc private func paste(_ sender: Any?) { pasteFromClipboard() }
}

// MARK: - Command line

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
        case "-colour": // consumed by UserDefaults (NSArgumentDomain)
            i += 2
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

    guard let data = AnnotationRenderer.bitmap(image: image, shapes: shapes)?
        .representation(using: .png, properties: [:]) else {
        fail("render failed")
    }
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail("write failed: \(error)") }
    exit(0)
}

#if !ANNOTATE_TESTING
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains("--out") { runHeadless(cliArgs) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#endif
