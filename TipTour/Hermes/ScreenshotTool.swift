// TipTour/Hermes/ScreenshotTool.swift
//
// MCP tool that captures the screen the frontmost app is on, downscales
// to 1280px wide, and returns a JPEG image content block (plus a one-
// line text breadcrumb so the chat transcript shows what was captured).
//
// Requires Screen Recording permission for the host process. macOS
// prompts on first use; permission persists.

import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

@MainActor
final class ScreenshotTool: MCPTool {
    let name = "take_screenshot"
    let description = "Capture the screen the frontmost app is on, resized to 1280px wide as JPEG. Returns a single image content block."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([]),
    ])

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard let screen = Self.frontmostAppScreen() ?? NSScreen.main else {
            throw MCPToolError.toolFailed("no screen available")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw MCPToolError.toolFailed("SCShareableContent failed — Screen Recording permission may be missing: \(error.localizedDescription)")
        }
        guard let display = content.displays.first(where: { Int($0.displayID) == Int(screen.displayID) }) else {
            throw MCPToolError.toolFailed("could not find SCDisplay for active screen")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.scalesToFit = true
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw MCPToolError.toolFailed("SCScreenshotManager failed: \(error.localizedDescription)")
        }

        let resized = Self.downscale(cgImage, maxWidth: 1280)
        guard let jpegData = Self.jpegData(from: resized, quality: 0.7) else {
            throw MCPToolError.toolFailed("JPEG encoding failed")
        }

        let base64 = jpegData.base64EncodedString()
        let dimensions = "\(resized.width)×\(resized.height)"
        return [
            .text("Captured screen \(screen.displayID), \(dimensions), \(jpegData.count) bytes"),
            .image(base64: base64, mimeType: "image/jpeg"),
        ]
    }

    // MARK: - Helpers

    /// Returns the NSScreen the frontmost app's focused window is on,
    /// or nil if the focused-window position can't be read (e.g. no
    /// frontmost app, or Accessibility permission missing).
    private static func frontmostAppScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let err = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard err == .success, let win = focusedWindow else { return nil }
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXPositionAttribute as CFString, &posValue)
        var point = CGPoint.zero
        if let p = posValue, AXValueGetType(p as! AXValue) == .cgPoint {
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
        }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// Downscale a CGImage to `maxWidth` (no-op if already smaller).
    private static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        if image.width <= maxWidth { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let newW = maxWidth
        let newH = Int(CGFloat(image.height) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage() ?? image
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
