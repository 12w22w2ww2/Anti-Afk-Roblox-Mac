import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import IOKit.pwr_mgt
import SwiftUI

enum AFKAction: String, CaseIterable, Identifiable {
    case space
    case ws
    case zoom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .space:
            "Space"
        case .ws:
            "W then S"
        case .zoom:
            "I then O"
        }
    }
}

struct RunnerConfig {
    var interval: TimeInterval
    var action: AFKAction
    var targetName: String
    var requireTarget: Bool
    var foreground: Bool
    var noSleep: Bool
    var multiInstance: Bool
    var multiInstanceDelay: TimeInterval
}

enum AppPage: String, CaseIterable, Identifiable {
    case main = "Main"
    case advanced = "Advanced"
    case utilities = "Utils"
    case logs = "Logs"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .main:
            "play.circle.fill"
        case .advanced:
            "slider.horizontal.3"
        case .utilities:
            "square.grid.2x2.fill"
        case .logs:
            "terminal.fill"
        }
    }
}

enum FPSCapPreset: Int, CaseIterable, Identifiable {
    case off = 0
    case fps3 = 3
    case fps5 = 5
    case fps7 = 7
    case fps10 = 10
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var label: String {
        rawValue == 0 ? "Off" : "\(rawValue) FPS"
    }
}

let keyCodes: [String: CGKeyCode] = [
    "space": 49,
    "w": 13,
    "s": 1,
    "i": 34,
    "o": 31
]

@MainActor
final class AppModel: ObservableObject {
    @Published var isRunning = false
    @Published var isTrusted = AXIsProcessTrusted()
    @Published var status = "Ready"
    @Published var logs: [String] = ["Ready. Accessibility is checked as a warning only."]
    @Published var targetCount = 0
    @Published var fpsCapStatus = "Off"
    @Published var isLaunchingInstance = false

    private var timer: Timer?
    private var permissionTimer: Timer?
    private let fpsThrottle = CPUThrottleController()
    private var powerAssertion: PowerAssertion?
    private var config: RunnerConfig?

    func refreshPermission() {
        isTrusted = AXIsProcessTrusted()
        if !isRunning {
            status = isTrusted ? "Ready" : "Ready, permission unverified"
        }
    }

    func beginPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermission()
            }
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)

        if !isTrusted {
            openAccessibilitySettings()
            appendLog("Opened Accessibility settings. Enable AntiAFK-RBX. If it was already enabled, remove it, add it again, then reopen the app.")
        }
    }

    func start(config newConfig: RunnerConfig) {
        refreshPermission()

        stopTimerOnly()
        config = newConfig
        powerAssertion = PowerAssertion(enabled: newConfig.noSleep)
        isRunning = true
        status = "Running"
        if !isTrusted {
            appendLog("Accessibility is not confirmed by macOS. Starting anyway; if input does not reach Roblox, open Accessibility manually.")
        }
        appendLog("Started. Action: \(newConfig.action.label), interval: \(Int(newConfig.interval))s.")
        runTick()

        timer = Timer.scheduledTimer(withTimeInterval: newConfig.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runTick()
            }
        }
    }

    func stop() {
        stopTimerOnly()
        powerAssertion = nil
        config = nil
        isRunning = false
        status = "Stopped"
        appendLog("Stopped.")
    }

    func testOnce(config newConfig: RunnerConfig) {
        refreshPermission()

        if !isTrusted {
            appendLog("Accessibility is not confirmed by macOS. Testing anyway.")
        }

        config = newConfig
        runTick()
    }

    private func runTick() {
        guard let config else {
            return
        }

        let targets = runningTargets(matching: config.targetName)
        targetCount = targets.count

        if targets.isEmpty && config.requireTarget {
            status = "Waiting for \(config.targetName)"
            appendLog("Waiting for \(config.targetName) to open.")
            return
        }

        if targets.isEmpty {
            sendAction(config.action, to: nil, foreground: false)
            status = "Sent \(config.action.label)"
            appendLog("Sent \(config.action.label) to the active app.")
            return
        }

        let apps = config.multiInstance ? targets : Array(targets.prefix(1))

        for (index, app) in apps.enumerated() {
            sendAction(config.action, to: app, foreground: config.foreground)
            if config.multiInstanceDelay > 0 && index < apps.count - 1 {
                Thread.sleep(forTimeInterval: config.multiInstanceDelay)
            }
        }

        status = "Sent \(config.action.label)"
        appendLog("Sent \(config.action.label) to \(apps.count) \(config.targetName) process\(apps.count == 1 ? "" : "es").")
    }

    func applyFPSCap(_ fps: Int, targetName: String, multiInstance: Bool) {
        let sanitizedFPS = min(max(fps, 0), 240)

        if sanitizedFPS == 0 {
            fpsThrottle.stop()
            fpsCapStatus = "Off"
            appendLog("CPU FPS throttle disabled. Resumed throttled Roblox processes.")
            return
        }

        fpsThrottle.start(limit: sanitizedFPS, targetName: targetName, multiInstance: multiInstance)
        fpsCapStatus = "\(sanitizedFPS) FPS"
        appendLog("CPU FPS throttle set to \(sanitizedFPS). This pauses/resumes Roblox processes to reduce CPU usage.")
    }

    func launchRobloxInstance(delay: TimeInterval) {
        isLaunchingInstance = true
        appendLog("Launching another Roblox instance...")

        Task.detached {
            let result = RobloxLauncher.launchNewInstance(delay: delay)
            await MainActor.run {
                self.isLaunchingInstance = false
                self.appendLog(result)
                self.targetCount = runningTargets(matching: "Roblox").count
            }
        }
    }

    private func stopTimerOnly() {
        timer?.invalidate()
        timer = nil
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")

        if logs.count > 80 {
            logs.removeFirst(logs.count - 80)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    @State private var selectedPage = AppPage.main

    @AppStorage("interval") private var interval = 540.0
    @AppStorage("targetName") private var targetName = "Roblox"
    @AppStorage("action") private var action = AFKAction.space.rawValue
    @AppStorage("requireTarget") private var requireTarget = true
    @AppStorage("foreground") private var foreground = false
    @AppStorage("noSleep") private var noSleep = true
    @AppStorage("multiInstance") private var multiInstance = false
    @AppStorage("multiInstanceDelay") private var multiInstanceDelay = 0.0
    @AppStorage("fpsCap") private var fpsCap = 0
    @AppStorage("customFPSCap") private var customFPSCap = 15.0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                topBar
                Divider()
                pageContent
            }
        }
        .frame(width: 920, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshPermission()
            model.beginPermissionPolling()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: appIconImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AntiAFK-RBX")
                        .font(.system(size: 18, weight: .semibold))
                    Text("macOS ARM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 6) {
                ForEach(AppPage.allCases) { page in
                    Button {
                        selectedPage = page
                    } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(selectedPage == page ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedPage == page ? Color.accentColor : Color.primary)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                StatusPill(title: "Anti-AFK", value: model.isRunning ? "On" : "Off", color: model.isRunning ? .green : .secondary)
                StatusPill(title: "Roblox", value: "\(model.targetCount) found", color: model.targetCount > 0 ? .green : .orange)
                StatusPill(title: "FPS", value: model.fpsCapStatus, color: fpsCap == 0 ? .secondary : .blue)
            }
        }
        .padding(18)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedPage.rawValue)
                    .font(.system(size: 24, weight: .semibold))
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(model.isRunning ? .green : .secondary)
            }

            Spacer()

            if !model.isTrusted {
                Text("Permission unverified; Start still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(model.isTrusted ? "Permission OK" : "Open Accessibility") {
                model.requestPermission()
            }
            .buttonStyle(.bordered)

            Button(model.isRunning ? "Stop" : "Start") {
                model.isRunning ? model.stop() : model.start(config: currentConfig)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .main:
            mainPage
        case .advanced:
            advancedPage
        case .utilities:
            utilitiesPage
        case .logs:
            logsPage
        }
    }

    private var mainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    MetricCard(title: "Status", value: model.isRunning ? "Running" : "Idle", symbol: "bolt.fill", color: model.isRunning ? .green : .secondary)
                    MetricCard(title: "Roblox Clients", value: "\(model.targetCount)", symbol: "macwindow.on.rectangle", color: model.targetCount > 0 ? .green : .orange)
                    MetricCard(title: "Interval", value: "\(Int(interval))s", symbol: "timer", color: .blue)
                }

                Panel(title: "Anti-AFK") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            FieldLabel("Target")
                            TextField("Roblox", text: $targetName)
                        }

                        GridRow {
                            FieldLabel("Interval")
                            HStack {
                                Slider(value: $interval, in: 30...1200, step: 30)
                                Text("\(Int(interval))s")
                                    .frame(width: 62, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        }

                        GridRow {
                            FieldLabel("Action")
                            Picker("Action", selection: $action) {
                                ForEach(AFKAction.allCases) { item in
                                    Text(item.label).tag(item.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                HStack(spacing: 12) {
                    FeatureToggle(title: "Require Roblox", subtitle: "Wait until clients exist", systemImage: "scope", isOn: $requireTarget)
                    FeatureToggle(title: "Bring to front", subtitle: "Focus before action", systemImage: "arrow.up.forward.app", isOn: $foreground)
                    FeatureToggle(title: "Keep Mac awake", subtitle: "Prevent display sleep", systemImage: "moon.zzz.fill", isOn: $noSleep)
                }

                HStack {
                    Button("Test Once") {
                        model.testOnce(config: currentConfig)
                    }
                    .disabled(model.isRunning)

                    Button("Refresh Permission") {
                        model.refreshPermission()
                    }

                    Spacer()
                }
            }
            .padding(24)
        }
    }

    private var advancedPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Multi-Instance Support") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Cycle anti-idle actions through all detected Roblox clients", isOn: $multiInstance)
                            .toggleStyle(.switch)

                        HStack {
                            FieldLabel("Instance interval")
                            Picker("Instance interval", selection: $multiInstanceDelay) {
                                Text("Minimum").tag(0.0)
                                Text("1 sec").tag(1.0)
                                Text("3 sec").tag(3.0)
                                Text("5 sec").tag(5.0)
                                Text("10 sec").tag(10.0)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                Panel(title: "CPU FPS Throttle") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("CPU FPS Throttle", selection: $fpsCap) {
                            ForEach(FPSCapPreset.allCases) { preset in
                                Text(preset.label).tag(preset.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            FieldLabel("Custom")
                            Slider(value: $customFPSCap, in: 1...240, step: 1)
                            Text("\(Int(customFPSCap)) FPS")
                                .frame(width: 72, alignment: .trailing)
                                .monospacedDigit()
                        }

                        HStack {
                            Button("Apply Selected Cap") {
                                model.applyFPSCap(fpsCap, targetName: targetName, multiInstance: multiInstance)
                            }
                            Button("Apply Custom Cap") {
                                model.applyFPSCap(Int(customFPSCap), targetName: targetName, multiInstance: multiInstance)
                            }
                            Button("Turn Off Cap") {
                                fpsCap = 0
                                model.applyFPSCap(0, targetName: targetName, multiInstance: multiInstance)
                            }
                            Spacer()
                        }

                        Text("CPU throttling is session-only and takes effect immediately. Turn it off before actively playing if Roblox feels choppy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private var utilitiesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Roblox Instances") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            MetricCard(title: "Detected", value: "\(model.targetCount)", symbol: "rectangle.stack.fill", color: model.targetCount > 0 ? .green : .orange)
                            MetricCard(title: "Mode", value: multiInstance ? "Multi" : "Single", symbol: "square.grid.2x2", color: multiInstance ? .blue : .secondary)
                        }

                        HStack {
                            Button(model.isLaunchingInstance ? "Launching..." : "Launch New Instance") {
                                model.launchRobloxInstance(delay: multiInstanceDelay)
                            }
                            .disabled(model.isLaunchingInstance)

                            Button("Refresh Roblox Count") {
                                model.targetCount = runningTargets(matching: targetName).count
                            }

                            Spacer()
                        }

                        Text("macOS may still route Roblox URL launches through an existing client depending on Roblox's launcher behavior.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private var logsPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.logs.count) { count in
                proxy.scrollTo(max(0, count - 1), anchor: .bottom)
            }
        }
    }

    private var currentConfig: RunnerConfig {
        RunnerConfig(
            interval: interval,
            action: AFKAction(rawValue: action) ?? .space,
            targetName: targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Roblox" : targetName,
            requireTarget: requireTarget,
            foreground: foreground,
            noSleep: noSleep,
            multiInstance: multiInstance,
            multiInstanceDelay: multiInstanceDelay
        )
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FeatureToggle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}

struct FieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 118, alignment: .leading)
    }
}

@main
struct AntiAFKRBXApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

func openAccessibilitySettings() {
    let urls = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security"
    ]

    for value in urls {
        if let url = URL(string: value), NSWorkspace.shared.open(url) {
            return
        }
    }
}

func appIconImage() -> NSImage {
    if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        return image
    }

    return NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "AntiAFK-RBX") ?? NSImage()
}

final class CPUThrottleController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stoppedPIDs = Set<pid_t>()

    deinit {
        stop()
    }

    func start(limit: Int, targetName: String, multiInstance: Bool) {
        stop()

        let normalizedLimit = min(max(limit, 1), 240)
        let dutyCycle = min(max(Double(normalizedLimit) / 60.0, 0.04), 0.95)
        let cycleDuration = 0.25
        let runDuration = cycleDuration * dutyCycle
        let stopDuration = max(0.02, cycleDuration - runDuration)

        task = Task.detached { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let pids = await MainActor.run {
                    let targets = runningTargets(matching: targetName)
                    return (multiInstance ? targets : Array(targets.prefix(1))).map(\.processIdentifier)
                }

                let throttlePIDs = pids.filter { $0 != ProcessInfo.processInfo.processIdentifier }

                if throttlePIDs.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                try? await Task.sleep(nanoseconds: UInt64(runDuration * 1_000_000_000))

                for pid in throttlePIDs {
                    if Darwin.kill(pid, SIGSTOP) == 0 {
                        self.recordStopped(pid)
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(stopDuration * 1_000_000_000))

                for pid in throttlePIDs {
                    self.resume(pid)
                }
            }

            self.resumeAll()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        resumeAll()
    }

    private func recordStopped(_ pid: pid_t) {
        lock.lock()
        stoppedPIDs.insert(pid)
        lock.unlock()
    }

    private func resume(_ pid: pid_t) {
        Darwin.kill(pid, SIGCONT)
        lock.lock()
        stoppedPIDs.remove(pid)
        lock.unlock()
    }

    private func resumeAll() {
        lock.lock()
        let pids = stoppedPIDs
        stoppedPIDs.removeAll()
        lock.unlock()

        for pid in pids {
            Darwin.kill(pid, SIGCONT)
        }
    }
}

enum RobloxLauncher {
    static func launchNewInstance(delay: TimeInterval) -> String {
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        if let appURL = robloxAppURLs().first {
            process.arguments = ["-n", appURL.path]
        } else {
            process.arguments = ["-n", "-a", "Roblox"]
        }

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return "Launch request sent with new-instance mode."
            }

            return "Roblox launch exited with status \(process.terminationStatus)."
        } catch {
            return "Could not launch Roblox: \(error.localizedDescription)."
        }
    }
}

func robloxAppURLs() -> [URL] {
    let fileManager = FileManager.default
    var urls: [URL] = []

    let bundleIDs = [
        "com.roblox.RobloxPlayer",
        "com.roblox.Roblox",
        "com.roblox.RobloxPlayerInstaller"
    ]

    for bundleID in bundleIDs {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            urls.append(url)
        }
    }

    let candidates = [
        "/Applications/Roblox.app",
        "\(fileManager.homeDirectoryForCurrentUser.path)/Applications/Roblox.app"
    ]

    for path in candidates {
        let url = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: url.path) {
            urls.append(url)
        }
    }

    var seen = Set<String>()
    return urls.filter { seen.insert($0.path).inserted }
}

func runningTargets(matching fragment: String) -> [NSRunningApplication] {
    let needle = fragment.lowercased()
    return NSWorkspace.shared.runningApplications.filter { app in
        let name = app.localizedName?.lowercased() ?? ""
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        return name.contains(needle) || bundleID.contains(needle)
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

        let reason = "AntiAFK-RBX is running" as CFString
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
