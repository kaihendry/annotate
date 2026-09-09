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
