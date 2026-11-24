// atbotify.swift — turns an installed Tweetbot into atbot, natively.
//
// Ports the whole pipeline (receipt/anti-tamper patch + LC_LOAD_DYLIB injection) to
// Swift and bundles the precompiled dylib, so an end user needs nothing but macOS —
// no Xcode, no Python, no LIEF, no Node. `ditto` and `codesign` ship with macOS.
//
// Build (by the project maintainer, into a universal binary):
//   swiftc -O -target arm64-apple-macos11 -o atbotify.arm64 builder/atbotify.swift
//   swiftc -O -target x86_64-apple-macos11 -o atbotify.x86  builder/atbotify.swift
//   lipo -create atbotify.arm64 atbotify.x86 -output atbotify
//
// Usage:
//   atbotify --tweetbot /Applications/Tweetbot.app --out ~/Applications/atbot.app \
//            --dylib ./libtweetbot-atproto.dylib \
//            --handle you.bsky.social --app-password xxxx-xxxx-xxxx-xxxx [--pds https://bsky.social]

import Foundation

// ---- CLI ---------------------------------------------------------------------
func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--\(name)"), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func die(_ msg: String) -> Never { FileHandle.standardError.write("✗ \(msg)\n".data(using: .utf8)!); exit(1) }
func step(_ msg: String) { print("→ \(msg)") }

let fm = FileManager.default
let tweetbot = arg("tweetbot") ?? "/Applications/Tweetbot.app"
guard let outPath = arg("out") else { die("--out <path to atbot.app> required") }
guard let dylibSrc = arg("dylib") else { die("--dylib <path to libtweetbot-atproto.dylib> required") }
let handle = arg("handle")
let appPassword = arg("app-password")
let pds = arg("pds")

let NEW_NAME = "atbot", NEW_ID = "io.orta.atbot", NEW_SCHEME = "atbot"
let INSTALL_PATH = "@executable_path/../Frameworks/libtweetbot-atproto.dylib"

guard fm.fileExists(atPath: tweetbot) else { die("Tweetbot not found at \(tweetbot)") }
guard fm.fileExists(atPath: dylibSrc) else { die("dylib not found at \(dylibSrc)") }

// ---- shell helpers -----------------------------------------------------------
@discardableResult
func run(_ launchPath: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: launchPath); p.arguments = args
    do { try p.run() } catch { die("failed to launch \(launchPath): \(error)") }
    p.waitUntilExit(); return p.terminationStatus
}

// ---- Mach-O: anti-tamper patch (port of patch-receipt.mjs, arm64 slice) -------
func arm64SliceOffset(_ data: Data) -> Int {
    func be32(_ o: Int) -> UInt32 { UInt32(data[o]) << 24 | UInt32(data[o+1]) << 16 | UInt32(data[o+2]) << 8 | UInt32(data[o+3]) }
    let top = be32(0)
    guard top == 0xcafebabe || top == 0xcafebabf else { return 0 } // thin
    let is64 = top == 0xcafebabf, n = Int(be32(4)); var p = 8, off = 0
    for _ in 0..<n {
        let cpu = be32(p)
        let o: Int = is64 ? Int((UInt64(be32(p+8)) << 32) | UInt64(be32(p+12))) : Int(be32(p+8))
        if cpu == 0x0100000c { off = o }
        p += is64 ? 32 : 20
    }
    return off
}
func le32(_ d: Data, _ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24 }
func put32(_ d: inout Data, _ o: Int, _ v: UInt32) { d[o] = UInt8(v & 0xff); d[o+1] = UInt8((v >> 8) & 0xff); d[o+2] = UInt8((v >> 16) & 0xff); d[o+3] = UInt8((v >> 24) & 0xff) }

func patchReceipt(_ url: URL) {
    var d = try! Data(contentsOf: url)
    let slice = arm64SliceOffset(d)
    let NOP: UInt32 = 0xd503201f, RET: UInt32 = 0xd65f03c0
    let STP: UInt32 = 0xa9bf7bfd, MOVFP: UInt32 = 0x910003fd, MOVW0: UInt32 = 0x52800000
    func isBL(_ w: UInt32) -> Bool { (w >> 26) == 0x25 }

    // (1) receipt gate: b.ne (B.cond NE) just before _NSApplicationMain -> NOP
    let gate = slice + Int(0x100001ed4 - 0x100000000)
    let cur = le32(d, gate)
    if cur != NOP {
        if (cur & 0xff00001f) == 0x54000001 { put32(&d, gate, NOP); step("patched receipt gate -> NOP") }
        else { die(String(format: "unexpected 0x%x at receipt gate", cur)) }
    }
    // (2) watchdog kill-stubs by signature -> RET
    var stubs = 0, f = slice
    while f < slice + 0x180000 - 16 {
        if le32(d, f) == STP && le32(d, f+4) == MOVFP && le32(d, f+8) == MOVW0 && isBL(le32(d, f+12)) {
            put32(&d, f, RET); stubs += 1
        }
        f += 4
    }
    step("neutralized \(stubs) watchdog stub(s)")
    try! d.write(to: url)
}

// ---- Mach-O: inject LC_LOAD_DYLIB in place (port of inject-framework.mjs) ------
func injectFramework(_ url: URL, installPath: String) {
    var d = try! Data(contentsOf: url)
    func be32(_ o: Int) -> UInt32 { UInt32(d[o]) << 24 | UInt32(d[o+1]) << 16 | UInt32(d[o+2]) << 8 | UInt32(d[o+3]) }

    var slices: [Int] = []
    let top = be32(0)
    if top == 0xcafebabe || top == 0xcafebabf {
        let is64 = top == 0xcafebabf, n = Int(be32(4)); var p = 8
        for _ in 0..<n {
            let cpu = be32(p)
            let o: Int = is64 ? Int((UInt64(be32(p+8)) << 32) | UInt64(be32(p+12))) : Int(be32(p+8))
            if cpu == 0x0100000c || cpu == 0x01000007 { slices.append(o) }
            p += is64 ? 32 : 20
        }
    } else { slices = [0] }

    // LC_LOAD_DYLIB command bytes
    let pathBytes = Array(installPath.utf8)
    let cmdsize = ((24 + pathBytes.count + 1) + 7) / 8 * 8
    var cmd = Data(count: cmdsize)
    func cput32(_ o: Int, _ v: UInt32) { cmd[o] = UInt8(v & 0xff); cmd[o+1] = UInt8((v>>8) & 0xff); cmd[o+2] = UInt8((v>>16) & 0xff); cmd[o+3] = UInt8((v>>24) & 0xff) }
    cput32(0, 0x0c); cput32(4, UInt32(cmdsize)); cput32(8, 24); cput32(12, 2); cput32(16, 0x010000); cput32(20, 0x010000)
    for (i, b) in pathBytes.enumerated() { cmd[24 + i] = b }

    var injected = 0
    for slice in slices {
        guard le32(d, slice) == 0xfeedfacf else { continue }
        let ncmds = Int(le32(d, slice+16)), sizeofcmds = Int(le32(d, slice+20))
        let endLC = slice + 32 + sizeofcmds

        // idempotency + first-section offset
        var already = false, firstSect = Int.max, p = slice + 32
        for _ in 0..<ncmds {
            let c = le32(d, p), sz = Int(le32(d, p+4))
            if c == 0x0c { let no = Int(le32(d, p+8)); var s = p + no, e = s; while d[e] != 0 { e += 1 }
                if String(bytes: d[s..<e], encoding: .utf8) == installPath { already = true }; _ = s }
            if c == 0x19 { let ns = Int(le32(d, p+64)); var s = p+72; for _ in 0..<ns { let fo = Int(le32(d, s+48)); if fo > 0 { firstSect = min(firstSect, slice+fo) }; s += 80 } }
            p += sz
        }
        if already { injected += 1; continue }
        let ceil = firstSect == Int.max ? d.count : firstSect
        if ceil - endLC < cmdsize { die("slice @\(slice): not enough header padding (\(ceil - endLC) < \(cmdsize))") }

        for i in 0..<cmdsize { d[endLC + i] = cmd[i] }
        put32(&d, slice+16, UInt32(ncmds + 1))
        put32(&d, slice+20, UInt32(sizeofcmds + cmdsize))
        injected += 1
    }
    if injected == 0 { die("no slices injected into \(url.lastPathComponent)") }
    try! d.write(to: url)
    step("injected load command into \(url.lastPathComponent) (\(injected) slice(s))")
}

// ---- Info.plist editing ------------------------------------------------------
func editInfoPlist(_ path: String) {
    guard var plist = NSMutableDictionary(contentsOfFile: path) as? [String: Any] else { die("can't read Info.plist") }
    plist["CFBundleExecutable"] = NEW_NAME
    plist["CFBundleName"] = NEW_NAME
    plist["CFBundleDisplayName"] = NEW_NAME
    plist["CFBundleIdentifier"] = NEW_ID
    plist["CFBundleURLTypes"] = [["CFBundleURLName": NEW_ID, "CFBundleURLSchemes": [NEW_SCHEME]]]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: path))
}

// ---- pipeline ----------------------------------------------------------------
let out = (outPath as NSString).expandingTildeInPath
let C = "\(out)/Contents"

step("copy \(tweetbot) -> \(out)")
try? fm.removeItem(atPath: out)
try? fm.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
if run("/usr/bin/ditto", [tweetbot, out]) != 0 { die("ditto failed") }

step("re-identify as '\(NEW_NAME)' (\(NEW_ID)) + '\(NEW_SCHEME)://' scheme")
try! fm.moveItem(atPath: "\(C)/MacOS/Tweetbot", toPath: "\(C)/MacOS/\(NEW_NAME)")
editInfoPlist("\(C)/Info.plist")

step("neutralize MAS receipt check + watchdog timers")
patchReceipt(URL(fileURLWithPath: "\(C)/MacOS/\(NEW_NAME)"))

step("install dylib + inject load command into PTHCommon")
try! fm.copyItem(atPath: dylibSrc, toPath: "\(C)/Frameworks/libtweetbot-atproto.dylib")
var pth = "\(C)/Frameworks/PTHCommon.framework/Versions/A/PTHCommon"
if !fm.fileExists(atPath: pth) { pth = "\(C)/Frameworks/PTHCommon.framework/PTHCommon" }
injectFramework(URL(fileURLWithPath: pth), installPath: INSTALL_PATH)

if let h = handle, let pw = appPassword {
    step("bake in Bluesky credentials")
    var creds: [String: String] = ["handle": h, "appPassword": pw]
    if let p = pds { creds["pds"] = p }
    let data = try! JSONSerialization.data(withJSONObject: creds, options: .prettyPrinted)
    try! data.write(to: URL(fileURLWithPath: "\(C)/Resources/atproto.json"))
}

step("re-sign ad-hoc (trimmed entitlements, inside-out)")
// trimmed entitlements inline (drops team-scoped keys that break ad-hoc launch)
let ent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.downloads.read-write</key><true/>
</dict></plist>
"""
let entPath = NSTemporaryDirectory() + "atbot.entitlements"
try! ent.write(toFile: entPath, atomically: true, encoding: .utf8)
func sign(_ p: String, entitlements: Bool) {
    var a = ["--force", "-s", "-"]
    if entitlements { a += ["--entitlements", entPath] }
    a.append(p)
    _ = run("/usr/bin/codesign", a)
}
sign("\(C)/Frameworks/libtweetbot-atproto.dylib", entitlements: false)
sign("\(C)/Frameworks/Model.framework", entitlements: false)
sign("\(C)/Frameworks/PTHCommon.framework", entitlements: false)
if let items = try? fm.contentsOfDirectory(atPath: "\(C)/PlugIns") {
    for it in items where it.hasSuffix(".appex") { sign("\(C)/PlugIns/\(it)", entitlements: true) }
}
sign("\(C)/MacOS/\(NEW_NAME)", entitlements: true)
sign(out, entitlements: true)

print("\n✓ atbot created at \(out)")
if handle == nil { print("  (no credentials baked in — add them in Resources/atproto.json or via Add Account)") }
print("  open it with:  open \(out)")
