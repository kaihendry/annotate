// Appended to Annotate.swift by run.sh so the app keeps its single-file build.
import AppKit

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func preservingClipboard(_ operation: () throws -> Void) rethrows {
    // Keep the snapshot in a parent process so even an AppKit exception in the
    // tests cannot prevent restoration. Never print the user's clipboard data.
    let pasteboard = NSPasteboard.general
    let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
        let saved = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { saved.setData(data, forType: type) }
        }
        return saved
    }
    defer {
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
    }
    try operation()
}

func testTextLayering() throws {
    let image = NSImage(size: NSSize(width: 240, height: 120), flipped: true) { rect in
        NSColor.white.setFill()
        rect.fill()
        return true
    }
    func png(_ shapes: [Shape]) throws -> Data {
        guard let data = AnnotationRenderer.bitmap(image: image, shapes: shapes)?
            .representation(using: .png, properties: [:]) else {
            throw TestFailure(description: "Could not render layering test")
        }
        return data
    }
    let text = Shape.text("TEXT", NSPoint(x: 40, y: 40))
    let box = Shape.box(NSRect(x: 40, y: 58, width: 140, height: 42))
    let arrow = Shape.arrow(NSPoint(x: 30, y: 60), NSPoint(x: 170, y: 60))
    for geometry in [[box], [arrow], [box, arrow]] {
        let expected = try png(geometry + [text])
        let textFirst = try png([text] + geometry)
        let withoutText = try png(geometry)
        try expect(textFirst == expected, "Later geometry covered existing text")
        try expect(expected != withoutText, "Text was missing from the rendered image")
    }
    print("PASS: text remains above overlapping boxes and arrows regardless of creation order")
}

func testEditing() throws {
    guard let window = NSApp.keyWindow,
          let canvas = (window.contentView as? NSScrollView)?.documentView as? Canvas,
          let menu = NSApp.mainMenu,
          let editMenu = menu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu,
          let originalImage = canvas.image else {
        throw TestFailure(description: "App did not launch with its canvas and image")
    }
    let pasteboard = NSPasteboard.general

    func clipboardText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func command(_ key: String, target: AnyObject? = nil) throws {
        guard let item = editMenu.items.first(where: { $0.keyEquivalent == key }),
              let action = item.action else {
            throw TestFailure(description: "Missing editing command: Command-\(key)")
        }
        let resolved = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject?
        if let target {
            try expect(resolved === target, "Command-\(key) bypassed the active responder")
        }
        editMenu.update()
        try expect(item.isEnabled, "Command-\(key) is disabled")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                    modifierFlags: .command, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: key, charactersIgnoringModifiers: key,
                                    isARepeat: false, keyCode: 0)!
        try expect(menu.performKeyEquivalent(with: event), "Command-\(key) was not handled")
    }

    func beginText() throws -> NSTextView {
        canvas.tool = .text
        let point = canvas.convert(NSPoint(x: 80, y: 80), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: event)
        guard let editor = window.firstResponder as? NSTextView else {
            throw TestFailure(description: "Text tool did not focus its field editor")
        }
        return editor
    }

    let label = "Pasted café 📋, with commas"
    let editor = try beginText()
    clipboardText(label)
    try command("v", target: editor)
    try expect(editor.string == label, "Clipboard text was not inserted")
    try expect(canvas.image === originalImage, "Text paste replaced the image")
    try expect(canvas.shapes.isEmpty, "Text paste committed prematurely")
    try command("z")
    try expect(window.firstResponder === editor && editor.string.isEmpty,
               "Text undo cancelled the editor instead of undoing the paste")
    try command("v", target: editor)

    try command("a", target: editor)
    try command("c", target: editor)
    try expect(pasteboard.string(forType: .string) == label, "Copy exported an image instead of text")
    try command("x", target: editor)
    try expect(editor.string.isEmpty, "Cut did not remove selected text")
    try command("v", target: editor)
    try command("a", target: editor)
    clipboardText("Replacement text")
    try command("v", target: editor)
    try expect(editor.string == "Replacement text", "Paste did not replace the selection")
    editor.insertNewline(nil)
    try expect(canvas.shapes.count == 1, "Return did not commit exactly one label")
    if case .text(let text, _) = canvas.shapes.first {
        try expect(text == "Replacement text", "Committed label lost pasted text")
    } else {
        throw TestFailure(description: "Committed annotation was not text")
    }
    try expect(window.firstResponder === canvas, "Return did not restore canvas focus")
    try command("z", target: canvas)
    try expect(canvas.shapes.isEmpty, "Canvas undo did not remove the label")

    let cancelled = try beginText()
    clipboardText("Discard this")
    try command("v", target: cancelled)
    cancelled.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    try expect(canvas.shapes.isEmpty, "Escape committed cancelled text")
    try expect(window.firstResponder === canvas, "Escape did not restore canvas focus")

    let pending = try beginText()
    clipboardText(label)
    try command("v", target: pending)
    let exported = canvas.rendered()
    try expect(exported != nil && canvas.shapes.count == 1, "Export lost pending pasted text")
    let pixels = originalImage.representations.map(\.pixelsWide).max()
    try expect(exported?.pixelsWide == pixels, "Export changed the image's pixel width")

    try command("c", target: NSApp.delegate!)
    try expect(pasteboard.availableType(from: [.png]) == .png, "Canvas copy did not export PNG")
    try command("v", target: NSApp.delegate!)
    try expect(canvas.image !== originalImage && canvas.shapes.isEmpty,
               "Canvas paste did not load the clipboard image")

    let stale = try beginText()
    clipboardText("Old image's label")
    try command("v", target: stale)
    canvas.image = originalImage
    try expect(canvas.subviews.isEmpty && canvas.shapes.isEmpty,
               "Replacing the image left a stale text editor")
    print("PASS: text paste, selection, cut/copy, text and canvas undo, commit/cancel, image clipboard, export")
}

func testMoving() throws {
    guard let window = NSApp.keyWindow,
          let scroll = window.contentView as? NSScrollView,
          let canvas = scroll.documentView as? Canvas else {
        throw TestFailure(description: "Missing canvas for move tests")
    }
    let image = NSImage(size: NSSize(width: 600, height: 400), flipped: true) { rect in
        NSColor.white.setFill()
        rect.fill()
        return true
    }
    canvas.image = image
    scroll.magnification = 1
    func key(_ value: String) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: value, charactersIgnoringModifiers: value,
                         isARepeat: false, keyCode: value == "\u{1b}" ? 53 : 0)!)
    }
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
        let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        default: canvas.mouseUp(with: event)
        }
    }
    func drag(_ from: NSPoint, _ to: NSPoint) {
        mouse(.leftMouseDown, from)
        mouse(.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
        mouse(.leftMouseDragged, to)
        mouse(.leftMouseUp, to)
    }

    let picker = canvas.toolPicker
    try expect(window.titlebarAccessoryViewControllers.contains {
        picker.isDescendant(of: $0.view)
    }, "Tool shortcuts are not attached to the window")
    for (index, value) in ["a", "b", "r", "t"].enumerated() {
        key(value)
        try expect(canvas.tool == Tool.allCases[index] && picker.selectedSegment == index,
                   "Shortcut \(value) did not select and highlight its tool")
        try expect(picker.label(forSegment: index) == Tool.allCases[index].rawValue,
                   "Tool strip lost its shortcut label")
    }
    mouse(.leftMouseDown, NSPoint(x: 80, y: 80))
    guard let editor = window.firstResponder as? NSTextView else {
        throw TestFailure(description: "Text tool did not open an editor")
    }
    for value in ["a", "r", "t"] { key(value) }
    try expect(editor.string == "art" && canvas.tool == .text,
               "Tool shortcuts intercepted typing")
    picker.selectedSegment = 0
    try expect(picker.sendAction(picker.action, to: picker.target), "Clicking the tool strip failed")
    try expect(canvas.tool == .move && window.firstResponder === canvas && canvas.shapes.count == 1,
               "Clicking Move did not commit text and restore canvas focus")

    canvas.image = image
    key("b")
    drag(NSPoint(x: 40, y: 40), NSPoint(x: 180, y: 140))
    let box = canvas.shapes
    let originalPNG = canvas.rendered()?.representation(using: .png, properties: [:])
    key("a")
    drag(NSPoint(x: 40, y: 80), NSPoint(x: 65, y: 95))
    try expect(canvas.shapes == [.box(NSRect(x: 65, y: 55, width: 140, height: 100))],
               "Dragging a box edge changed its size or moved it by the wrong amount")
    try expect(canvas.rendered()?.representation(using: .png, properties: [:]) != originalPNG,
               "Export ignored the move")
    // Neither a click nor a trip back to the starting point should consume undo.
    mouse(.leftMouseDown, NSPoint(x: 65, y: 95))
    mouse(.leftMouseUp, NSPoint(x: 65, y: 95))
    mouse(.leftMouseDown, NSPoint(x: 65, y: 95))
    mouse(.leftMouseDragged, NSPoint(x: 75, y: 95))
    mouse(.leftMouseDragged, NSPoint(x: 65, y: 95))
    mouse(.leftMouseUp, NSPoint(x: 65, y: 95))
    canvas.undo(nil)
    try expect(canvas.shapes == box, "One undo did not restore the entire drag")
    try expect(canvas.rendered()?.representation(using: .png, properties: [:]) == originalPNG,
               "Undo did not restore the exported pixels")
    drag(NSPoint(x: 100, y: 90), NSPoint(x: 110, y: 100))
    try expect(canvas.shapes == box, "Dragging an empty box interior moved the box")
    mouse(.leftMouseDown, NSPoint(x: 40, y: 80))
    mouse(.leftMouseDragged, NSPoint(x: 60, y: 80))
    key("\u{1b}")
    mouse(.leftMouseUp, NSPoint(x: 60, y: 80))
    try expect(canvas.shapes == box, "Escape did not cancel the move")
    canvas.undo(nil)
    try expect(canvas.shapes.isEmpty, "Cancelled or empty drags consumed an undo step")

    let text = Shape.text("TOP", NSPoint(x: 80, y: 80))
    let arrow = Shape.arrow(NSPoint(x: 40, y: 100), NSPoint(x: 200, y: 100))
    canvas.shapes = [text, arrow]
    drag(NSPoint(x: 90, y: 100), NSPoint(x: 110, y: 110))
    try expect(canvas.shapes == [.text("TOP", NSPoint(x: 100, y: 90)), arrow],
               "Move selected later geometry instead of the text drawn above it")
    canvas.undo(nil)
    for point in [NSPoint(x: 60, y: 100), NSPoint(x: 182, y: 111)] {
        drag(point, NSPoint(x: point.x + 20, y: point.y + 10))
        try expect(canvas.shapes == [text, .arrow(NSPoint(x: 60, y: 110), NSPoint(x: 220, y: 110))],
                   "Arrow shaft or arrowhead could not be moved without changing its shape")
        canvas.undo(nil)
    }
    canvas.shapes = [.box(NSRect(x: 40, y: 40, width: 160, height: 60)), arrow]
    drag(NSPoint(x: 60, y: 100), NSPoint(x: 80, y: 110))
    try expect(canvas.shapes[0] == .box(NSRect(x: 40, y: 40, width: 160, height: 60)),
               "Move did not select the topmost geometry")

    canvas.image = image
    let edgeText = Shape.text("EDGE", NSPoint(x: 599, y: 399))
    canvas.shapes = [edgeText]
    let visible = AnnotationRenderer.textRect("EDGE", at: NSPoint(x: 599, y: 399), in: canvas.bounds)
    let grab = NSPoint(x: visible.midX, y: visible.midY)
    drag(grab, NSPoint(x: grab.x - 30, y: grab.y - 20))
    try expect(canvas.shapes == [.text("EDGE", NSPoint(x: visible.minX - 30, y: visible.minY - 20))],
               "Moving an edge-clamped label jumped away from its displayed position")
    canvas.undo(nil)
    try expect(canvas.shapes == [edgeText], "Undo changed the original clamped label")

    canvas.image = image
    canvas.shapes = [.box(NSRect(x: 40, y: 40, width: 160, height: 100))]
    scroll.magnification = 0.25
    drag(NSPoint(x: 24, y: 80), NSPoint(x: 44, y: 100)) // Four screen points from edge.
    try expect(canvas.shapes == [.box(NSRect(x: 60, y: 60, width: 160, height: 100))],
               "Zooming out made the move hit target too small")
    mouse(.leftMouseDown, NSPoint(x: 60, y: 90))
    mouse(.leftMouseDragged, NSPoint(x: 80, y: 90))
    key("r")
    mouse(.leftMouseUp, NSPoint(x: 80, y: 90))
    try expect(canvas.shapes == [.box(NSRect(x: 60, y: 60, width: 160, height: 100))],
               "Switching tools did not cancel the active move")
    canvas.image = image
    canvas.undo(nil)
    try expect(canvas.shapes.isEmpty, "Replacing an image retained its move history")
    scroll.magnification = 1
    print("PASS: tool strip, shortcuts, text/arrow/box moves, picking order, zoom, cancellation, move undo and export")
}

if !CommandLine.arguments.contains("--run-editing-tests") {
    var status: Int32 = 1
    try preservingClipboard {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = Array(CommandLine.arguments.dropFirst()) + ["--run-editing-tests"]
        try child.run()
        child.waitUntilExit()
        status = child.terminationStatus
    }
    exit(status)
}

let testApp = NSApplication.shared
testApp.setActivationPolicy(.regular)
let testDelegate = AppDelegate()
testApp.delegate = testDelegate
func runTestsWhenReady(attempts: Int = 50) {
    // Window activation can complete after the launch notification.
    if testApp.keyWindow == nil && attempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            runTestsWhenReady(attempts: attempts - 1)
        }
        return
    }
    let status: Int32
    do {
        try testTextLayering()
        try testEditing()
        try testMoving()
        status = 0
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        status = 1
    }
    // Avoid the app's copy-on-quit hook after restoring the user's clipboard.
    testApp.delegate = nil
    exit(status)
}
DispatchQueue.main.async { runTestsWhenReady() }
testApp.run()
