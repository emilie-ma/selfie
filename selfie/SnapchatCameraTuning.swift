import CoreGraphics

/// Tuning constants matched to Snapchat front-camera selfies (closer crop, soft skin, warm tone).
enum SnapchatCameraTuning {
    /// Subtle default front zoom — native FOV with a tiny bump (1.0 = widest).
    static let frontCameraZoomFactor: CGFloat = 1.05

    /// Center crop applied in post if capture still looks wider than Snap (safety net).
    static let postCaptureCropScale: CGFloat = 1.0

    /// Blend of edge-preserving smooth layer (0 = raw, 1 = full blur).
    static let skinSmoothBlend: CGFloat = 0.40

    /// Gaussian sigma for skin-softening layer.
    static let smoothBlurRadius: CGFloat = 2.6

    /// CINoiseReduction — lowers grit/grain from the sensor.
    static let noiseLevel: Float = 0.012
    static let noiseSharpness: Float = 0.32

    /// Warmer, slightly lifted tones (Snapchat indoor selfie look).
    static let saturation: Float = 1.05
    static let contrast: Float = 0.92
    static let brightness: Float = 0.035

    /// Neutral → target for CITemperatureAndTint (higher neutral K = warmer result).
    static let warmthNeutral: CGFloat = 6800
    static let warmthTarget: CGFloat = 6000

    /// Soft local contrast — reduces pore/texture emphasis.
    static let localContrastReduction: CGFloat = 0.22

    static let jpegQuality: CGFloat = 0.91

    /// Long-edge cap for Core Image beauty pass — avoids full 12MP+ buffer spikes.
    static let beautyProcessingLongEdge: CGFloat = 2048
}
