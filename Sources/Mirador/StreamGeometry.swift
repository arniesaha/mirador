import CoreGraphics
import Foundation

public enum StreamScalingPolicy: String, Equatable, Sendable {
    case native
    case letterbox
}

public struct StreamConfiguration: Equatable, Sendable {
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let scalingPolicy: StreamScalingPolicy

    public init(outputWidth: Int? = nil, outputHeight: Int? = nil, scalingPolicy: StreamScalingPolicy = .native) {
        self.outputWidth = outputWidth.flatMap { $0 > 0 ? $0 : nil }
        self.outputHeight = outputHeight.flatMap { $0 > 0 ? $0 : nil }
        self.scalingPolicy = scalingPolicy
    }

    public static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> StreamConfiguration {
        let width = positiveInt(environment["MIRADOR_STREAM_WIDTH"])
        let height = positiveInt(environment["MIRADOR_STREAM_HEIGHT"])
        let rawPolicy = environment["MIRADOR_SCALING_POLICY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let policy = rawPolicy.flatMap(StreamScalingPolicy.init(rawValue:)) ?? .native
        return StreamConfiguration(outputWidth: width, outputHeight: height, scalingPolicy: policy)
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    public var hasFixedOutputSize: Bool { outputWidth != nil && outputHeight != nil }

    public func captureSize(forDisplayWidth displayWidth: Int, height displayHeight: Int, maxNativeWidth: Int = 1920) -> CGSize {
        let source = CGSize(width: max(1, displayWidth), height: max(1, displayHeight))
        if scalingPolicy == .letterbox, let output = fixedOutputSize {
            let rect = Self.aspectFitRect(sourceSize: source, in: CGRect(origin: .zero, size: output))
            return CGSize(width: max(1, Int(rect.width.rounded())), height: max(1, Int(rect.height.rounded())))
        }
        if displayWidth > maxNativeWidth {
            return CGSize(width: maxNativeWidth, height: max(1, Int(Double(displayHeight) * Double(maxNativeWidth) / Double(displayWidth))))
        }
        return source
    }

    public func outputSize(forCaptureSize captureSize: CGSize) -> CGSize {
        if scalingPolicy == .letterbox, let output = fixedOutputSize { return output }
        return captureSize
    }

    public func contentRect(forSourceSize sourceSize: CGSize) -> CGRect {
        let output = outputSize(forCaptureSize: sourceSize)
        guard scalingPolicy == .letterbox, fixedOutputSize != nil else {
            return CGRect(origin: .zero, size: output)
        }
        return Self.aspectFitRect(sourceSize: sourceSize, in: CGRect(origin: .zero, size: output)).integral
    }

    public func sourceNormalizedPoint(fromOutputNormalized point: CGPoint, sourceSize: CGSize) -> CGPoint? {
        let output = outputSize(forCaptureSize: sourceSize)
        let px = CGPoint(x: point.x * output.width, y: point.y * output.height)
        let content = contentRect(forSourceSize: sourceSize)
        // Inclusive on every edge: clients clamp the cursor to exactly 1.0 at the right/bottom
        // edge, and CGRect.contains would drop it.
        guard content.width > 0, content.height > 0,
              px.x >= content.minX, px.x <= content.maxX,
              px.y >= content.minY, px.y <= content.maxY else { return nil }
        return CGPoint(x: (px.x - content.minX) / content.width, y: (px.y - content.minY) / content.height)
    }

    public var fixedOutputSize: CGSize? {
        guard let outputWidth, let outputHeight else { return nil }
        return CGSize(width: outputWidth, height: outputHeight)
    }

    static func aspectFitRect(sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return CGRect(x: bounds.minX + (bounds.width - width) / 2,
                      y: bounds.minY + (bounds.height - height) / 2,
                      width: width,
                      height: height)
    }
}
