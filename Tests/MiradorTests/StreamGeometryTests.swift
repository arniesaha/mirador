import CoreGraphics
import Testing
@testable import Mirador

@Test func letterboxConfigurationCapturesUltrawideInto1920By810AndOutputs1080p() {
    let config = StreamConfiguration(outputWidth: 1920, outputHeight: 1080, scalingPolicy: .letterbox)
    let capture = config.captureSize(forDisplayWidth: 5120, height: 2160)
    let output = config.outputSize(forCaptureSize: capture)
    let rect = config.contentRect(forSourceSize: capture)

    #expect(capture == CGSize(width: 1920, height: 810))
    #expect(output == CGSize(width: 1920, height: 1080))
    #expect(rect == CGRect(x: 0, y: 135, width: 1920, height: 810))
}

@Test func nativeConfigurationKeepsBackwardsCompatibleAspectLimitedCapture() {
    let config = StreamConfiguration()
    let capture = config.captureSize(forDisplayWidth: 5120, height: 2160)

    #expect(capture == CGSize(width: 1920, height: 810))
    #expect(config.outputSize(forCaptureSize: capture) == capture)
    #expect(config.contentRect(forSourceSize: capture) == CGRect(origin: .zero, size: capture))
}

@Test func environmentConfigurationRequiresExplicitLetterboxPolicy() {
    let config = StreamConfiguration.configured(environment: [
        "MIRADOR_STREAM_WIDTH": "1920",
        "MIRADOR_STREAM_HEIGHT": "1080",
        "MIRADOR_SCALING_POLICY": "letterbox"
    ])

    #expect(config.outputWidth == 1920)
    #expect(config.outputHeight == 1080)
    #expect(config.scalingPolicy == .letterbox)
}

@Test func inputMappingReachesRightAndBottomEdges() throws {
    let bounds = CGRect(x: 100, y: 200, width: 5120, height: 2160)
    for config in [StreamConfiguration(), StreamConfiguration(outputWidth: 1920, outputHeight: 1080, scalingPolicy: .letterbox)] {
        let corner = try InputEvent(type: .pointerMove, x: 1, y: config.scalingPolicy == .letterbox ? 945.0 / 1080.0 : 1)
        let point = try #require(corner.point(in: bounds, streamConfiguration: config))
        #expect(point.x == bounds.maxX)
        #expect(point.y == bounds.maxY)
    }
}

@Test func letterboxInputMappingIgnoresBarsAndMapsContentToFullSource() throws {
    let config = StreamConfiguration(outputWidth: 1920, outputHeight: 1080, scalingPolicy: .letterbox)
    let bounds = CGRect(x: 100, y: 200, width: 5120, height: 2160)

    let topBar = try InputEvent(type: .pointerMove, x: 0.5, y: 0.10)
    #expect(topBar.point(in: bounds, streamConfiguration: config) == nil)

    let bottomBar = try InputEvent(type: .pointerMove, x: 0.5, y: 0.90)
    #expect(bottomBar.point(in: bounds, streamConfiguration: config) == nil)

    let topEdge = try InputEvent(type: .pointerMove, x: 0.5, y: 135.0 / 1080.0)
    let topEdgePoint = try #require(topEdge.point(in: bounds, streamConfiguration: config))
    #expect(topEdgePoint.x == 2660)
    #expect(topEdgePoint.y == 200)

    let bottomEdge = try InputEvent(type: .pointerMove, x: 0.5, y: 944.0 / 1080.0)
    let bottomEdgePoint = try #require(bottomEdge.point(in: bounds, streamConfiguration: config))
    #expect(bottomEdgePoint.x == 2660)
    #expect(bottomEdgePoint.y > 2357)
    #expect(bottomEdgePoint.y < 2360)
}
