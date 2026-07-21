// Boots an AppKit window hosting the SwiftUI spike — no Xcode project needed.
// Run: swift run   (from prototypes/EditorSpike)
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Minimal menu so ⌘Q/⌘Z/⌘C/⌘V/⌘A work in the text view.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit EditorSpike",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All",
                 action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false)
window.center()
window.title = "Reflect — editor spike"
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = NSColor(srgbRed: 0xF8 / 255, green: 0xF6 / 255, blue: 0xF1 / 255, alpha: 1)
window.contentView = NSHostingView(rootView: ContentView())
window.makeKeyAndOrderFront(nil)
window.isReleasedWhenClosed = false

app.activate(ignoringOtherApps: true)
app.run()
