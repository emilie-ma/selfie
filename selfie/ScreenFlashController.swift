import UIKit

/// Drives real screen brightness for front-facing ring flash (like Snapchat).
final class ScreenFlashController {
    static let shared = ScreenFlashController()

    private var savedBrightness: CGFloat?

    private init() {}

    func applyRingLight(intensity: Double) {
        DispatchQueue.main.async {
            if self.savedBrightness == nil {
                self.savedBrightness = UIScreen.main.brightness
            }
            // Map slider 0.45…1.0 → ~82%…100% screen brightness
            let normalized = max(0, min(1, (intensity - 0.45) / 0.55))
            UIScreen.main.brightness = 0.82 + normalized * 0.18
        }
    }

    func pulseCaptureFlash() {
        DispatchQueue.main.async {
            if self.savedBrightness == nil {
                self.savedBrightness = UIScreen.main.brightness
            }
            UIScreen.main.brightness = 1.0
        }
    }

    func restore() {
        DispatchQueue.main.async {
            guard let saved = self.savedBrightness else { return }
            UIScreen.main.brightness = saved
            self.savedBrightness = nil
        }
    }
}
