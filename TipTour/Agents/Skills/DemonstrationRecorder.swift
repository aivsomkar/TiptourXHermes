// TipTour/Agents/Skills/DemonstrationRecorder.swift

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// Not an actor: CGEventTap C callbacks are synchronous and cannot cross an actor boundary.
// NSLock guards all mutable state instead.
final class DemonstrationRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var _actions: [ObservedAction] = []
    private var _startedAt: Date = .now
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var typingBuffer: String = ""
    private var typingAppName: String = ""
    private var lastScrollTimePerApp: [String: Date] = [:]
    private var workspaceObserver: NSObjectProtocol?

    // MARK: - Public API

    func start() {
        lock.withLock {
            _startedAt = .now
            _actions = []
            typingBuffer = ""
            typingAppName = ""
            lastScrollTimePerApp = [:]
        }
        installEventTap()
        installWorkspaceObserver()
    }

    func stop() -> ActionTrajectory {
        let endedAt = Date.now
        flushTypingBuffer()
        removeEventTap()
        removeWorkspaceObserver()
        return lock.withLock {
            ActionTrajectory(startedAt: _startedAt, endedAt: endedAt, actions: _actions)
        }
    }

    // MARK: - Internal for unit tests (inject actions without a live CGEventTap)

    func simulateClick(appName: String, point: CGPoint, screenshotJPEG: Data? = nil) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .click, appName: appName,
            point: point, text: nil, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: screenshotJPEG
        )
        appendAction(action)
    }

    func simulatePrintableKey(appName: String, characters: String) {
        let currentApp = lock.withLock { typingAppName }
        if appName == currentApp {
            lock.withLock { typingBuffer += characters }
        } else {
            flushTypingBuffer()
            lock.withLock {
                typingBuffer = characters
                typingAppName = appName
            }
        }
    }

    func simulateNonPrintableKey(appName: String, keyDescription: String) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .keyPress, appName: appName,
            point: nil, text: nil, keyDescription: keyDescription,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
    }

    func simulateAppSwitch(newAppName: String) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .appSwitch, appName: newAppName,
            point: nil, text: nil, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
        lock.withLock { typingAppName = "" }
    }

    func simulateScroll(appName: String, delta: CGFloat) {
        let now = Date.now
        let debounced = lock.withLock { () -> Bool in
            if let last = lastScrollTimePerApp[appName],
               now.timeIntervalSince(last) < 0.5 { return true }
            lastScrollTimePerApp[appName] = now
            return false
        }
        guard !debounced else { return }
        let action = ObservedAction(
            timestamp: now, type: .scroll, appName: appName,
            point: nil, text: nil, keyDescription: nil,
            scrollDelta: delta, screenshotJPEG: nil
        )
        appendAction(action)
    }

    // MARK: - Trajectory formatting

    static func formatForLLM(_ trajectory: ActionTrajectory) -> (text: String, images: [Data]) {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = []
        var images: [Data] = []

        for action in trajectory.actions {
            let timeStr = timeFormatter.string(from: action.timestamp)
            let line: String

            switch action.type {
            case .click:
                let pointStr = action.point.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "(?, ?)"
                let screenshotNote = action.screenshotJPEG != nil ? " [screenshot]" : ""
                line = "[\(timeStr)] click at \(pointStr) in \(action.appName)\(screenshotNote)"
                if let jpg = action.screenshotJPEG { images.append(jpg) }
            case .type:
                line = "[\(timeStr)] type \"\(action.text ?? "")\" in \(action.appName)"
            case .keyPress:
                line = "[\(timeStr)] keyPress \(action.keyDescription ?? "?") in \(action.appName)"
            case .appSwitch:
                line = "[\(timeStr)] appSwitch → \(action.appName)"
            case .scroll:
                let direction = (action.scrollDelta ?? 0) <= 0 ? "↓" : "↑"
                let amount = Int(abs(action.scrollDelta ?? 0))
                line = "[\(timeStr)] scroll \(direction) \(amount)pt in \(action.appName)"
            }
            lines.append(line)
        }

        return (lines.joined(separator: "\n"), images)
    }

    // MARK: - Private helpers

    private func appendAction(_ action: ObservedAction) {
        lock.withLock { _actions.append(action) }
    }

    private func flushTypingBuffer() {
        let (text, appName) = lock.withLock { () -> (String, String) in
            let t = typingBuffer
            let a = typingAppName
            typingBuffer = ""
            typingAppName = ""
            return (t, a)
        }
        guard !text.isEmpty else { return }
        let action = ObservedAction(
            timestamp: .now, type: .type, appName: appName,
            point: nil, text: text, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
    }

    // MARK: - CGEventTap installation

    private func installEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let tapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<DemonstrationRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            recorder.handleCGEvent(type: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[DemonstrationRecorder] ⚠️ failed to create CGEventTap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - NSWorkspace app-switch observer

    private func installWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let newAppName = app.localizedName else { return }
            self.flushTypingBuffer()
            let action = ObservedAction(
                timestamp: .now, type: .appSwitch, appName: newAppName,
                point: nil, text: nil, keyDescription: nil,
                scrollDelta: nil, screenshotJPEG: nil
            )
            self.appendAction(action)
            self.lock.withLock { self.typingAppName = "" }
        }
    }

    private func removeWorkspaceObserver() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    // MARK: - CGEventTap callback dispatch (runs on main thread)

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            handleClickEvent(event)
        case .keyDown:
            handleKeyDownEvent(event)
        case .scrollWheel:
            handleScrollEvent(event)
        default:
            break
        }
    }

    private func handleClickEvent(_ event: CGEvent) {
        flushTypingBuffer()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let quartzLocation = event.location
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: quartzLocation.x, y: primaryScreenHeight - quartzLocation.y)
        let timestamp = Date.now

        Task { @MainActor [weak self] in
            guard let self else { return }
            let screenshotJPEG = await Self.captureClickScreenshotJPEG()
            let action = ObservedAction(
                timestamp: timestamp, type: .click, appName: appName,
                point: appKitPoint, text: nil, keyDescription: nil,
                scrollDelta: nil, screenshotJPEG: screenshotJPEG
            )
            self.appendAction(action)
        }
    }

    @MainActor
    private static func captureClickScreenshotJPEG() async -> Data? {
        guard let cgImage = try? await CompanionScreenCaptureUtility.capturePrimaryScreenAsCGImage() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }

    private func handleKeyDownEvent(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        let chars = nsEvent.charactersIgnoringModifiers ?? ""
        let modifiers = nsEvent.modifierFlags
        let hasCommandOrControl = modifiers.contains(.command) || modifiers.contains(.control)

        let isPrintable = !chars.isEmpty
            && !hasCommandOrControl
            && chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })

        if isPrintable {
            let currentApp = lock.withLock { typingAppName }
            if appName == currentApp {
                lock.withLock { typingBuffer += chars }
            } else {
                flushTypingBuffer()
                lock.withLock {
                    typingBuffer = chars
                    typingAppName = appName
                }
            }
        } else {
            flushTypingBuffer()
            let keyDescription = buildKeyDescription(from: nsEvent)
            let action = ObservedAction(
                timestamp: .now, type: .keyPress, appName: appName,
                point: nil, text: nil, keyDescription: keyDescription,
                scrollDelta: nil, screenshotJPEG: nil
            )
            appendAction(action)
        }
    }

    private func handleScrollEvent(_ event: CGEvent) {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        simulateScroll(appName: appName, delta: CGFloat(delta))
    }

    private func buildKeyDescription(from nsEvent: NSEvent) -> String {
        var parts: [String] = []
        let modifiers = nsEvent.modifierFlags
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }

        let keyName: String
        switch nsEvent.keyCode {
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 53: keyName = "Escape"
        case 51: keyName = "Delete"
        case 123: keyName = "Left"
        case 124: keyName = "Right"
        case 125: keyName = "Down"
        case 126: keyName = "Up"
        case 116: keyName = "PageUp"
        case 121: keyName = "PageDown"
        case 115: keyName = "Home"
        case 119: keyName = "End"
        case 49: keyName = "Space"
        default:
            keyName = nsEvent.charactersIgnoringModifiers?.uppercased() ?? "Key\(nsEvent.keyCode)"
        }

        parts.append(keyName)
        return parts.joined(separator: "+")
    }
}
