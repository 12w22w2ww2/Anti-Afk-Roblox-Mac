import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import IOKit.pwr_mgt

enum AFKAction: String {
    case space
    case ws
    case zoom
}

struct Config {
    var interval: TimeInterval = 540
    var action: AFKAction = .space
    var targetName = "Roblox"
    var requireTarget = true
    var foreground = false
    var noSleep = true
    var runOnce = false
    var verbose = false
}

final class StopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case accessibility = 69
}

let keyCodes: [String: CGKeyCode] = [
    "space": 49,
    "w": 13,
    "s": 1,
    "i": 34,
    "o": 31
]

func printHelp() {
    print("""
    AntiAFK-RBX macOS ARM port

    Usage:
      antiafk-rbx-mac [options]

    Options:
      --interval <seconds>      Anti-AFK interval. Default: 540.
      --action <space|ws|zoom>  Action to send. Default: space.
      --target <name>           Running app name or bundle id fragment. Default: Roblox.
      --foreground              Activate Roblox before sending each action.
      --no-require-target       Keep running even when Roblox is not open.
      --no-sleep                Keep the Mac awake while running. Default.
      --allow-sleep             Do not create a no-sleep power assertion.
      --once                    Send one action and exit.
      --verbose                 Print extra diagnostics.
      --help                    Show this help.

    Notes:
      macOS requires Accessibility permission for synthetic input:
      System Settings > Privacy & Security > Accessibility.
    """)
}

func parseArguments(_ args: [String]) throws -> Config {
    var config = Config()
    var index = 1

    func requireValue(for option: String) throws -> String {
        guard index + 1 < args.count else {
            throw ArgumentError("Missing value for \(option)")
        }
        index += 1
        return args[index]
    }

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--interval", "--set-interval":
            let value = try requireValue(for: arg)
            guard let seconds = TimeInterval(value), seconds >= 3 else {
                throw ArgumentError("Interval must be a number >= 3 seconds")
            }
            config.interval = seconds
        case "--action", "--set-action":
            let value = try requireValue(for: arg).lowercased()
            guard let action = AFKAction(rawValue: value) else {
                throw ArgumentError("Action must be one of: space, ws, zoom")
            }
            config.action = action
        case "--target":
            config.targetName = try requireValue(for: arg)
        case "--foreground":
            config.foreground = true
        case "--no-require-target":
            config.requireTarget = false
        case "--no-sleep":
            config.noSleep = true
        case "--allow-sleep":
            config.noSleep = false
        case "--once":
            config.runOnce = true
        case "--verbose":
            config.verbose = true
        case "--help", "-h", "-?":
            printHelp()
            exit(ExitCode.ok.rawValue)
        default:
            throw ArgumentError("Unknown option: \(arg)")
        }
        index += 1
    }

    return config
}

struct ArgumentError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
}

func log(_ message: String) {
    print("[\(timestamp())] \(message)")
    fflush(stdout)
}

func checkAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func runningTargets(matching fragment: String) -> [NSRunningApplication] {
    let needle = fragment.lowercased()
    return NSWorkspace.shared.runningApplications.filter { app in
        let name = app.localizedName?.lowercased() ?? ""
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        return name.contains(needle) || bundleID.contains(needle)
    }
}

func sleepUntilNextAction(seconds: TimeInterval, stopState: StopState) {
    let deadline = Date().addingTimeInterval(seconds)
    while !stopState.shouldStop && Date() < deadline {
        Thread.sleep(forTimeInterval: min(0.5, deadline.timeIntervalSinceNow))
    }
}

func postKey(_ keyCode: CGKeyCode, to app: NSRunningApplication?) {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        return
    }
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

    if let pid = app?.processIdentifier {
        down?.postToPid(pid)
        usleep(35_000)
        up?.postToPid(pid)
    } else {
        down?.post(tap: .cghidEventTap)
        usleep(35_000)
        up?.post(tap: .cghidEventTap)
    }
}

func sendAction(_ action: AFKAction, to app: NSRunningApplication?, foreground: Bool) {
    if foreground {
        app?.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.25)
    }

    switch action {
    case .space:
        postKey(keyCodes["space"]!, to: app)
    case .ws:
        postKey(keyCodes["w"]!, to: app)
        usleep(120_000)
        postKey(keyCodes["s"]!, to: app)
    case .zoom:
        postKey(keyCodes["i"]!, to: app)
        usleep(160_000)
        postKey(keyCodes["o"]!, to: app)
    }
}

final class PowerAssertion {
    private var assertionID = IOPMAssertionID(0)

    init?(enabled: Bool) {
        guard enabled else {
            return nil
        }
        let reason = "AntiAFK-RBX macOS port is running" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result != kIOReturnSuccess {
            return nil
        }
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}

let stopState = StopState()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let signalQueue = DispatchQueue(label: "antiafk-rbx-mac.signals")

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
sigintSource.setEventHandler {
    stopState.stop()
}
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
sigtermSource.setEventHandler {
    stopState.stop()
}
sigtermSource.resume()

do {
    let config = try parseArguments(CommandLine.arguments)

    guard checkAccessibility() else {
        fputs("Accessibility permission is required. Enable it in System Settings > Privacy & Security > Accessibility, then run again.\n", stderr)
        exit(ExitCode.accessibility.rawValue)
    }

    let powerAssertion = PowerAssertion(enabled: config.noSleep)
    if config.noSleep && powerAssertion == nil {
        log("Warning: could not create no-sleep assertion; continuing.")
    }

    log("AntiAFK-RBX macOS port started. action=\(config.action.rawValue), interval=\(Int(config.interval))s, target=\(config.targetName)")

    repeat {
        autoreleasepool {
            let targets = runningTargets(matching: config.targetName)

            if targets.isEmpty && config.requireTarget {
                log("Waiting for \(config.targetName) to open...")
            } else if targets.isEmpty {
                sendAction(config.action, to: nil, foreground: false)
                log("Sent \(config.action.rawValue) to the active app.")
            } else {
                for app in targets {
                    sendAction(config.action, to: app, foreground: config.foreground)
                    if config.verbose {
                        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
                        log("Sent \(config.action.rawValue) to \(name) [pid \(app.processIdentifier)].")
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                }
                if !config.verbose {
                    log("Sent \(config.action.rawValue) to \(targets.count) \(config.targetName) process\(targets.count == 1 ? "" : "es").")
                }
            }
        }

        if config.runOnce {
            stopState.stop()
        } else {
            sleepUntilNextAction(seconds: targetsWaitInterval(config: config), stopState: stopState)
        }
    } while !stopState.shouldStop

    _ = powerAssertion
    log("Stopped.")
    exit(ExitCode.ok.rawValue)
} catch let error as ArgumentError {
    fputs("\(error.description)\n\n", stderr)
    printHelp()
    exit(ExitCode.usage.rawValue)
}

func targetsWaitInterval(config: Config) -> TimeInterval {
    config.requireTarget && runningTargets(matching: config.targetName).isEmpty
        ? min(config.interval, 15)
        : config.interval
}
