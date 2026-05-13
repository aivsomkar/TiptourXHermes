// TipTour/Agents/Overlay/AgentOverlayWindowController.swift

import AppKit
import Combine
import SwiftUI

/// Hosts AgentOverlayStackView in a non-activating NSPanel anchored to the
/// top-right of the primary screen. Never steals focus.
///
/// **Sizing strategy: pinned content min/max on the panel.**
///
/// Every previous attempt to dynamically resize the panel — or to
/// subclass NSHostingView and short-circuit its layout — uncovered a
/// new SwiftUI feedback loop or tripped an AppKit invariant assertion.
/// The reliable fix is to:
///
///   1. Use a vanilla `NSHostingView` (no subclass, no `updateConstraints`
///      override — AppKit asserts that overrides must call super).
///   2. Make the panel report `contentMinSize == contentMaxSize == (316, 600)`
///      regardless of what callers try to set. AppKit's content-sizing
///      machinery treats this as an absolute size pin; the window
///      cannot shrink to match SwiftUI's natural content size, and
///      `updateWindowContentSizeExtremaIfNecessary`'s writes are
///      silently ignored.
///   3. SwiftUI sees a stable proposed size (316×600) every time
///      `updateC5Graph` runs, so `graphDidChange` doesn't fire about a
///      size change, no `setNeedsUpdate` happens during the constraint
///      pass, and AppKit's "more update passes than views" safeguard
///      never trips.
///
/// SwiftUI content is top-aligned inside the 600pt-tall panel; the
/// unused bottom area is transparent.
@MainActor
final class AgentOverlayWindowController {

    static let shared = AgentOverlayWindowController()

    private var panel: OverlayKeyablePanel?
    private var hostingView: NSHostingView<AgentOverlayStackView>?
    private var overlayStateCancellable: AnyCancellable?

    /// Right-edge and top-edge margin from the visible screen frame (pt).
    private let screenEdgeMargin: CGFloat = 8
    /// Fixed panel width (content 300pt + 8pt padding each side).
    private let panelWidth: CGFloat = 316
    /// Fixed panel height — large enough to fit the maximum supported
    /// 5-agent stack plus a detail card and the new-task form. The
    /// SwiftUI content aligns to the top and the unused bottom area
    /// stays transparent.
    private let panelHeight: CGFloat = 600

    private init() {
        createPanel()
        subscribeToOverlayState()
    }

    // MARK: - Panel creation

    private func createPanel() {
        let stackView = AgentOverlayStackView()
        let hosting = NSHostingView(rootView: stackView)
        // sizingOptions = [] keeps NSHostingView from pushing its
        // intrinsic content size up to Auto Layout. The panel's pinned
        // min/max (set below) is the real size authority, but disabling
        // this option removes one extra noisy signal.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        self.hostingView = hosting

        let pinnedContentSize = NSSize(width: panelWidth, height: panelHeight)
        let frame = panelFrameForCurrentScreen()
        let newPanel = OverlayKeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            pinnedContentSize: pinnedContentSize
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = true
        newPanel.contentView = hosting
        self.panel = newPanel
    }

    // MARK: - Visibility driven by agent count

    private func subscribeToOverlayState() {
        overlayStateCancellable = AgentSwarmManager.shared.overlayStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.updateVisibility(agentCount: statuses.count)
            }
    }

    private func updateVisibility(agentCount: Int) {
        if agentCount > 0 {
            showPanel()
        } else {
            hidePanel()
        }
    }

    // MARK: - Show / Hide

    func showPanel() {
        guard let panel else { return }
        if !panel.isVisible {
            // Refresh the frame on show in case the screen layout
            // changed (display added/removed, resolution change)
            // between sessions. The size won't change (min/max pin),
            // only the origin will move.
            panel.setFrame(panelFrameForCurrentScreen(), display: false)
            panel.orderFrontRegardless()
        }
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: - Positioning

    /// Compute the panel's frame for the currently-main screen. Called
    /// only at panel creation and on show.
    private func panelFrameForCurrentScreen() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        }
        let visibleFrame = screen.visibleFrame
        let panelX = visibleFrame.maxX - panelWidth - screenEdgeMargin
        let panelY = visibleFrame.maxY - panelHeight - screenEdgeMargin
        return NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
    }
}

// MARK: - NSPanel subclass

/// NSPanel subclass that **pins its content size**. The pinned value
/// (passed in at init) becomes the panel's `contentMinSize` AND
/// `contentMaxSize`. NSHostingView and AppKit can still try to update
/// the extrema, but our property overrides drop those writes silently,
/// so the pinned values are the only ones that ever take effect.
///
/// Why this matters: without pinning, SwiftUI's
/// `updateWindowContentSizeExtremaIfNecessary` (called from inside
/// `NSHostingView.updateConstraints`) sets the window's content min/max
/// to match the SwiftUI content's natural size. AppKit then shrinks the
/// window, triggering another layout pass, which re-runs
/// `updateConstraints`, which re-shrinks, etc. — eventually AppKit's
/// "more update passes than views" safeguard fires and the app crashes.
///
/// With min/max pinned to the same value, the window simply cannot
/// resize. SwiftUI sees a stable proposed size on every layout pass,
/// `graphDidChange` never fires about a size change, and the loop
/// can't form.
///
/// Also: this subclass can become the key window so text fields inside
/// (chat input, new-task description) receive keyboard events, while
/// `.nonactivatingPanel` style keeps it from stealing app focus.
private final class OverlayKeyablePanel: NSPanel {

    private let pinnedContentSize: NSSize

    init(contentRect: NSRect,
         styleMask: NSWindow.StyleMask,
         backing backingStoreType: NSWindow.BackingStoreType,
         defer flag: Bool,
         pinnedContentSize: NSSize) {
        self.pinnedContentSize = pinnedContentSize
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backingStoreType,
            defer: flag
        )
        // Apply the pin directly on `super` so AppKit's content-sizing
        // machinery sees the values during the first display cycle.
        // After this, any subsequent setter call (from NSHostingView or
        // anywhere else) is dropped by the property overrides below.
        super.contentMinSize = pinnedContentSize
        super.contentMaxSize = pinnedContentSize
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Always reports the pinned size — never the value from
    /// `updateWindowContentSizeExtremaIfNecessary` or any other writer.
    override var contentMinSize: NSSize {
        get { pinnedContentSize }
        set { /* deliberately suppressed — see class docs */ }
    }

    override var contentMaxSize: NSSize {
        get { pinnedContentSize }
        set { /* deliberately suppressed — see class docs */ }
    }

    /// AppKit may also call `setContentSize:` (the imperative resize
    /// entry point) from inside the constraint pass. With min == max
    /// at the pinned value, any size other than the pinned one would
    /// be clamped anyway, but we drop the call explicitly so the
    /// shrink-attempt doesn't even start a layout cycle.
    override func setContentSize(_ size: NSSize) {
        // Only honor calls that are already at the pinned size — i.e.
        // calls that aren't trying to change anything. Reject every
        // shrink/grow attempt.
        if size == pinnedContentSize {
            super.setContentSize(size)
        }
    }
}
