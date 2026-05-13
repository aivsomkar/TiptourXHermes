// TipTour/Agents/Overlay/AgentStateDisplay.swift

import SwiftUI

// MARK: - Dot variant enum (testable without SwiftUI Color equality)

enum AgentDotVariant: Equatable {
    case greenPulsing   // active — green + pulsing
    case bluePulsing    // busy — blue + pulsing
    case amber          // blocked
    case green          // completed (static)
    case red            // error
    case grey           // idle / spawning / terminated
}

// MARK: - Pure display logic

struct AgentStateDisplay {

    static func dotVariant(for state: AgentState) -> AgentDotVariant {
        switch state {
        case .spawning:     return .grey
        case .active:       return .greenPulsing
        case .busy:         return .bluePulsing
        case .blocked:      return .amber
        case .idle:         return .grey
        case .completed:    return .green
        case .error:        return .red
        case .terminated:   return .grey
        }
    }

    static func dotColor(for variant: AgentDotVariant) -> Color {
        switch variant {
        case .greenPulsing: return DS.Colors.success
        case .bluePulsing:  return DS.Colors.blue400
        case .amber:        return DS.Colors.warning
        case .green:        return DS.Colors.success
        case .red:          return DS.Colors.destructive
        case .grey:         return DS.Colors.textTertiary
        }
    }

    static func isPulsing(for variant: AgentDotVariant) -> Bool {
        variant == .greenPulsing || variant == .bluePulsing
    }

    /// SF Symbol name used in the collapsed row indicator.
    static func statusIcon(for state: AgentState) -> String {
        switch state {
        case .completed:    return "checkmark.circle.fill"
        case .error:        return "xmark.circle.fill"
        case .blocked:      return "exclamationmark.triangle.fill"
        default:            return "circle.fill"
        }
    }
}
