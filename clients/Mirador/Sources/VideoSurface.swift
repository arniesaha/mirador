import SwiftUI
import AVFoundation

/// A UIView whose backing layer is an `AVSampleBufferDisplayLayer`, so decoded H.264 frames can
/// be enqueued straight onto it.
final class SampleBufferUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// SwiftUI wrapper that exposes the display layer to the session for enqueueing.
struct VideoSurface: UIViewRepresentable {
    let session: RemoteSession

    func makeUIView(context: Context) -> SampleBufferUIView {
        let view = SampleBufferUIView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        session.attach(displayLayer: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {}
}
