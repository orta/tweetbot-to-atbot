// AtbotifyGUI.swift — a tiny AppKit front-end over the `atbotify` engine. Bundles the
// precompiled `atbotify` CLI + the dylib in its Resources and shells out to them, so the
// whole thing is one self-contained .app a person double-clicks. No Xcode/Python/Node.
import AppKit

final class Controller: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let tweetbotField = NSTextField(string: "/Applications/Tweetbot.app")
    let handleField = NSTextField(string: "")
    let pwField = NSSecureTextField(string: "")
    let pdsField = NSTextField(string: "")
    let log = NSTextView()
    let button = NSButton(title: "Create atbot…", target: nil, action: nil)

    /// The app is built without a nib, so it has no menu bar unless we make one. Without it
    /// there is no Quit / ⌘Q, and ⌘V doesn't work in the text fields (key equivalents for
    /// paste live on the Edit menu) — which matters for pasting an app password.
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Make atbot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Make atbot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Make atbot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// One window, nothing to come back to: closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        window.title = "Make atbot"
        window.center()
        let v = NSView(frame: window.contentView!.bounds)

        func label(_ s: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.frame = NSRect(x: 20, y: y, width: 480, height: 18); return l
        }
        func field(_ f: NSTextField, _ y: CGFloat, placeholder: String) {
            f.frame = NSRect(x: 20, y: y, width: 480, height: 24); f.placeholderString = placeholder
        }

        let title = NSTextField(labelWithString: "Turn your Tweetbot into a Bluesky client")
        title.font = .boldSystemFont(ofSize: 15); title.frame = NSRect(x: 20, y: 420, width: 480, height: 22)
        let sub = NSTextField(wrappingLabelWithString: "Point this at your installed Tweetbot and sign in with a Bluesky app password (bsky.app → Settings → App Passwords; allow direct messages for DMs). Your copy is transformed in place; nothing is uploaded.")
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor; sub.frame = NSRect(x: 20, y: 370, width: 480, height: 46)

        v.addSubview(title); v.addSubview(sub)
        v.addSubview(label("Tweetbot app", 350)); field(tweetbotField, 326, placeholder: "/Applications/Tweetbot.app"); v.addSubview(tweetbotField)
        v.addSubview(label("Bluesky handle", 294)); field(handleField, 270, placeholder: "you.bsky.social"); v.addSubview(handleField)
        v.addSubview(label("App password", 238)); field(pwField, 214, placeholder: "xxxx-xxxx-xxxx-xxxx"); v.addSubview(pwField)
        v.addSubview(label("PDS (optional)", 182)); field(pdsField, 158, placeholder: "https://bsky.social (auto-detected if blank)"); v.addSubview(pdsField)

        button.frame = NSRect(x: 360, y: 118, width: 140, height: 32); button.bezelStyle = .rounded
        button.target = self; button.action = #selector(create); v.addSubview(button)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 480, height: 88))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.minSize = .zero; log.maxSize = NSSize(width: .max, height: .max); log.isVerticallyResizable = true
        log.textContainer?.containerSize = NSSize(width: 480, height: .max); log.textContainer?.widthTracksTextView = true
        scroll.documentView = log; v.addSubview(scroll)

        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func append(_ s: String) {
        DispatchQueue.main.async {
            self.log.textStorage?.append(NSAttributedString(string: s, attributes: [.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]))
            self.log.scrollToEndOfDocument(nil)
        }
    }

    @objc func create() {
        guard let res = Bundle.main.resourcePath else { return }
        let atbotify = res + "/atbotify"
        let dylib = res + "/libtweetbot-atproto.dylib"
        guard FileManager.default.fileExists(atPath: atbotify), FileManager.default.fileExists(atPath: dylib) else {
            append("✗ bundled atbotify/dylib missing\n"); return
        }
        let handle = handleField.stringValue.trimmingCharacters(in: .whitespaces)
        let pw = pwField.stringValue.trimmingCharacters(in: .whitespaces)
        if handle.isEmpty || pw.isEmpty { append("✗ enter your Bluesky handle and app password\n"); return }

        let save = NSSavePanel()
        save.nameFieldStringValue = "atbot.app"
        save.directoryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Applications"))
        save.begin { resp in
            guard resp == .OK, let out = save.url else { return }
            self.button.isEnabled = false
            self.append("Building \(out.path)…\n")
            var args = ["--tweetbot", self.tweetbotField.stringValue, "--out", out.path,
                        "--dylib", dylib, "--handle", handle, "--app-password", pw]
            let pds = self.pdsField.stringValue.trimmingCharacters(in: .whitespaces)
            if !pds.isEmpty { args += ["--pds", pds] }

            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: atbotify); p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { h in
                    if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty { self.append(s) }
                }
                do { try p.run(); p.waitUntilExit() } catch { self.append("✗ \(error)\n") }
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.button.isEnabled = true
                    if p.terminationStatus == 0 {
                        self.append("\n✓ Done. Launching atbot…\n")
                        NSWorkspace.shared.open(out)
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = Controller()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
