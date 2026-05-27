//
//  CameraFlashTests.swift
//  selfieTests
//

import Testing
@testable import selfie

struct CameraFlashTests {

    @Test @MainActor func ringLightControlsAvailableInDualCameraMode() {
        let model = CameraViewModel()
        model.dualCameraEnabled = true
        model.ringLightEnabled = true
        model.frontFlashStyle = .ring
        #expect(model.usesFrontRingLight == true)
    }

    @Test @MainActor func ringLightOverlayWhenDualSessionActive() {
        let model = CameraViewModel()
        model.dualCameraEnabled = true
        model.ringLightEnabled = true
        model.frontFlashStyle = .ring
        model.toggleFlashControl()
        #expect(model.ringLightEnabled == false)
        model.toggleFlashControl()
        #expect(model.ringLightEnabled == true)
    }

    @Test @MainActor func ringLightOffByDefault() {
        let model = CameraViewModel()
        #expect(model.shouldShowRingLightOverlay == false)
    }

    @Test @MainActor func toggleFlashEnablesRingInDualMode() {
        let model = CameraViewModel()
        model.dualCameraEnabled = true
        model.toggleFlashControl()
        #expect(model.ringLightEnabled == true)
        #expect(model.frontFlashStyle == .ring)
    }

    @Test @MainActor func dualCameraSwapTogglesLayout() {
        let model = CameraViewModel()
        model.dualCameraEnabled = true
        model.flipCamera()
        #expect(model.dualCameraLayoutSwapped == true)
        model.flipCamera()
        #expect(model.dualCameraLayoutSwapped == false)
    }
}
