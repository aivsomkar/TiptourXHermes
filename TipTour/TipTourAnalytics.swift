//
//  TipTourAnalytics.swift
//  TipTour
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//
//  NOTE: PostHog SDK removed during rebrand (Task 4). All methods are
//  stubbed as no-ops. This file is deleted entirely in Task 5.
//

import Foundation

enum TipTourAnalytics {

    // MARK: - Setup

    static func configure() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// Claude responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// Claude's response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        // Analytics removed during rebrand; see Plan 2 if reinstating.
    }
}
