//
//  selfieTests.swift
//  selfieTests
//

import Testing
import UIKit
@testable import selfie

struct selfieTests {

    @Test func frontCameraZoomIsSubtle() {
        #expect(SnapchatCameraTuning.frontCameraZoomFactor >= 1.0)
        #expect(SnapchatCameraTuning.frontCameraZoomFactor <= 1.1)
    }

    @Test func beautyProcessingCapReducesMemoryFootprint() {
        #expect(SnapchatCameraTuning.beautyProcessingLongEdge <= 2048)
    }

    @Test func photoBeautyProcessorReturnsJPEG() {
        let size = CGSize(width: 400, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let input = image.jpegData(compressionQuality: 0.9) else {
            Issue.record("Could not create test JPEG")
            return
        }

        let output = PhotoBeautyProcessor.prepareSnapchatPhoto(
            from: input,
            isFrontCamera: true,
            applyMirrorFallback: false
        )
        #expect(!output.isEmpty)
        #expect(UIImage(data: output) != nil)
    }

    @Test func photoBeautyProcessorBackCameraSkipsBeauty() {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let input = image.jpegData(compressionQuality: 0.9) else { return }

        let output = PhotoBeautyProcessor.prepareSnapchatPhoto(
            from: input,
            isFrontCamera: false,
            applyMirrorFallback: false
        )
        #expect(!output.isEmpty)
    }

    @Test func saveDestinationOptionsAreComplete() {
        #expect(SaveDestinationOption.allCases.count == 3)
        #expect(SaveDestinationOption.both.destination == .both)
        #expect(SaveDestinationOption.appOnly.destination == .appOnly)
        #expect(SaveDestinationOption.cameraRollOnly.destination == .cameraRollOnly)
    }

    @Test func mediaStorageRoundTrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let size = CGSize(width: 100, height: 100)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }

        // MediaStorageService uses Documents/Selfies — appOnly write should succeed on device/sim.
        let media = await MediaStorageService.shared.savePhoto(data: data, destination: .appOnly)
        #expect(media != nil)
        if let media {
            #expect(FileManager.default.fileExists(atPath: media.fileURL.path))
        }
    }
}
