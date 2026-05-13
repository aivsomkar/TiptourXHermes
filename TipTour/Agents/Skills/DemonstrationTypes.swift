// TipTour/Agents/Skills/DemonstrationTypes.swift

import CoreGraphics
import Foundation

// MARK: - Action type taxonomy

enum ObservedActionType: String, Codable, Sendable {
    case click
    case type
    case keyPress
    case appSwitch
    case scroll
}

// MARK: - One recorded user action

struct ObservedAction: Codable, Sendable {
    let timestamp: Date
    let type: ObservedActionType
    let appName: String
    let point: CGPoint?
    let text: String?
    let keyDescription: String?
    let scrollDelta: CGFloat?
    let screenshotJPEG: Data?
}

// MARK: - Full recording session

struct ActionTrajectory: Sendable {
    let startedAt: Date
    let endedAt: Date
    let actions: [ObservedAction]
}
