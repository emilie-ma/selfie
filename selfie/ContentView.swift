import SwiftUI
import AVFoundation
import AVKit
import UIKit
import PhotosUI

// MARK: - Root View
struct ContentView: View {
    @StateObject private var cameraModel = CameraViewModel()
    @State private var showGallery = false
    @AppStorage("defaultSaveOption") private var defaultSaveOptionRaw = SaveDestinationOption.both.rawValue

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Camera preview
            CameraPreviewContainer(model: cameraModel)
                .ignoresSafeArea()
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if cameraModel.showFlashSettingsPanel {
                            cameraModel.dismissFlashSettingsPanel()
                        }
                    }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { cameraModel.zoom(factor: $0) }
                        .onEnded { _ in cameraModel.commitZoom(factor: 1) }
                )
                .onTapGesture(count: 2) {
                    cameraModel.flipCamera()
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    cameraModel.focus(at: location)
                }

            // Grid overlay
            if cameraModel.showGrid {
                GridOverlayView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Ring light overlay (selfie + dual-cam front face)
            if cameraModel.shouldShowRingLightOverlay {
                RingLightOverlay(
                    shade: cameraModel.ringLightShade,
                    intensity: cameraModel.ringLightIntensity
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // Brief full-screen flash only for Regular front-flash mode at capture
            if cameraModel.showScreenFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Countdown overlay
            if let countdown = cameraModel.countdownValue {
                CountdownOverlay(value: countdown)
            }

            // Camera setup / permission message
            if let message = cameraModel.cameraStatusMessage, cameraModel.pendingPreview == nil {
                CameraStatusOverlay(message: message) { data in
                    cameraModel.loadDemoPhoto(data: data)
                }
            }

            // Main UI (hidden during capture preview)
            if cameraModel.pendingPreview == nil {
                VStack(spacing: 0) {
                    TopBarView(model: cameraModel)
                    Spacer()
                    BottomBarView(model: cameraModel, showGallery: $showGallery)
                }

                // Flash settings popup (top-right, Snapchat style)
                if cameraModel.showFlashSettingsPanel && cameraModel.usesFrontRingLight {
                    FlashSettingsPanel(model: cameraModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 88)
                        .padding(.trailing, 58)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(20)
                }

                if cameraModel.showFlashSettingsPanel {
                    VStack {
                        Spacer()
                        Text("Tap anywhere on Camera to dismiss")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.bottom, 130)
                    }
                    .allowsHitTesting(false)
                    .zIndex(19)
                }

                // Right sidebar controls (Snapchat style)
                HStack {
                    Spacer()
                    RightSidebarView(model: cameraModel)
                        .padding(.trailing, 12)
                }
            }

            // Zoom indicator
            if cameraModel.showZoomLabel {
                VStack {
                    Spacer()
                    Text(String(format: "%.1fx", cameraModel.currentZoom))
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(.bottom, 180)
                }
            }

            // Brief processing — avoids showing raw capture that flips when beauty pass finishes
            if cameraModel.isProcessingCapture {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.2)
                }
                .zIndex(150)
            }

            // Post-capture preview (Snapchat save flow)
            if let pending = cameraModel.pendingPreview {
                CapturePreviewView(
                    pending: pending,
                    defaultSaveOptionRaw: $defaultSaveOptionRaw,
                    onSave: { destination in
                        Task {
                            await cameraModel.savePendingCapture(to: destination)
                        }
                    },
                    onDiscard: {
                        cameraModel.discardPendingCapture()
                    }
                )
                .zIndex(200)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: cameraModel.pendingPreview?.id)
        .animation(.easeInOut(duration: 0.15), value: cameraModel.showScreenFlash)
        .sheet(isPresented: $showGallery) {
            GalleryView(lastMedia: cameraModel.lastCapturedMedia)
        }
        .onAppear {
            cameraModel.requestPermissions()
            if let last = MediaStorageService.shared.loadAll().first {
                cameraModel.lastCapturedMedia = last
            }
        }
        .onChange(of: cameraModel.shouldShowRingLightOverlay) { _, isOn in
            if isOn {
                cameraModel.applyRingLightScreenBoost()
            } else {
                ScreenFlashController.shared.restore()
            }
        }
        .onDisappear {
            ScreenFlashController.shared.restore()
        }
        .statusBarHidden(true)
    }
}

// MARK: - Camera Preview Container
struct CameraPreviewContainer: View {
    @ObservedObject var model: CameraViewModel

    var body: some View {
        ZStack {
            if model.isReconfiguringSession {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            } else if model.dualCameraEnabled, model.dualCamMainPort != nil {
                PortPreviewView(
                    model: model,
                    inputPort: model.dualCamMainPort,
                    mirrorVideo: model.dualCameraLayoutSwapped
                )
                .id(model.previewSessionID)

                if model.dualCamPiPPort != nil {
                    VStack {
                        HStack {
                            PortPreviewView(
                                model: model,
                                inputPort: model.dualCamPiPPort,
                                mirrorVideo: !model.dualCameraLayoutSwapped
                            )
                            .id("\(model.previewSessionID)-pip")
                            .frame(width: 110, height: 155)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white, lineWidth: 2)
                            )
                            .shadow(radius: 4)
                            .padding(.leading, 16)
                            .padding(.top, 100)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            } else {
                PortPreviewView(
                    model: model,
                    inputPort: nil,
                    mirrorVideo: model.isUsingFrontCamera
                )
                .id(model.previewSessionID)
            }
        }
    }
}

// MARK: - Top Bar
struct TopBarView: View {
    @ObservedObject var model: CameraViewModel

    var body: some View {
        HStack {
            Spacer()

            if model.timerMode != .off {
                ControlButton(icon: model.timerIcon, isActive: true) {
                    model.cycleTimer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

// MARK: - Right Sidebar (Snapchat-style vertical controls)
struct RightSidebarView: View {
    @ObservedObject var model: CameraViewModel

    var body: some View {
        VStack(spacing: 22) {
            // Flash at top of sidebar (Snapchat layout)
            VStack(spacing: 10) {
                Button {
                    model.toggleFlashControl()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: model.flashIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(model.isFlashActive ? .black : .white)
                        .frame(width: 44, height: 44)
                        .background(model.isFlashActive ? Color.white : Color.clear)
                        .clipShape(Circle())
                }

                if model.usesFrontRingLight {
                    Button {
                        model.toggleFlashSettingsPanel()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(model.showFlashSettingsPanel ? .yellow : .white)
                            .frame(width: 36, height: 28)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())

            SidebarButton(icon: model.timerIcon, label: "Timer", isActive: model.timerMode != .off) {
                model.cycleTimer()
            }

            SidebarButton(icon: "grid", label: "Grid", isActive: model.showGrid) {
                model.toggleGrid()
            }

            if model.supportsDualCamera {
                SidebarButton(
                    icon: "camera.on.rectangle.fill",
                    label: "Dual",
                    isActive: model.dualCameraEnabled
                ) {
                    model.toggleDualCamera()
                }
                .opacity(model.isReconfiguringSession ? 0.4 : 1)
                .disabled(model.isReconfiguringSession)
            }

            Spacer()
        }
        .padding(.top, 56)
    }
}

// MARK: - Bottom Bar
struct BottomBarView: View {
    @ObservedObject var model: CameraViewModel
    @Binding var showGallery: Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center) {
                // Gallery / last capture thumbnail
                Button {
                    showGallery = true
                } label: {
                    GalleryThumbnailView(media: model.lastCapturedMedia)
                }

                Spacer()

                // Shutter
                ShutterButtonView(model: model)

                Spacer()

                // Flip camera
                Button {
                    model.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .opacity(model.isReconfiguringSession ? 0.4 : 1)
                .disabled(model.isReconfiguringSession)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
        }
    }
}

// MARK: - Shutter Button (tap photo, hold video, slide up to lock)
struct ShutterButtonView: View {
    @ObservedObject var model: CameraViewModel
    @State private var pressBeganAt: Date?
    @State private var holdWorkItem: DispatchWorkItem?
    @State private var didStartHoldRecording = false
    @State private var dragOffset: CGFloat = 0

    private let shutterSize: CGFloat = 78
    private let lockThreshold: CGFloat = -80
    private let holdThreshold: TimeInterval = 0.3

    var body: some View {
        ZStack {
            if model.isRecording {
                Circle()
                    .trim(from: 0, to: model.recordingProgress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: shutterSize + 8, height: shutterSize + 8)
                    .rotationEffect(.degrees(-90))
            }

            // Outer ring
            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: shutterSize, height: shutterSize)

            // Inner fill
            RoundedRectangle(cornerRadius: model.isRecording ? 8 : shutterSize / 2)
                .fill(model.isRecording ? Color.red : Color.white)
                .frame(
                    width: model.isRecording ? 36 : 64,
                    height: model.isRecording ? 36 : 64
                )
                .animation(.spring(response: 0.25), value: model.isRecording)

            // Lock indicator
            if model.isRecording && !model.isRecordingLocked {
                VStack {
                    Image(systemName: "lock.open.fill")
                        .font(.caption2)
                        .foregroundColor(.white)
                    Image(systemName: "chevron.up")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                }
                .offset(y: -70 + dragOffset)
                .opacity(min(1.0, Double(-dragOffset) / 40.0))
            }

            if model.isRecordingLocked {
                VStack {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("Locked")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                }
                .offset(y: -60)
            }
        }
        .contentShape(Circle())
        .offset(y: model.isRecording ? dragOffset : 0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressBeganAt == nil {
                        pressBeganAt = Date()
                        let work = DispatchWorkItem {
                            guard pressBeganAt != nil else { return }
                            didStartHoldRecording = true
                            model.startVideoRecording()
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        }
                        holdWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
                    }

                    if model.isRecording, !model.isRecordingLocked {
                        dragOffset = min(0, value.translation.height)
                        if dragOffset < lockThreshold {
                            model.lockRecording()
                        }
                    }
                }
                .onEnded { _ in
                    holdWorkItem?.cancel()
                    holdWorkItem = nil
                    dragOffset = 0

                    let pressDuration = pressBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressBeganAt = nil

                    if model.isRecordingLocked { return }

                    if didStartHoldRecording || model.isRecording {
                        if model.isRecording { model.stopVideoRecording() }
                        didStartHoldRecording = false
                    } else if pressDuration < holdThreshold {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.capturePhoto { _ in }
                    }
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                if model.isRecordingLocked {
                    model.stopVideoRecording()
                }
            }
        )
    }
}

// MARK: - Capture Preview (Snapchat-style save)
struct CapturePreviewView: View {
    let pending: PendingCapture
    @Binding var defaultSaveOptionRaw: String
    let onSave: (SaveDestination) -> Void
    let onDiscard: () -> Void

    @State private var showSaveMenu = false
    @State private var isSaving = false

    private var defaultOption: SaveDestinationOption {
        SaveDestinationOption(rawValue: defaultSaveOptionRaw) ?? .both
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Group {
                    if pending.isVideo, let url = pending.videoURL {
                        VideoPreviewPlayer(url: url)
                    } else if let image = pending.previewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                if showSaveMenu {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28)) { showSaveMenu = false }
                        }
                }

                // Close — top left, plain white X
                VStack {
                    HStack {
                        Button(action: onDiscard) {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.top, max(geo.safeAreaInsets.top, 12) + 16)
                    Spacer()
                }

                // Download — bottom left, tap save / hold for destination
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        ZStack(alignment: .bottomLeading) {
                            if showSaveMenu {
                                SaveDestinationMenu { option in
                                    defaultSaveOptionRaw = option.rawValue
                                    isSaving = true
                                    onSave(option.destination)
                                    showSaveMenu = false
                                }
                                .offset(y: -72)
                                .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
                                .zIndex(2)
                            }

                            DownloadSaveControl(isSaving: isSaving) {
                                guard !isSaving else { return }
                                isSaving = true
                                onSave(defaultOption.destination)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } onShowOptions: {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                withAnimation(.spring(response: 0.28)) { showSaveMenu = true }
                            }
                        }
                        Spacer()
                    }
                    .padding(.leading, 28)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 16) + 28)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

struct DownloadSaveControl: View {
    let isSaving: Bool
    let onQuickSave: () -> Void
    let onShowOptions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: isSaving ? "checkmark" : "arrow.down.to.line")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isSaving else { return }
                    onQuickSave()
                }
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard !isSaving else { return }
                    onShowOptions()
                }

            Text("Hold for save options")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }
}

struct FlashSettingsPanel: View {
    @ObservedObject var model: CameraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Flash")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            HStack(spacing: 20) {
                ForEach(FrontFlashStyle.allCases) { style in
                    Button {
                        model.setFrontFlashStyle(style)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 4) {
                            Text(style.rawValue)
                                .font(.subheadline.weight(model.frontFlashStyle == style ? .bold : .regular))
                                .foregroundColor(model.frontFlashStyle == style ? .yellow : .gray)
                            Rectangle()
                                .fill(model.frontFlashStyle == style ? Color.yellow : Color.clear)
                                .frame(height: 2)
                        }
                    }
                }
            }

            if model.frontFlashStyle == .ring {
                HStack(spacing: 16) {
                    ForEach(RingLightShade.allCases) { shade in
                        Button {
                            model.selectRingLightShade(shade)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Circle()
                                .fill(shade.swiftUIColor)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            model.ringLightShade == shade ? Color.white : Color.white.opacity(0.35),
                                            lineWidth: model.ringLightShade == shade ? 2.5 : 1
                                        )
                                )
                        }
                    }
                }

                Slider(value: $model.ringLightIntensity, in: 0.45...1.0)
                    .tint(.white)
                    .onChange(of: model.ringLightIntensity) { _, _ in
                        model.updateRingLightIntensity()
                    }
            }
        }
        .padding(16)
        .frame(width: 220)
        .background(Color(white: 0.15).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SaveDestinationMenu: View {
    let onSelect: (SaveDestinationOption) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SaveDestinationOption.allCases) { option in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelect(option)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.body.bold())
                        Text(option.rawValue)
                            .font(.caption2.bold())
                    }
                    .foregroundColor(.white)
                    .frame(width: 88, height: 64)
                }
            }
        }
        .background(Color.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Gallery
struct GalleryView: View {
    let lastMedia: CapturedMedia?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CapturedMedia] = []
    @State private var selectedMedia: CapturedMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                            .foregroundColor(.white.opacity(0.4))
                        Text("No memories yet")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Saved photos and videos will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(items) { item in
                                GalleryCell(media: item) {
                                    selectedMedia = item
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Memories")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            items = MediaStorageService.shared.loadAll()
        }
        .fullScreenCover(item: $selectedMedia) { media in
            MemoryDetailView(media: media)
        }
    }
}

struct GalleryCell: View {
    let media: CapturedMedia
    let onTap: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                } else {
                    Color(white: 0.15)
                        .aspectRatio(1, contentMode: .fill)
                        .overlay {
                            ProgressView()
                                .tint(.white.opacity(0.6))
                                .scaleEffect(0.8)
                        }
                }

                if media.isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                            Spacer()
                        }
                        .padding(8)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: media.id) {
            let size = MediaStorageService.gridThumbnailPixelSize()
            let thumb = await Task.detached(priority: .userInitiated) {
                MediaStorageService.shared.thumbnail(for: media, size: size)
            }.value
            thumbnail = thumb
        }
    }
}

struct MemoryDetailView: View {
    let media: CapturedMedia
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if media.isVideo {
                    VideoPreviewPlayer(url: media.fileURL)
                        .ignoresSafeArea()
                } else if let fullImage {
                    Image(uiImage: fullImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                }

                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.top, geo.safeAreaInsets.top + 12)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task(id: media.id) {
            guard !media.isVideo else { return }
            fullImage = await Task.detached(priority: .userInitiated) {
                MediaStorageService.shared.fullImage(for: media)
            }.value
        }
    }
}

struct GalleryThumbnailView: View {
    let media: CapturedMedia?
    @State private var thumbnail: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.white, lineWidth: 2)
            .frame(width: 42, height: 42)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .task(id: media?.id) {
                guard let media else {
                    thumbnail = nil
                    return
                }
                let size = CGSize(width: 84 * UIScreen.main.scale, height: 84 * UIScreen.main.scale)
                thumbnail = await Task.detached(priority: .utility) {
                    MediaStorageService.shared.thumbnail(for: media, size: size)
                }.value
            }
    }
}

// MARK: - Overlays
struct GridOverlayView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct RingLightOverlay: View {
    let shade: RingLightShade
    let intensity: Double

    var body: some View {
        GeometryReader { geo in
            let minSide = min(geo.size.width, geo.size.height)
            let lineWidth = min(38, max(22, minSide * (0.045 + intensity * 0.01)))
            let white = Color.white.opacity(0.82 + intensity * 0.14)
            let tint = shade.swiftUIColor.opacity(0.28 + intensity * 0.22)

            ZStack {
                RadialGradient(
                    colors: [
                        Color.clear,
                        tint.opacity(0.35),
                        white.opacity(0.5)
                    ],
                    center: .center,
                    startRadius: minSide * 0.28,
                    endRadius: minSide * 0.72
                )

                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(tint, lineWidth: lineWidth)
                    .blur(radius: lineWidth * 0.32)

                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(
                        LinearGradient(
                            colors: [white, tint, white],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: lineWidth * 0.82
                    )
                    .blur(radius: lineWidth * 0.06)
            }
        }
        .allowsHitTesting(false)
    }
}

struct CountdownOverlay: View {
    let value: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            Text("\(value)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(radius: 8)
                .transition(.scale.combined(with: .opacity))
                .id(value)
        }
    }
}

struct CameraStatusOverlay: View {
    let message: String
    var onDemoPhoto: ((Data) -> Void)? = nil

    @State private var pickedItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            #if targetEnvironment(simulator)
            if let onDemoPhoto {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Import Photo to Demo", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .onChange(of: pickedItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            await MainActor.run { onDemoPhoto(data) }
                        }
                    }
                }
            }
            #endif
        }
        .foregroundColor(.white)
        .padding(24)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}

// MARK: - Reusable Controls
struct ControlButton: View {
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(isActive ? .yellow : .white)
                .shadow(color: .black.opacity(0.4), radius: 2)
        }
    }
}

struct SidebarButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(isActive ? .yellow : .white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Port-specific Preview (dual camera + single)
struct PortPreviewView: UIViewRepresentable {
    @ObservedObject var model: CameraViewModel
    let inputPort: AVCaptureInput.Port?
    var mirrorVideo: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        bindIfNeeded(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        bindIfNeeded(view: uiView, coordinator: context.coordinator)
    }

    private func bindIfNeeded(view: PreviewUIView, coordinator: Coordinator) {
        guard !model.isReconfiguringSession else { return }
        let portKey = inputPort.map { ObjectIdentifier($0).hashValue } ?? 0
        let key = "\(model.previewSessionID.uuidString)-\(portKey)-\(mirrorVideo)"
        guard coordinator.bindingKey != key else { return }
        coordinator.bindingKey = key
        model.bindPreviewLayer(view.previewLayer, inputPort: inputPort, mirrorVideo: mirrorVideo)
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: Coordinator) {
        coordinator.bindingKey = nil
    }

    final class Coordinator {
        var bindingKey: String?
    }
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Video Preview Player
struct VideoPreviewPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.player?.play()
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: controller.player?.currentItem,
            queue: .main
        ) { _ in
            controller.player?.seek(to: .zero)
            controller.player?.play()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}