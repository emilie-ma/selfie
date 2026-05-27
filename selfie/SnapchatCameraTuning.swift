import CoreGraphics

/// Tuning for Snapchat-style front selfies — texture softening only, no color shift.
enum SnapchatCameraTuning {
    /// Subtle default front zoom — native FOV with a tiny bump (1.0 = widest).
    static let frontCameraZoomFactor: CGFloat = 1.05

    /// Center crop applied in post if capture still looks wider than Snap (safety net).
    static let postCaptureCropScale: CGFloat = 1.0

    /// How much fine skin texture to keep after smoothing (1 = original, ~0.55 = Snap-like soft).
    static let skinTextureRetention: CGFloat = 0.58

    /// Gaussian sigma for the low-frequency (smooth) layer in frequency separation.
    static let smoothBlurRadius: CGFloat = 2.0

    /// Very light sensor noise cleanup — keeps color neutral.
    static let noiseLevel: Float = 0.006
    static let noiseSharpness: Float = 0.40

    static let jpegQuality: CGFloat = 0.91

    /// Long-edge cap for Core Image beauty pass — avoids full 12MP+ buffer spikes.
    static let beautyProcessingLongEdge: CGFloat = 2048
}
