// Throwaway v2: does the Input Monitoring prompt appear if we ask AFTER the
// app has finished launching, rather than during init? Stays alive so a prompt
// has time to show.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOKit
import IOKit.hid
import Foundation

let logPath = ProcessInfo.processInfo.environment["PERMCHECK_LOG"] ?? "/tmp/permcheck.log"
var report = ""
func say(_ text: String) {
    report += text + "\n"
    try? report.write(toFile: logPath, atomically: true, encoding: .utf8)
}

func probeTap() -> Bool {
    let mask = 1 << CGEventType.keyDown.rawValue
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                      callback: { _, _, e, _ in Unmanaged.passUnretained(e) },
                                      userInfo: nil) else { return false }
    CGEvent.tapEnable(tap: tap, enable: false)
    return true
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        say("ppid              : \(getppid())")
        say("didFinishLaunching fired")
        say("preflight listen  : \(CGPreflightListenEventAccess())")
        say("tapCreate (before): \(probeTap())")

        NSApp.activate(ignoringOtherApps: true)

        // Ask AFTER launch completes and the app is frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            say("IOHIDCheckAccess(listen) -> \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted 1=denied 2=unknown)")

            say("--- calling IOHIDRequestAccess(listen) now ---")
            let hid = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            say("IOHIDRequestAccess -> \(hid)")

            say("--- calling CGRequestListenEventAccess() now ---")
            let result = CGRequestListenEventAccess()
            say("CGRequestListenEventAccess -> \(result)")

            say("--- attempting tapCreate again ---")
            say("tapCreate (after) : \(probeTap())")
            say("(staying alive 20s so any prompt can appear)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
            say("preflight listen at exit: \(CGPreflightListenEventAccess())")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
