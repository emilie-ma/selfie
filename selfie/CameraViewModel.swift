import AVFoundation
import Photos
import SwiftUI
import Combine
import UIKit

// MARK: - Camera ViewModel
class CameraViewModel: NSObject, ObservableObject {

    // MARK: Session
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let multiCamPhotoOutput: AVCapturePhotoOutput = {
        let output = AVCapturePhotoOutput()
        output.maxPhotoQualityPrioritization = .balanced
        return output
    }()
    private let multiCamMovieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var secondaryVideoInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.selfie.session")

    // Dual camera
    private var multiCamSession: AVCaptureMultiCamSession?
    private var isDualCameraActive = false
    @Published private(set) var frontCameraPort: AVCaptureInput.Port?
    @Published private(set) var backCameraPort: AVCaptureInput.Port?
    @Published var previewSessionID = UUID()
    @Published private(set) var isReconfiguringSession = false
    private var previewBindings: [ObjectIdentifier: (session: AVCaptureSession, connection: AVCaptureConnection)] = [:]
    private var previewBindingKeys: [ObjectIdentifier: String] = [:]
    private var dualCamSwitchToken = UUID()

    // MARK: Published State
    @Published var ringLightEnabled = false
    @Published var ringLightIntensity: Double = 0.88
    @Published var ringLightShade: RingLightShade = .neutral
    @Published var showFlashSettingsPanel = false
    @Published var frontFlashStyle: FrontFlashStyle = .ring
    @Published var dualCameraEnabled = false
    @Published var showGrid = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var timerMode: TimerMode = .off
    @Published var currentZoom: CGFloat = 1.0
    @Published var showZoomLabel = false
    @Published var isUsingFrontCamera = true
    @Published var isRecording = false
    @Published var isRecordingLocked = false
    @Published var recordingProgress: CGFloat = 0
    @Published var countdownValue: Int?
    @Published var showScreenFlash = false
    @Published var lastCapturedMedia: CapturedMedia?
    @Published var pendingPreview: PendingCapture?
    @Published var isProcessingCapture = false
    @Published var saveDestination: SaveDestination = .both
    @Published var isCameraReady = false
    @Published var cameraStatusMessage: String?

    // MARK: Internal
    private var baseZoom: CGFloat = 1.0
    private var zoomHideTask: DispatchWorkItem?
    private var photoCompletion: ((Data?) -> Void)?
    private var timerCancellable: AnyCancellable?
    private var countdownCancellable: AnyCancellable?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let maxRecordingDuration: TimeInterval = 60
    private var isPhotoCaptureInProgress = false
    private var isSessionConfigured = false

    var activeSession: AVCaptureSession {
        if dualCameraEnabled, isDualCameraActive, let multi = multiCamSession { return multi }
        return session
    }

    private var activePhotoOutput: AVCapturePhotoOutput {
        isDualCameraActive ? multiCamPhotoOutput : photoOutput
    }

    private var activeMovieOutput: AVCaptureMovieFileOutput {
        isDualCameraActive ? multiCamMovieOutput : movieOutput
    }

    var supportsDualCamera: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    var flashIcon: String {
        if isUsingFrontCamera {
            return ringLightEnabled ? "bolt.fill" : "bolt.slash.fill"
        }
        switch flashMode {
        case .off:  return "bolt.slash.fill"
        case .on:   return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        @unknown default: return "bolt.slash.fill"
        }
    }

    var isFlashActive: Bool {
        if isUsingFrontCamera { return ringLightEnabled }
        return flashMode != .off
    }

    var timerIcon: String {
        switch timerMode {
        case .off:   return "timer"
        case .three: return "3.circle.fill"
        case .ten:   return "10.circle.fill"
        }
    }

    // MARK: - Permissions & Setup
    func requestPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSetup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.beginSetup()
                } else {
                    DispatchQueue.main.async {
                        self?.cameraStatusMessage = "Camera access denied. Enable it in Settings → Privacy → Camera."
                    }
                }
            }
        case .denied, .restricted:
            cameraStatusMessage = "Camera access denied. Enable it in Settings → Privacy → Camera."
        @unknown default:
            cameraStatusMessage = "Camera is unavailable."
        }
    }

    private func beginSetup() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { _ in }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isSessionConfigured, self.session.isRunning {
                DispatchQueue.main.async { self.isCameraReady = self.hasActivePhotoConnection() }
                return
            }
            if self.isSessionConfigured, !self.session.isRunning, !self.dualCameraEnabled {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isCameraReady = self.session.isRunning && self.hasActivePhotoConnection()
                }
                return
            }
            self.configureSession()
        }
    }

    /// Releases timers, preview connections, and camera sessions when leaving the camera screen.
    func teardownCaptureResources() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        timerCancellable?.cancel()
        timerCancellable = nil
        zoomHideTask?.cancel()
        zoomHideTask = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        dualCamSwitchToken = UUID()

        if isRecording {
            stopVideoRecording()
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.removeAllPreviewBindings()
            if self.isDualCameraActive, let multi = self.multiCamSession {
                multi.stopRunning()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isSessionConfigured = false
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.isRecordingLocked = false
            self.isReconfiguringSession = false
            self.isProcessingCapture = false
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .photo

        guard addVideoInput(to: session, position: isUsingFrontCamera ? .front : .back) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.isCameraReady = false
                #if targetEnvironment(simulator)
                self.cameraStatusMessage = "The iOS Simulator has no camera. Connect a real iPhone to test the camera, or import a photo below to demo the app."
                #else
                self.cameraStatusMessage = "No camera found on this device."
                #endif
            }
            return
        }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        configurePhotoOutput(photoOutput)
        if isUsingFrontCamera, let device = videoInput?.device {
            applySnapchatFrontCameraSettings(to: device)
        }
        applyMirroring()
        session.commitConfiguration()
        session.startRunning()
        isSessionConfigured = true

        DispatchQueue.main.async {
            self.isCameraReady = self.session.isRunning && self.hasActivePhotoConnection()
            if self.isUsingFrontCamera {
                self.currentZoom = SnapchatCameraTuning.frontCameraZoomFactor
                self.baseZoom = SnapchatCameraTuning.frontCameraZoomFactor
            }
            if self.isCameraReady {
                self.cameraStatusMessage = nil
            } else {
                #if targetEnvironment(simulator)
                self.cameraStatusMessage = "The iOS Simulator has no camera. Connect a real iPhone to test the camera, or import a photo below to demo the app."
                #else
                self.cameraStatusMessage = "Camera failed to start."
                #endif
            }
        }
    }

    private func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return device
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: position
        )
        if let device = discovery.devices.first {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func addVideoInput(to targetSession: AVCaptureSession, position: AVCaptureDevice.Position) -> Bool {
        guard
            let device = cameraDevice(for: position),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        if targetSession.canAddInput(input) {
            targetSession.addInput(input)
            videoInput = input
            return true
        }
        return false
    }

    private func configurePhotoOutput(_ output: AVCapturePhotoOutput) {
        output.maxPhotoQualityPrioritization = .balanced
        output.isDepthDataDeliveryEnabled = false
        output.isPortraitEffectsMatteDeliveryEnabled = false
        output.isHighResolutionCaptureEnabled = false
    }

    /// After video recording, restore `.photo` on whichever session is active (single or dual-cam).
    private func resetActiveSessionToPhotoPreset() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let target = self.activeSession
            target.beginConfiguration()
            if target.canSetSessionPreset(.photo) {
                target.sessionPreset = .photo
            }
            target.commitConfiguration()
        }
    }

    private func applyMirroring() {
        // Front camera: mirror preview AND photo/video so saved file matches live view (Snapchat WYSIWYG).
        if let connection = photoOutput.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isUsingFrontCamera
        }
        if let connection = multiCamPhotoOutput.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if let movieConnection = movieOutput.connection(with: .video) {
            movieConnection.automaticallyAdjustsVideoMirroring = false
            movieConnection.isVideoMirrored = isUsingFrontCamera
        }
        if let movieConnection = multiCamMovieOutput.connection(with: .video) {
            movieConnection.automaticallyAdjustsVideoMirroring = false
            movieConnection.isVideoMirrored = false
        }
    }

    func updatePreviewMirroring(for previewLayer: AVCaptureVideoPreviewLayer) {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isUsingFrontCamera
    }

    // MARK: - Flash / Ring Light
    func toggleFlashControl() {
        if isUsingFrontCamera {
            ringLightEnabled.toggle()
            if ringLightEnabled {
                frontFlashStyle = .ring
            }
            applyRingLightScreenBoost()
        } else {
            toggleFlash()
            showFlashSettingsPanel = false
            applyRingLightScreenBoost()
        }
    }

    func toggleFlashSettingsPanel() {
        showFlashSettingsPanel.toggle()
    }

    func dismissFlashSettingsPanel() {
        showFlashSettingsPanel = false
    }

    func selectRingLightShade(_ shade: RingLightShade) {
        ringLightShade = shade
        ringLightEnabled = true
        frontFlashStyle = .ring
        applyRingLightScreenBoost()
    }

    func setFrontFlashStyle(_ style: FrontFlashStyle) {
        frontFlashStyle = style
        if style == .ring {
            ringLightEnabled = true
        }
        applyRingLightScreenBoost()
    }

    func updateRingLightIntensity() {
        applyRingLightScreenBoost()
    }

    func applyRingLightScreenBoost() {
        DispatchQueue.main.async {
            if self.isUsingFrontCamera, self.ringLightEnabled, self.frontFlashStyle == .ring {
                ScreenFlashController.shared.applyRingLight(intensity: self.ringLightIntensity)
            } else {
                ScreenFlashController.shared.restore()
            }
        }
    }

    func toggleFlash() {
        guard !isUsingFrontCamera else {
            toggleFlashControl()
            return
        }
        switch flashMode {
        case .off:  flashMode = .on
        case .on:   flashMode = .auto
        case .auto: flashMode = .off
        @unknown default: flashMode = .off
        }
    }

    // MARK: - Preview binding
    func bindPreviewLayer(_ layer: AVCaptureVideoPreviewLayer, inputPort: AVCaptureInput.Port?, mirrorVideo: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isReconfiguringSession else { return }
            self.configurePreviewLayer(layer, inputPort: inputPort, mirrorVideo: mirrorVideo, session: self.activeSession)
        }
    }

    func unbindPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async { [weak self] in
            self?.removePreviewBinding(for: layer)
        }
    }

    private func removePreviewBinding(for layer: AVCaptureVideoPreviewLayer) {
        let key = ObjectIdentifier(layer)
        previewBindingKeys.removeValue(forKey: key)
        if let binding = previewBindings.removeValue(forKey: key) {
            binding.session.removeConnection(binding.connection)
        }
        DispatchQueue.main.async {
            layer.session = nil
        }
    }

    private func removeAllPreviewBindings() {
        previewBindingKeys.removeAll()
        let bindings = previewBindings
        previewBindings.removeAll()
        for (_, binding) in bindings {
            binding.session.removeConnection(binding.connection)
        }
    }

    private func configurePreviewLayer(
        _ layer: AVCaptureVideoPreviewLayer,
        inputPort: AVCaptureInput.Port?,
        mirrorVideo: Bool,
        session targetSession: AVCaptureSession
    ) {
        let layerKey = ObjectIdentifier(layer)
        let bindingKey = "\(ObjectIdentifier(targetSession))-\(inputPort.map { ObjectIdentifier($0) }?.hashValue ?? 0)-\(mirrorVideo)"
        if previewBindingKeys[layerKey] == bindingKey { return }

        removePreviewBinding(for: layer)
        previewBindingKeys[layerKey] = bindingKey

        DispatchQueue.main.async {
            layer.videoGravity = .resizeAspectFill

            guard let port = inputPort else {
                layer.session = targetSession
                if let connection = layer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrorVideo
                }
                return
            }

            layer.setSessionWithNoConnection(targetSession)

            self.sessionQueue.async {
                let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
                guard targetSession.canAddConnection(connection) else { return }

                targetSession.addConnection(connection)
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrorVideo
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                connection.isEnabled = true

                self.previewBindings[layerKey] = (targetSession, connection)
            }
        }
    }

    private func videoPort(for input: AVCaptureDeviceInput, device: AVCaptureDevice) -> AVCaptureInput.Port? {
        input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first
            ?? input.ports.first { $0.mediaType == .video }
    }

    private func connectOutput(_ output: AVCaptureOutput, to port: AVCaptureInput.Port, on targetSession: AVCaptureSession) {
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard targetSession.canAddConnection(connection) else { return }
        targetSession.addConnection(connection)
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - Dual Camera
    func toggleDualCamera() {
        guard supportsDualCamera, !isReconfiguringSession else { return }

        let enabling = !dualCameraEnabled
        let switchToken = UUID()
        dualCamSwitchToken = switchToken
        isReconfiguringSession = true

        if !enabling {
            dualCameraEnabled = false
            backCameraPort = nil
            frontCameraPort = nil
            previewSessionID = UUID()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.dualCamSwitchToken == switchToken, self.isReconfiguringSession else { return }
            self.dualCamSwitchToken = UUID()
            self.sessionQueue.async {
                self.finishDualCameraFailure(message: "Dual camera took too long. Try again.")
                DispatchQueue.main.async { self.isReconfiguringSession = false }
            }
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if enabling {
                self.startDualCameraSession()
            } else {
                self.stopDualCameraSession()
            }
            DispatchQueue.main.async {
                guard self.dualCamSwitchToken == switchToken else { return }
                self.isReconfiguringSession = false
            }
        }
    }

    private func startDualCameraSession() {
        removeAllPreviewBindings()
        session.stopRunning()

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()

        let multiSession = multiCamSession ?? AVCaptureMultiCamSession()
        tearDownMultiCamSession(multiSession)

        multiSession.beginConfiguration()

        guard
            let backDevice = cameraDevice(for: .back),
            let frontDevice = cameraDevice(for: .front),
            let backInput = try? AVCaptureDeviceInput(device: backDevice),
            let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
            multiSession.canAddInput(backInput),
            multiSession.canAddInput(frontInput)
        else {
            multiSession.commitConfiguration()
            finishDualCameraFailure(message: "Dual camera is not available on this device.")
            return
        }

        applyDualCamFormats(back: backDevice, front: frontDevice)

        multiSession.addInputWithNoConnections(backInput)
        multiSession.addInputWithNoConnections(frontInput)

        guard
            let backPort = videoPort(for: backInput, device: backDevice),
            let frontPort = videoPort(for: frontInput, device: frontDevice),
            multiSession.canAddOutput(multiCamPhotoOutput)
        else {
            multiSession.commitConfiguration()
            finishDualCameraFailure(message: "Could not connect dual camera outputs.")
            return
        }

        multiSession.addOutputWithNoConnections(multiCamPhotoOutput)
        configurePhotoOutput(multiCamPhotoOutput)
        connectOutput(multiCamPhotoOutput, to: backPort, on: multiSession)

        if multiSession.canAddOutput(multiCamMovieOutput) {
            multiSession.addOutputWithNoConnections(multiCamMovieOutput)
            connectOutput(multiCamMovieOutput, to: backPort, on: multiSession)
            if let movieConnection = multiCamMovieOutput.connection(with: .video) {
                movieConnection.automaticallyAdjustsVideoMirroring = false
                movieConnection.isVideoMirrored = false
            }
        }

        if multiSession.hardwareCost > 1.0 {
            applyDualCamFormats(back: backDevice, front: frontDevice, lowBandwidth: true)
        }

        configureDualCamDeviceSettings(backDevice)
        configureDualCamDeviceSettings(frontDevice)

        multiSession.commitConfiguration()
        multiSession.startRunning()

        guard multiSession.isRunning else {
            finishDualCameraFailure(message: "Dual camera failed to start.")
            return
        }

        multiCamSession = multiSession
        isDualCameraActive = true
        secondaryVideoInput = frontInput
        videoInput = backInput

        DispatchQueue.main.async {
            self.backCameraPort = backPort
            self.frontCameraPort = frontPort
            self.dualCameraEnabled = true
            self.isUsingFrontCamera = false
            self.showFlashSettingsPanel = false
            self.currentZoom = 1.0
            self.baseZoom = 1.0
            self.previewSessionID = UUID()
            self.isCameraReady = self.hasActivePhotoConnection()
        }
    }

    private func finishDualCameraFailure(message: String? = nil) {
        if isDualCameraActive, let multi = multiCamSession {
            tearDownMultiCamSession(multi)
            multi.stopRunning()
        }
        multiCamSession = nil
        isDualCameraActive = false
        secondaryVideoInput = nil

        reconfigureSingleSession()

        DispatchQueue.main.async {
            self.dualCameraEnabled = false
            self.backCameraPort = nil
            self.frontCameraPort = nil
            self.previewSessionID = UUID()
            if let message {
                self.cameraStatusMessage = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if self.cameraStatusMessage == message {
                        self.cameraStatusMessage = nil
                    }
                }
            }
            self.isCameraReady = self.session.isRunning && self.hasActivePhotoConnection()
        }
    }

    private func stopDualCameraSession() {
        removeAllPreviewBindings()

        if let multi = multiCamSession {
            multi.stopRunning()
            tearDownMultiCamSession(multi)
        }

        multiCamSession = nil
        isDualCameraActive = false
        secondaryVideoInput = nil

        reconfigureSingleSession()

        DispatchQueue.main.async {
            self.backCameraPort = nil
            self.frontCameraPort = nil
            self.previewSessionID = UUID()
            self.isCameraReady = self.session.isRunning && self.hasActivePhotoConnection()
        }
    }

    private func tearDownMultiCamSession(_ multiSession: AVCaptureMultiCamSession) {
        multiSession.beginConfiguration()
        for connection in multiSession.connections {
            multiSession.removeConnection(connection)
        }
        for output in multiSession.outputs { multiSession.removeOutput(output) }
        for input in multiSession.inputs { multiSession.removeInput(input) }
        multiSession.commitConfiguration()
    }

    private func applyDualCamFormats(
        back: AVCaptureDevice,
        front: AVCaptureDevice,
        lowBandwidth: Bool = false
    ) {
        let backMaxPixels: Int32 = lowBandwidth ? 1280 * 720 : 1920 * 1080
        let frontMaxPixels: Int32 = lowBandwidth ? 640 * 480 : 1280 * 720

        try? back.lockForConfiguration()
        try? front.lockForConfiguration()
        defer {
            back.unlockForConfiguration()
            front.unlockForConfiguration()
        }

        // Back: widest field-of-view first so dual cam doesn't look cropped/zoomed.
        if let backFormat = bestMultiCamFormat(for: back, maxPixels: backMaxPixels, preferWidestFOV: true) {
            back.activeFormat = backFormat
        }
        if let frontFormat = bestMultiCamFormat(for: front, maxPixels: frontMaxPixels, preferWidestFOV: false) {
            front.activeFormat = frontFormat
        }

        let frameDuration = CMTime(value: 1, timescale: 30)
        back.activeVideoMinFrameDuration = frameDuration
        back.activeVideoMaxFrameDuration = frameDuration
        front.activeVideoMinFrameDuration = frameDuration
        front.activeVideoMaxFrameDuration = frameDuration
    }

    private func configureDualCamDeviceSettings(_ device: AVCaptureDevice) {
        try? device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let resetZoom = max(device.minAvailableVideoZoomFactor, 1.0)
        device.videoZoomFactor = min(resetZoom, device.activeFormat.videoMaxZoomFactor)

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .none
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
    }

    private func bestMultiCamFormat(
        for device: AVCaptureDevice,
        maxPixels: Int32,
        preferWidestFOV: Bool
    ) -> AVCaptureDevice.Format? {
        let supported = device.formats.filter(\.isMultiCamSupported)
        let withinBudget = supported.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width * dimensions.height <= maxPixels
        }

        let candidates = withinBudget.isEmpty ? supported : withinBudget
        guard !candidates.isEmpty else { return nil }

        if preferWidestFOV {
            // Multi-cam formats can be sensor-cropped; widest FOV matches normal 1x back camera.
            return candidates.max(by: { $0.videoFieldOfView < $1.videoFieldOfView })
        }

        return candidates.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return l.width * l.height > r.width * r.height
        })
    }

    private func reconfigureSingleSession() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .photo

        guard addVideoInput(to: session, position: isUsingFrontCamera ? .front : .back) else {
            session.commitConfiguration()
            return
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        configurePhotoOutput(photoOutput)
        if isUsingFrontCamera, let device = videoInput?.device {
            applySnapchatFrontCameraSettings(to: device)
        }
        applyMirroring()
        session.commitConfiguration()
        session.startRunning()
        isSessionConfigured = true
        DispatchQueue.main.async {
            self.isCameraReady = self.session.isRunning
            if self.isUsingFrontCamera {
                self.currentZoom = SnapchatCameraTuning.frontCameraZoomFactor
                self.baseZoom = SnapchatCameraTuning.frontCameraZoomFactor
            }
        }
    }

    private func hasActivePhotoConnection() -> Bool {
        guard let connection = activePhotoOutput.connection(with: .video) else { return false }
        return connection.isEnabled && connection.isActive
    }

    // MARK: - Capture Photo
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        let doCapture: () -> Void = { [weak self] in
            self?.performPhotoCapture(completion: completion)
        }

        switch timerMode {
        case .off:
            doCapture()
        case .three:
            startCountdown(from: 3, action: doCapture)
        case .ten:
            startCountdown(from: 10, action: doCapture)
        }
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings? {
        let output = activePhotoOutput
        guard !output.availablePhotoCodecTypes.isEmpty else { return nil }

        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else if let codec = output.availablePhotoCodecTypes.first {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        } else {
            return nil
        }

        if #available(iOS 16.0, *) {
            // Cap capture size to limit memory during PhotoBeautyProcessor pass.
            let maxDim = output.maxPhotoDimensions
            let cap = CMVideoDimensions(
                width: isUsingFrontCamera ? 3024 : 4032,
                height: isUsingFrontCamera ? 4032 : 3024
            )
            settings.maxPhotoDimensions = CMVideoDimensions(
                width: min(maxDim.width, cap.width),
                height: min(maxDim.height, cap.height)
            )
        } else {
            settings.isHighResolutionPhotoEnabled = false
        }
        if #available(iOS 13.0, *) {
            settings.isAutoVirtualDeviceFusionEnabled = false
        }
        if !isUsingFrontCamera, output.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        return settings
    }

    private func performPhotoCapture(completion: @escaping (Data?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.activeSession.isRunning, !self.dualCameraEnabled {
                self.reconfigureSingleSession()
            }

            guard !self.isReconfiguringSession,
                  self.activeSession.isRunning,
                  self.hasActivePhotoConnection(),
                  !self.isPhotoCaptureInProgress,
                  let settings = self.makePhotoSettings() else {
                DispatchQueue.main.async {
                    self.isPhotoCaptureInProgress = false
                    self.showScreenFlash = false
                    self.cameraStatusMessage = self.isCameraReady
                        ? "Could not take photo. Try again or restart the app."
                        : self.cameraStatusMessage
                    completion(nil)
                }
                return
            }

            let useScreenFlash = self.isUsingFrontCamera && self.ringLightEnabled && self.frontFlashStyle == .regular

            if useScreenFlash {
                DispatchQueue.main.async { self.showScreenFlash = true }
            }

            let captureDelay: TimeInterval = useScreenFlash ? 0.1 : 0
            self.sessionQueue.asyncAfter(deadline: .now() + captureDelay) { [weak self] in
                guard let self,
                      self.hasActivePhotoConnection(),
                      !self.isPhotoCaptureInProgress else {
                    DispatchQueue.main.async {
                        self?.showScreenFlash = false
                        self?.cameraStatusMessage = "The iOS Simulator has no camera. Connect a real iPhone to test capture."
                        completion(nil)
                    }
                    return
                }
                self.isPhotoCaptureInProgress = true
                self.photoCompletion = completion
                self.activePhotoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func startCountdown(from seconds: Int, action: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.countdownValue = seconds
        }

        var remaining = seconds
        countdownCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                remaining -= 1
                if remaining > 0 {
                    self?.countdownValue = remaining
                } else {
                    self?.countdownCancellable?.cancel()
                    self?.countdownValue = nil
                    action()
                }
            }
    }

    // MARK: - Video Recording
    func startVideoRecording() {
        guard !activeMovieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let targetSession = activeSession
        sessionQueue.async {
            targetSession.beginConfiguration()
            if targetSession.canSetSessionPreset(.high) {
                targetSession.sessionPreset = .high
            }
            targetSession.commitConfiguration()
        }

        activeMovieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStartTime = Date()
            self.recordingProgress = 0
            self.startRecordingTimer()
        }
    }

    func stopVideoRecording() {
        guard activeMovieOutput.isRecording else { return }
        activeMovieOutput.stopRecording()
        stopRecordingTimer()
        resetActiveSessionToPhotoPreset()
        DispatchQueue.main.async {
            self.isRecording = false
            self.isRecordingLocked = false
            self.recordingProgress = 0
        }
    }

    func lockRecording() {
        guard isRecording, !isRecordingLocked else { return }
        DispatchQueue.main.async {
            self.isRecordingLocked = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.recordingProgress = min(CGFloat(elapsed / self.maxRecordingDuration), 1.0)
            if elapsed >= self.maxRecordingDuration {
                self.stopVideoRecording()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Camera Controls
    func flipCamera() {
        guard !dualCameraEnabled, !isReconfiguringSession else { return }
        isUsingFrontCamera.toggle()
        if !isUsingFrontCamera {
            ringLightEnabled = false
            showFlashSettingsPanel = false
        } else if ringLightEnabled {
            showFlashSettingsPanel = false
        }
        applyRingLightScreenBoost()

        sessionQueue.async {
            self.session.beginConfiguration()
            if let currentInput = self.videoInput {
                self.session.removeInput(currentInput)
            }
            let position: AVCaptureDevice.Position = self.isUsingFrontCamera ? .front : .back
            guard
                let device = self.cameraDevice(for: position),
                let newInput = try? AVCaptureDeviceInput(device: device)
            else {
                self.session.commitConfiguration()
                return
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
            }
            if self.isUsingFrontCamera {
                self.applySnapchatFrontCameraSettings(to: device)
            } else {
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, 1.0)
                    device.unlockForConfiguration()
                } catch {}
            }
            self.applyMirroring()
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                let zoom: CGFloat = self.isUsingFrontCamera
                    ? SnapchatCameraTuning.frontCameraZoomFactor
                    : 1.0
                self.currentZoom = zoom
                self.baseZoom = zoom
            }
        }
    }

    /// True when we must mirror in software because the photo connection couldn't mirror at capture.
    private func needsPostCaptureMirrorFallback() -> Bool {
        guard isUsingFrontCamera else { return false }
        guard let connection = activePhotoOutput.connection(with: .video) else { return true }
        return !connection.isVideoMirroringSupported || !connection.isVideoMirrored
    }

    /// Default front-camera zoom + exposure so preview matches Snapchat framing.
    private func applySnapchatFrontCameraSettings(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let target = SnapchatCameraTuning.frontCameraZoomFactor
            let minZ = device.minAvailableVideoZoomFactor
            let maxZ = min(device.activeFormat.videoMaxZoomFactor, 10)
            device.videoZoomFactor = min(max(target, minZ), maxZ)

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            // Device busy during reconfiguration.
        }
    }

    func cycleTimer() {
        switch timerMode {
        case .off:   timerMode = .three
        case .three: timerMode = .ten
        case .ten:   timerMode = .off
        }
    }

    func toggleGrid() {
        showGrid.toggle()
    }

    // MARK: - Zoom
    func zoom(factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
            let minZoom = max(device.minAvailableVideoZoomFactor, 1.0)
            let newZoom = max(minZoom, min(self.baseZoom * factor, maxZoom))

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newZoom
                device.unlockForConfiguration()
            } catch { return }

            DispatchQueue.main.async {
                self.currentZoom = newZoom
                self.showZoomLabel = true
            }

            self.zoomHideTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async { self?.showZoomLabel = false }
            }
            self.zoomHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
        }
    }

    func commitZoom(factor: CGFloat) {
        baseZoom = currentZoom
    }

    // MARK: - Focus & Exposure
    func focus(at point: CGPoint) {
        let screenSize = UIScreen.main.bounds.size
        let focusPoint = CGPoint(x: point.y / screenSize.height, y: 1 - point.x / screenSize.width)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = focusPoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = focusPoint
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch {
                // Device busy during session reconfiguration — ignore.
            }
        }
    }

    // MARK: - Save
    func savePendingCapture(to destination: SaveDestination) async {
        guard let pending = pendingPreview else { return }

        if pending.isVideo, let url = pending.videoURL {
            if let media = await MediaStorageService.shared.saveVideo(from: url, destination: destination) {
                await MainActor.run {
                    self.lastCapturedMedia = media
                    self.pendingPreview = nil
                }
            }
        } else if let data = pending.photoData {
            if let media = await MediaStorageService.shared.savePhoto(data: data, destination: destination) {
                await MainActor.run {
                    self.lastCapturedMedia = media
                    self.pendingPreview = nil
                }
            }
        }
    }

    func discardPendingCapture() {
        if let url = pendingPreview?.videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingPreview = nil
        isProcessingCapture = false
    }

    func loadDemoPhoto(data: Data) {
        pendingPreview = PendingCapture(photoData: data, videoURL: nil, isVideo: false)
    }
}

// MARK: - Pending Capture
struct PendingCapture: Identifiable {
    let id = UUID()
    let photoData: Data?
    let videoURL: URL?
    let isVideo: Bool

    var previewImage: UIImage? {
        if let data = photoData { return UIImage(data: data) }
        if let url = videoURL {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            guard let cgImage = VideoThumbnailGenerator.cgImage(from: generator, at: .zero) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        DispatchQueue.main.async {
            self.isPhotoCaptureInProgress = false
            if let error {
                self.showScreenFlash = false
                self.cameraStatusMessage = "Photo capture failed: \(error.localizedDescription)"
                self.photoCompletion?(nil)
                self.photoCompletion = nil
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let rawData = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.photoCompletion?(nil)
                self.photoCompletion = nil
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPhotoCaptureInProgress = false
            self.showScreenFlash = false
            self.applyRingLightScreenBoost()
            self.isProcessingCapture = true

            let isFront = self.isUsingFrontCamera
            let needsMirrorFallback = self.needsPostCaptureMirrorFallback()
            DispatchQueue.global(qos: .utility).async {
                let data = autoreleasepool {
                    PhotoBeautyProcessor.prepareSnapchatPhoto(
                        from: rawData,
                        isFrontCamera: isFront,
                        applyMirrorFallback: needsMirrorFallback
                    )
                }

                DispatchQueue.main.async {
                    self.isProcessingCapture = false
                    self.pendingPreview = PendingCapture(photoData: data, videoURL: nil, isVideo: false)
                    self.photoCompletion?(data)
                    self.photoCompletion = nil
                }
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraViewModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        resetActiveSessionToPhotoPreset()

        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        DispatchQueue.main.async {
            self.pendingPreview = PendingCapture(photoData: nil, videoURL: outputFileURL, isVideo: true)
        }
    }
}

// MARK: - Supporting Enums
enum TimerMode {
    case off, three, ten
}

enum SaveDestinationOption: String, CaseIterable, Identifiable {
    case both = "Both"
    case appOnly = "Memories"
    case cameraRollOnly = "Camera Roll"

    var id: String { rawValue }

    var destination: SaveDestination {
        switch self {
        case .both: return .both
        case .appOnly: return .appOnly
        case .cameraRollOnly: return .cameraRollOnly
        }
    }

    var icon: String {
        switch self {
        case .both: return "square.on.square"
        case .appOnly: return "photo.on.rectangle"
        case .cameraRollOnly: return "arrow.down.to.line"
        }
    }
}

enum RingLightShade: String, CaseIterable, Identifiable {
    case neutral = "Neutral"
    case warm = "Warm"
    case cool = "Cool"

    var id: String { rawValue }

    var tintColor: UIColor {
        switch self {
        case .neutral: return UIColor(white: 1.0, alpha: 1)
        case .warm:    return UIColor(red: 1.0, green: 0.94, blue: 0.78, alpha: 1)
        case .cool:    return UIColor(red: 0.86, green: 0.93, blue: 1.0, alpha: 1)
        }
    }

    var swiftUIColor: Color {
        Color(tintColor)
    }
}

enum FrontFlashStyle: String, CaseIterable, Identifiable {
    case regular = "Regular"
    case ring = "Ring"

    var id: String { rawValue }
}

