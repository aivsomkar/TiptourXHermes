// TipTourTests/AgentOverlayTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("AgentStateDisplay")
struct AgentStateDotVariantTests {

    @Test func spawningIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .spawning) == .grey)
    }

    @Test func activeIsGreenPulsing() {
        #expect(AgentStateDisplay.dotVariant(for: .active) == .greenPulsing)
    }

    @Test func busyIsBluePulsing() {
        #expect(AgentStateDisplay.dotVariant(for: .busy) == .bluePulsing)
    }

    @Test func blockedIsAmber() {
        let blocker = AgentBlocker(description: "Need login", possibleResolutions: [], raisedAt: Date())
        #expect(AgentStateDisplay.dotVariant(for: .blocked(blocker: blocker)) == .amber)
    }

    @Test func idleIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .idle) == .grey)
    }

    @Test func completedIsGreen() {
        #expect(AgentStateDisplay.dotVariant(for: .completed) == .green)
    }

    @Test func errorIsRed() {
        #expect(AgentStateDisplay.dotVariant(for: .error(message: "boom")) == .red)
    }

    @Test func terminatedIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .terminated) == .grey)
    }

    @Test func onlyActiveAndBusyArePulsing() {
        #expect(AgentStateDisplay.isPulsing(for: .greenPulsing) == true)
        #expect(AgentStateDisplay.isPulsing(for: .bluePulsing) == true)
        #expect(AgentStateDisplay.isPulsing(for: .amber) == false)
        #expect(AgentStateDisplay.isPulsing(for: .green) == false)
        #expect(AgentStateDisplay.isPulsing(for: .red) == false)
        #expect(AgentStateDisplay.isPulsing(for: .grey) == false)
    }

    @Test func statusIconIsNeverEmpty() {
        let states: [AgentState] = [
            .spawning, .active, .busy,
            .blocked(blocker: AgentBlocker(description: "x", possibleResolutions: [], raisedAt: Date())),
            .idle, .completed, .error(message: "e"), .terminated
        ]
        for state in states {
            #expect(!AgentStateDisplay.statusIcon(for: state).isEmpty,
                    "Empty icon for \(state)")
        }
    }
}

@Suite("AgentOverlayStack")
struct AgentOverlayStackTests {

    @Test func overlayLimitsVisibleAgentsToFive() {
        let statuses: [AgentStatus] = (0..<7).map { index in
            AgentStatus(
                id: UUID(),
                agentName: "Agent \(index)",
                taskSummary: "Task \(index)",
                state: .active,
                currentStep: "Working",
                stepHistory: [],
                tokensUsed: 0,
                elapsedSeconds: 0,
                blocker: nil,
                result: nil,
                isExpanded: false,
                isMinimised: false,
                chatHistory: []
            )
        }
        let visible = AgentOverlayStackView.visibleStatuses(from: statuses)
        #expect(visible.count == 5)
    }

    @Test func overlayShowsAllAgentsWhenFiveOrFewer() {
        let statuses: [AgentStatus] = (0..<3).map { index in
            AgentStatus(
                id: UUID(),
                agentName: "Agent \(index)",
                taskSummary: "Task \(index)",
                state: .active,
                currentStep: "Working",
                stepHistory: [],
                tokensUsed: 0,
                elapsedSeconds: 0,
                blocker: nil,
                result: nil,
                isExpanded: false,
                isMinimised: false,
                chatHistory: []
            )
        }
        let visible = AgentOverlayStackView.visibleStatuses(from: statuses)
        #expect(visible.count == 3)
    }

    @Test func overlayPrioritisesBlockedAgentsOverIdle() {
        let idleStatus = AgentStatus(
            id: UUID(), agentName: "Idle", taskSummary: "Idle task",
            state: .idle, currentStep: "", stepHistory: [], tokensUsed: 0,
            elapsedSeconds: 0, blocker: nil, result: nil,
            isExpanded: false, isMinimised: false, chatHistory: []
        )
        let blockedStatus = AgentStatus(
            id: UUID(), agentName: "Blocked", taskSummary: "Blocked task",
            state: .blocked(blocker: AgentBlocker(
                description: "Need login", possibleResolutions: [], raisedAt: Date()
            )),
            currentStep: "", stepHistory: [], tokensUsed: 0,
            elapsedSeconds: 0, blocker: nil, result: nil,
            isExpanded: false, isMinimised: false, chatHistory: []
        )
        // idle first in input — blocked should appear first in output
        let statuses = [idleStatus, blockedStatus]
        let visible = AgentOverlayStackView.visibleStatuses(from: statuses)
        #expect(visible.count == 2)
        #expect(visible[0].id == blockedStatus.id)
        #expect(visible[1].id == idleStatus.id)
    }
}
