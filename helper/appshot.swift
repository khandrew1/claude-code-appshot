// appshot-helper: the macOS side of the Appshot mod.
//
//   listen   --shortcut option+option [--skip id,id] [--silent]
//            Holds a machine-wide lock (one listener for every Claude session),
//            watches for the shortcut from any app, and captures the window in
//            front: a PNG screenshot plus its Accessibility text. Each capture
//            lands in <root>/inbox as <id>.png, <id>.txt and, last, <id>.json.
//   capture  [--delay seconds] [--app bundle.id]   one capture, no shortcut
//   permissions [--prompt]                          print what is granted
//   activate --pid N   bring the GUI app that started process N to the front
//
// Every line on stdout is one JSON object with an "event" field.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
    let line = String(data: data, encoding: .utf8)
  else { return }
  print(line)
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func opt(_ name: String) -> String? {
  guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
  return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains("--\(name)") }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let root = opt("root") ?? "\(home)/.claude/appshot"
let inbox = "\(root)/inbox"
let silent = flag("silent")
let skipBundles = Set(
  (opt("skip") ?? "com.anthropic.claudefordesktop").split(separator: ",").map {
    String($0).trimmingCharacters(in: .whitespaces)
  })

try? FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)

// MARK: - Permissions

func permissions(prompt: Bool) -> [String: Bool] {
  let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
  let accessibility = AXIsProcessTrustedWithOptions(axOptions)
  var screen = CGPreflightScreenCaptureAccess()
  if !screen && prompt { screen = CGRequestScreenCaptureAccess() }
  var input = CGPreflightListenEventAccess()
  if !input && prompt { input = CGRequestListenEventAccess() }
  return ["accessibility": accessibility, "screenRecording": screen, "inputMonitoring": input]
}

// MARK: - Shortcut

enum Shortcut {
  // Both keys of one modifier held together (left + right), as Codex's ⌘ + ⌘.
  case pair(left: UInt64, right: UInt64)
  // An ordinary chord: modifiers plus one key.
  case chord(mods: CGEventFlags, key: CGKeyCode)
}

let pairMasks: [String: (UInt64, UInt64)] = [
  "option": (0x20, 0x40), "opt": (0x20, 0x40), "alt": (0x20, 0x40),
  "command": (0x08, 0x10), "cmd": (0x08, 0x10),
  "control": (0x01, 0x2000), "ctrl": (0x01, 0x2000),
  "shift": (0x02, 0x04),
]
let modFlags: [String: CGEventFlags] = [
  "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
  "command": .maskCommand, "cmd": .maskCommand,
  "control": .maskControl, "ctrl": .maskControl,
  "shift": .maskShift,
]
let keyCodes: [String: CGKeyCode] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
  "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
  "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
  "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
  ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
  "`": 50, "escape": 53, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
  "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

func parseShortcut(_ text: String) -> Shortcut? {
  let parts = text.lowercased().split(separator: "+").map {
    String($0).trimmingCharacters(in: .whitespaces)
  }
  if parts.count == 2, parts[0] == parts[1], let masks = pairMasks[parts[0]] {
    return .pair(left: masks.0, right: masks.1)
  }
  guard parts.count >= 2, let key = keyCodes[parts.last!] else { return nil }
  var mods: CGEventFlags = []
  for part in parts.dropLast() {
    guard let f = modFlags[part] else { return nil }
    mods.insert(f)
  }
  return mods.isEmpty ? nil : .chord(mods: mods, key: key)
}

// MARK: - Finding the window in front

struct Target {
  let pid: pid_t
  let windowID: CGWindowID
  let app: String
  let bundleID: String?
  let title: String?
}

func onScreenWindows() -> [[String: Any]] {
  (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]) ?? []
}

func isUsable(_ w: [String: Any]) -> Bool {
  guard (w[kCGWindowLayer as String] as? Int) == 0 else { return false }
  if let alpha = w[kCGWindowAlpha as String] as? Double, alpha == 0 { return false }
  guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
  return (b["Width"] ?? 0) >= 60 && (b["Height"] ?? 0) >= 60
}

func focusedPid() -> pid_t? {
  if AXIsProcessTrusted() {
    let system = AXUIElementCreateSystemWide()
    var app: AnyObject?
    if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
      let app
    {
      var pid: pid_t = 0
      if AXUIElementGetPid(app as! AXUIElement, &pid) == .success { return pid }
    }
  }
  return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func frontTarget(bundle: String?) -> Target? {
  var pid: pid_t?
  if let bundle {
    pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
    if pid == nil { return nil }
  } else {
    pid = focusedPid()
  }
  // CGWindowList is ordered front to back.
  let windows = onScreenWindows().filter(isUsable)
  let window =
    windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    ?? (bundle == nil ? windows.first : nil)
  guard let window, let owner = window[kCGWindowOwnerPID as String] as? Int32,
    let number = window[kCGWindowNumber as String] as? Int
  else { return nil }
  let running = NSRunningApplication(processIdentifier: owner)
  let app = running?.localizedName ?? (window[kCGWindowOwnerName as String] as? String) ?? "App"
  let title = (window[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
  return Target(
    pid: owner, windowID: CGWindowID(number), app: app, bundleID: running?.bundleIdentifier,
    title: title)
}

// MARK: - Accessibility text

let textRoles: Set<String> = [
  "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
]
let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXScrollBar"]

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func focusedWindow(_ app: AXUIElement, title: String?) -> AXUIElement? {
  if let w = attr(app, kAXFocusedWindowAttribute) { return (w as! AXUIElement) }
  if let w = attr(app, kAXMainWindowAttribute) { return (w as! AXUIElement) }
  if let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
    return list.first { (attr($0, kAXTitleAttribute) as? String) == title } ?? list.first
  }
  return nil
}

struct WindowText {
  var lines: [String] = []
  var chars = 0
  var url: String?
  var truncated = false
}

func walk(_ window: AXUIElement, maxChars: Int, deadline: Date) -> WindowText {
  var out = WindowText()
  var stack: [AXUIElement] = [window]
  var visited = 0
  let names = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray
  while let el = stack.popLast() {
    visited += 1
    if visited > 20000 || Date() > deadline || out.chars >= maxChars {
      out.truncated = true
      break
    }
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, names, [], &values) == .success,
      let v = values as? [AnyObject], v.count == 4
    else { continue }
    let role = v[0] as? String ?? ""
    if skipRoles.contains(role) { continue }
    if role == "AXWebArea", out.url == nil, let url = attr(el, "AXURL") {
      out.url = (url as? URL)?.absoluteString ?? (url as? String)
    }
    if textRoles.contains(role) {
      var text = (v[1] as? String) ?? ""
      if text.isEmpty { text = (v[2] as? String) ?? "" }
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty, text != out.lines.last {
        let room = maxChars - out.chars
        if text.count > room {
          text = String(text.prefix(room))
          out.truncated = true
        }
        out.lines.append(text)
        out.chars += text.count + 1
      }
    }
    if let children = v[3] as? [AXUIElement] {
      stack.append(contentsOf: children.reversed())
    }
  }
  return out
}

func windowText(_ target: Target, maxChars: Int) -> WindowText {
  guard AXIsProcessTrusted() else { return WindowText() }
  let app = AXUIElementCreateApplication(target.pid)
  AXUIElementSetMessagingTimeout(app, 0.3)
  // Chromium and Electron apps build their web content tree only when asked.
  let woke = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
  guard let window = focusedWindow(app, title: target.title) else { return WindowText() }
  var text = walk(window, maxChars: maxChars, deadline: Date().addingTimeInterval(2.0))
  if woke && text.chars < 200 {
    Thread.sleep(forTimeInterval: 0.4)
    text = walk(window, maxChars: maxChars, deadline: Date().addingTimeInterval(2.0))
  }
  return text
}

// MARK: - Capture

func pixelSize(_ path: String) -> (Int, Int)? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
    let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
  else { return nil }
  return (w, h)
}

@discardableResult
func run(_ path: String, _ arguments: [String]) -> Int32 {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = arguments
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  do { try p.run() } catch { return -1 }
  p.waitUntilExit()
  return p.terminationStatus
}

func slug(_ s: String) -> String {
  let allowed = CharacterSet.alphanumerics
  let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
  let joined = String(mapped).split(separator: "-").joined(separator: "-")
  return joined.isEmpty ? "app" : String(joined.prefix(40))
}

let stampFormat: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyyMMdd-HHmmss-SSS"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()

func capture(_ target: Target, source: String) {
  if let bundle = target.bundleID, skipBundles.contains(bundle) {
    emit(["event": "skipped", "reason": "front-is-claude", "app": target.app])
    return
  }
  let now = Date()
  let id = "\(stampFormat.string(from: now))-\(slug(target.app))"
  let png = "\(inbox)/\(id).png"
  let txt = "\(inbox)/\(id).txt"

  var shot = ["-o", "-t", "png", "-l", String(target.windowID), png]
  if silent { shot.insert("-x", at: 0) }
  let status = run("/usr/sbin/screencapture", shot)
  let hasImage = status == 0 && FileManager.default.fileExists(atPath: png)
  if hasImage, let (w, h) = pixelSize(png), max(w, h) > 2400 {
    run("/usr/bin/sips", ["-Z", "2400", png])
  }

  let text = windowText(target, maxChars: 60000)
  var header = ["App: \(target.app)\(target.bundleID.map { " (\($0))" } ?? "")"]
  if let title = target.title { header.append("Window: \(title)") }
  if let url = text.url { header.append("URL: \(url)") }
  header.append("Captured: \(ISO8601DateFormatter().string(from: now))")
  if text.truncated { header.append("Note: the window's text was cut to fit.") }
  if text.lines.isEmpty {
    header.append(
      AXIsProcessTrusted()
        ? "Note: the app exposed no text through Accessibility; use the screenshot."
        : "Note: no text, Accessibility permission is missing.")
  }
  let body = header.joined(separator: "\n") + "\n---\n" + text.lines.joined(separator: "\n") + "\n"
  try? body.write(toFile: txt, atomically: true, encoding: .utf8)

  var record: [String: Any] = [
    "id": id, "app": target.app, "txt": txt, "chars": text.chars,
    "at": Int(now.timeIntervalSince1970 * 1000), "source": source,
  ]
  if hasImage { record["png"] = png }
  if let bundle = target.bundleID { record["bundleId"] = bundle }
  if let title = target.title { record["title"] = title }
  if let url = text.url { record["url"] = url }

  // The .json goes last, by rename: a session that sees it sees whole files.
  let json = "\(inbox)/\(id).json"
  if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
    let tmp = "\(inbox)/.\(id).json.tmp"
    FileManager.default.createFile(atPath: tmp, contents: data)
    rename(tmp, json)
  }
  var event = record
  event["event"] = "captured"
  event["json"] = json
  emit(event)
}

let captureQueue = DispatchQueue(label: "appshot.capture")

func trigger() {
  // Resolve the target now, before anything can change what is in front.
  guard let target = frontTarget(bundle: nil) else {
    emit(["event": "skipped", "reason": "no-window"])
    return
  }
  captureQueue.async { capture(target, source: "shortcut") }
}

// MARK: - Listening

var shortcut: Shortcut = .pair(left: 0x20, right: 0x40)
var isArmed = true
var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    return Unmanaged.passUnretained(event)
  }
  switch shortcut {
  case .pair(let left, let right):
    if type == .flagsChanged {
      let raw = event.flags.rawValue
      if raw & left != 0 && raw & right != 0 {
        if isArmed {
          isArmed = false
          trigger()
        }
      } else if raw & (left | right) == 0 {
        isArmed = true
      }
    }
  case .chord(let mods, let key):
    if type == .keyDown,
      CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == key,
      event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == mods
    {
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { trigger() }
      return nil  // swallowed where the tap may (an active tap); ignored on a listen-only one
    }
  }
  return Unmanaged.passUnretained(event)
}

func makeTap() -> CFMachPort? {
  let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
  // An active tap can swallow a chord's key; it needs Accessibility. Fall back to listening.
  if case .chord = shortcut, AXIsProcessTrusted(),
    let t = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
  {
    return t
  }
  return CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
}

func watchParent() {
  let parent = getppid()
  DispatchQueue.global().async {
    while true {
      if getppid() != parent { exit(0) }
      sleep(2)
    }
  }
}

func listen() -> Never {
  let text = opt("shortcut") ?? "option+option"
  guard let parsed = parseShortcut(text) else {
    emit(["event": "error", "reason": "bad-shortcut", "shortcut": text])
    exit(2)
  }
  shortcut = parsed
  watchParent()

  let fd = open("\(root)/listener.lock", O_CREAT | O_RDWR, 0o644)
  var saidStandby = false
  while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    if !saidStandby {
      emit(["event": "standby"])
      saidStandby = true
    }
    sleep(2)
  }

  emit(["event": "permissions"].merging(permissions(prompt: true)) { a, _ in a })
  var saidWaiting = false
  while true {
    tap = makeTap()
    if tap != nil { break }
    if !saidWaiting {
      emit(["event": "waiting", "reason": "no-event-tap"])
      saidWaiting = true
    }
    sleep(3)
  }
  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
  CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  CGEvent.tapEnable(tap: tap!, enable: true)
  emit(["event": "listening", "shortcut": text])
  CFRunLoopRun()
  exit(0)
}

// MARK: - Bringing Claude forward

func parentPid(_ pid: pid_t) -> pid_t {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
  return info.kp_eproc.e_ppid
}

func activate(pid start: pid_t) {
  var pid = start
  while pid > 1 {
    if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
      let url = app.bundleURL
    {
      run("/usr/bin/open", ["-a", url.path])
      emit(["event": "activated", "app": app.localizedName ?? url.lastPathComponent, "path": url.path, "pid": Int(pid)])
      return
    }
    pid = parentPid(pid)
  }
  emit(["event": "activated", "app": NSNull()])
}

// MARK: - Main

switch command {
case "listen":
  listen()
case "capture":
  if let delay = opt("delay").flatMap(Double.init), delay > 0 { Thread.sleep(forTimeInterval: delay) }
  if let target = frontTarget(bundle: opt("app")) {
    capture(target, source: "command")
  } else {
    emit(["event": "skipped", "reason": "no-window"])
  }
case "permissions":
  emit(["event": "permissions"].merging(permissions(prompt: flag("prompt"))) { a, _ in a })
case "activate":
  activate(pid: pid_t(opt("pid") ?? "") ?? getppid())
default:
  FileHandle.standardError.write("usage: appshot-helper listen|capture|permissions|activate\n".data(using: .utf8)!)
  exit(2)
}
