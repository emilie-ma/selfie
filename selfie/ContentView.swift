import SwiftUI
import AVFoundation
import AVKit
import UIKit
import PhotosUI

// MARK: - Root View
struct ContentView: View {
    @StateObject private var cameraModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showGallery = false
    @AppStorage("defaultSaveOption") private var defaultSaveOptionRaw = SaveDestinationOption.both.rawValue

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                .onTapGesture(count: 2) { cameraModel.flipCamera() }
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    cameraModel.focus(at: location)
                }

            if cameraModel.showGrid {
                GridOverlayView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if cameraModel.ringLightEnabled,
               cameraModel.isUsingFrontCamera,
               cameraModel.frontFlashStyle == .ring {
                RingLightOverlay(
                    shade: cameraModel.ringLightShade,
                    intensity: cameraModel.ringLightIntensity
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if cameraModel.showScreenFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let countdown = cameraModel.countdownValue {
                CountdownOverlay(value: countdown)
            }

            if let message = cameraModel.cameraStatusMessage, cameraModel.pendingPreview == nil {
                CameraStatusOverlay(message: message) { data in
                    cameraModel.loadDemoPhoto(data: data)
                }
            }

            if cameraModel.pendingPreview == nil {
                VStack(spacing: 0) {
                    TopBarView(model: cameraModel)
                    Spacer()
                    BottomBarView(model: cameraModel, showGallery: $showGallery)
                }

                if cameraModel.showFlashSettingsPanel && cameraModel.isUsingFrontCamera {
                    FlashSettingsPanel(model: cameraModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 88)
                        .padding(.trailing, 58)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(20)
                }

                HStack {
                    Spacer()
                    RightSidebarView(model: cameraModel)
                        .padding(.trailing, 12)
                }
            }

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

            if let pending = cameraModel.pendingPreview {
                CapturePreviewView(
                    pending: pending,
                    defaultSaveOptionRaw: $defaultSaveOptionRaw,
                    onSave: { destination in
                        Task { await cameraModel.savePendingCapture(to: destination) }
                    },
                    onDiscard: { cameraModel.discardPendingCapture() }
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                cameraModel.requestPermissions()
            case .background:
                ScreenFlashController.shared.restore()
                cameraModel.teardownCaptureResources()
            default:
                break
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
                ProgressView().tint(.white).scaleEffect(1.2)
            } else if model.dualCameraEnabled, model.backCameraPort != nil {
                PortPreviewView(
                    model: model,
                    inputPort: model.backCameraPort,
                    mirrorVideo: false
                )
                .id(model.previewSessionID)

                if model.frontCameraPort != nil {
                    VStack {
                        HStack {
                            PortPreviewView(
                                model: model,
                                inputPort: model.frontCameraPort,
                                mirrorVideo: true
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
            Spacer()
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
            Spacer()
                .frame(height: 80)

            // Timer
            SidebarButton(icon: model.timerIcon, label: "Timer", isActive: model.timerMode != .off) {
                model.cycleTimer()
            }

            // Grid
            SidebarButton(icon: "grid", label: "Grid", isActive: model.showGrid) {
                model.toggleGrid()
            }

            Button {
                model.toggleFlashSettingsPanel()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: model.flashIcon)
                        .font(.system(size: 22))
                        .foregroundColor(model.isFlashActive ? .yellow : .white)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.bottom, 4)

            // Dual camera
            if model.supportsDualCamera {
                SidebarButton(icon: "camera.on.rectangle.fill", label: "Dual", isActive: model.dualCameraEnabled) {
                    model.toggleDualCamera()
                }
            }

            Spacer()
                .frame(height: 200)
        }
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
                .disabled(model.dualCameraEnabled)
                .opacity(model.dualCameraEnabled ? 0.4 : 1)
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

            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: shutterSize, height: shutterSize)

            RoundedRectangle(cornerRadius: model.isRecording ? 8 : shutterSize / 2)
                .fill(model.isRecording ? Color.red : Color.white)
                .frame(
                    width: model.isRecording ? 36 : 64,
                    height: model.isRecording ? 36 : 64
                )
                .animation(.spring(response: 0.25), value: model.isRecording)

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

                    if model.isRecordingLocked {
                        return
                    }

                    if didStartHoldRecording || model.isRecording {
                        if model.isRecording {
                            model.stopVideoRecording()
                        }
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

                VStack {
                    HStack {
                        Button(action: onDiscard) {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, max(geo.safeAreaInsets.top, 12) + 16)

                    Spacer()

                    SaveDestinationButton(
                        defaultOption: defaultOption,
                        isSaving: isSaving,
                        showSaveMenu: $showSaveMenu,
                        onSave: { destination in
                            guard !isSaving else { return }
                            isSaving = true
                            defaultSaveOptionRaw = destination.rawValue
                            onSave(destination.destination)
                        }
                    )
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 16) + 28)
                }

                if showSaveMenu {
                    SaveDestinationMenu(
                        selectedRaw: $defaultSaveOptionRaw,
                        isSaving: isSaving,
                        onSelect: { option in
                            guard !isSaving else { return }
                            isSaving = true
                            defaultSaveOptionRaw = option.rawValue
                            showSaveMenu = false
                            onSave(option.destination)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 16) + 90)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SaveDestinationButton: View {
    let defaultOption: SaveDestinationOption
    let isSaving: Bool
    @Binding var showSaveMenu: Bool
    let onSave: (SaveDestinationOption) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard !isSaving else { return }
                onSave(defaultOption)
            } label: {
                Image(systemName: isSaving ? "checkmark" : "arrow.down.to.line")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }

            Button {
                withAnimation(.spring(response: 0.28)) { showSaveMenu.toggle() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}

struct SaveDestinationMenu: View {
    @Binding var selectedRaw: String
    let isSaving: Bool
    let onSelect: (SaveDestinationOption) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(SaveDestinationOption.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack {
                        Image(systemName: option.icon)
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if selectedRaw == option.rawValue {
                            Image(systemName: "checkmark")
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Gallery
struct GalleryView: View {
    let lastMedia: CapturedMedia?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CapturedMedia] = []

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { item in
                        GalleryCell(media: item)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            items = MediaStorageService.shared.loadAll()
        }
    }
}

struct GalleryCell: View {
    let media: CapturedMedia
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Color.gray.opacity(0.3)
                    .aspectRatio(1, contentMode: .fill)
            }

            if media.isVideo {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .onAppear {
            thumbnail = MediaStorageService.shared.thumbnail(for: media)
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
            .onAppear {
                if let media {
                    thumbnail = MediaStorageService.shared.thumbnail(for: media)
                }
            }
            .onChange(of: media?.id) { _, _ in
                if let media {
                    thumbnail = MediaStorageService.shared.thumbnail(for: media)
                }
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
            let tint = shade.swiftUIColor
            let glowStrength = 0.12 + intensity * 0.18

            ZStack {
                RadialGradient(
                    colors: [
                        Color.clear,
                        tint.opacity(glowStrength * 0.5),
                        Color.white.opacity(glowStrength)
                    ],
                    center: .center,
                    startRadius: geo.size.width * 0.25,
                    endRadius: geo.size.width * 0.75
                )

                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.9),
                                tint.opacity(0.4),
                                Color.white.opacity(0.9)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 28
                    )
                    .blur(radius: 12)
            }
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
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            #if targetEnvironment(simulator)
            if let onDemoPhoto {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Text("Import test photo")
                        .font(.subheadline.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .onChange(of: pickedItem) { _, item in
                    Task {
                        guard let item,
                              let data = try? await item.loadTransferable(type: Data.self) else { return }
                        await MainActor.run { onDemoPhoto(data) }
                    }
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
    }
}

struct FlashSettingsPanel: View {
    @ObservedObject var model: CameraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ring Light")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 8) {
                ForEach(RingLightShade.allCases) { shade in
                    Button { model.selectRingLightShade(shade) } label: {
                        Circle()
                            .fill(shade.swiftUIColor)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .stroke(
                                        model.ringLightShade == shade ? Color.yellow : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                }
            }

            Slider(
                value: Binding(
                    get: { model.ringLightIntensity },
                    set: { model.ringLightIntensity = $0; model.updateRingLightIntensity() }
                ),
                in: 0.45...1.0
            )
            .tint(.yellow)

            Divider().background(Color.white.opacity(0.2))

            ForEach(FrontFlashStyle.allCases) { style in
                Button { model.setFrontFlashStyle(style) } label: {
                    HStack {
                        Text(style.rawValue)
                            .font(.subheadline.weight(model.frontFlashStyle == style ? .bold : .regular))
                            .foregroundColor(.white)
                        Spacer()
                        if model.frontFlashStyle == style {
                            Image(systemName: "checkmark")
                                .foregroundColor(.yellow)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 200)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewUIView {
        context.coordinator.model = model
        let view = PreviewUIView()
        bindIfNeeded(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.model = model
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
        coordinator.model?.unbindPreviewLayer(uiView.previewLayer)
    }

    final class Coordinator {
        var bindingKey: String?
        weak var model: CameraViewModel?
    }
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Video Preview Player
struct VideoPreviewPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        player.play()

        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        if let observer = coordinator.endObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.endObserver = nil
        }
        uiViewController.player?.pause()
        uiViewController.player = nil
    }

    final class Coordinator {
        var endObserver: NSObjectProtocol?
    }
}
