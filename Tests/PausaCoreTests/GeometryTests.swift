import Testing
import Foundation
import CoreGraphics
@testable import PausaCore

struct GeometryTests {
    @Test func draggingTracksDesktopPointerWithoutAccumulatingWindowMovement() {
        let canvas = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let initial = CGRect(x: -1400, y: 400, width: 240, height: 150)
        let start = CGPoint(x: -1300, y: 470)
        for offset in stride(from: 0, through: 300, by: 5) {
            let rect = Geometry.draggedCameraRect(initial: initial, pointerStart: start,
                                                  pointerNow: CGPoint(x: start.x + CGFloat(offset), y: start.y + 40), inside: canvas)
            #expect(rect.minX == initial.minX + CGFloat(offset))
            #expect(rect.minY == initial.minY + 40)
            #expect(rect.size == initial.size)
        }
        #expect(Geometry.draggedCameraRect(initial: initial, pointerStart: start, pointerNow: start, inside: canvas) == initial)
    }
    @Test func dragClampingAndSavedPositionMatchForEveryCameraShape() {
        let canvas = CGRect(x: -1600, y: -900, width: 1600, height: 1000)
        for shape in CameraShape.allCases {
            var p = Preferences(); p.shape = shape
            let initial = Geometry.cameraRect(in: canvas.size, preferences: p).offsetBy(dx: canvas.minX, dy: canvas.minY)
            let rect = Geometry.draggedCameraRect(initial: initial, pointerStart: .zero,
                                                  pointerNow: CGPoint(x: -5000, y: 5000), inside: canvas)
            #expect(canvas.contains(rect))
            #expect(rect.minX == canvas.minX)
            #expect(abs(rect.maxY - canvas.maxY) < 0.0001)
            p.anchor = .custom; p.customX = (rect.midX - canvas.minX) / canvas.width
            p.customY = (rect.midY - canvas.minY) / canvas.height
            let restored = Geometry.cameraRect(in: canvas.size, preferences: p).offsetBy(dx: canvas.minX, dy: canvas.minY)
            #expect(abs(restored.minX - rect.minX) < 0.0001)
            #expect(abs(restored.minY - rect.minY) < 0.0001)
        }
    }
    @Test func lifeSizePreviewUsesFullDisplayIncludingMenuBarAndDock() {
        let display = CGRect(x: -1920, y: 100, width: 1920, height: 1200)
        let canvas = Geometry.desktopCanvas(videoSize: CGSize(width: 3840, height: 2400), sourceFrame: display)
        #expect(canvas == display)
        let webcam = Geometry.cameraRect(in: canvas.size, preferences: Preferences())
        #expect(abs(webcam.width - 384) < 0.0001)
        #expect(abs(webcam.minX - 1506) < 0.0001)
        #expect(abs(webcam.minY - 30) < 0.0001)
    }
    @Test func lifeSizePreviewInvertsLetterboxingInsteadOfShrinkingTheCanvas() {
        let source = CGRect(x: 350, y: 120, width: 800, height: 600)
        let canvas = Geometry.desktopCanvas(videoSize: CGSize(width: 1920, height: 1080), sourceFrame: source)
        #expect(abs(canvas.width - 1066.6666667) < 0.0001)
        #expect(abs(canvas.minX - 216.6666667) < 0.0001)
        #expect(canvas.height == 600)
        #expect(canvas.minY == 120)
    }
    @Test func windowCoordinatesRespectDisplaysAboveAndLeftOfPrimary() {
        let window = CGRect(x: -1600, y: -900, width: 1000, height: 700)
        let desktop = Geometry.desktopRect(from: window, desktopTop: 1080)
        #expect(desktop == CGRect(x: -1600, y: 1280, width: 1000, height: 700))
    }
    @Test func testCanvasKeepsAspectAndEvenEncoderDimensions() {
        let size = Geometry.canvas(source: CGSize(width: 3024, height: 1964), maxHeight: 1080)
        #expect(size.height == 1080)
        #expect(Int(size.width) % 2 == 0)
        #expect(abs(size.width / size.height - 3024.0 / 1964) < 0.002)
    }
    @Test func testSmallSourcesAreNotUpscaled() {
        #expect(Geometry.canvas(source: CGSize(width: 640, height: 480), maxHeight: 1080) == CGSize(width: 640, height: 480))
    }
    @Test func testPortraitSourceFitsLandscapeWithoutStretching() {
        let fit = Geometry.fit(CGSize(width: 900, height: 1600), inside: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(fit.height == 1080)
        #expect(fit.width == 607.5)
        #expect(fit.midX == 960)
    }
    @Test func testEveryCameraPositionStaysInsideCanvas() {
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 400, height: 1200)] {
            for shape in CameraShape.allCases {
                for anchor in Anchor.allCases {
                    var p = Preferences(); p.shape = shape; p.anchor = anchor; p.cameraSize = 0.45
                    p.customX = 1; p.customY = 0
                    let rect = Geometry.cameraRect(in: canvas, preferences: p)
                    #expect(CGRect(origin: .zero, size: canvas).contains(rect))
                }
            }
        }
    }
    @Test func testSanitizationProtectsEncoderAndCoordinates() {
        var p = Preferences(); p.fps = 0; p.resolution = -1; p.cameraSize = .nan; p.bitRateMbps = -100
        p.countdown = 200; p.customX = -1
        let fixed = p.sanitized()
        #expect(fixed.fps == 30); #expect(fixed.resolution == 1080)
        #expect(fixed.cameraSize == 0.20); #expect(fixed.bitRateMbps == 2)
        #expect(fixed.countdown == 15); #expect(fixed.customX == 0)
    }
    @Test func testPreferencesRoundTripKeepsIndependentPreviewAndRecordingChoices() throws {
        var p = Preferences(); p.camera = true; p.showPreview = false; p.systemAudio = true; p.microphone = false
        let roundtrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        #expect(p == roundtrip)
    }
}
