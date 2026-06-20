import Foundation
import Testing
@testable import Mirador

@Test func streamFrameSelectionRepeatsLastRealFrameInsteadOfPlaceholder() {
    let previous = Data("real-frame".utf8)
    let selected = HTTPServer.jpegForStream(nextFrame: nil, previousFrame: previous)

    #expect(selected.jpeg == previous)
    #expect(selected.previousFrame == previous)
}

@Test func streamFrameSelectionUsesPlaceholderOnlyBeforeFirstRealFrame() {
    let selected = HTTPServer.jpegForStream(nextFrame: nil, previousFrame: nil)

    #expect(selected.jpeg == HTTPServer.syntheticJPEG)
    #expect(selected.previousFrame == nil)
}

@Test func streamFrameSelectionStoresNewestRealFrame() {
    let next = Data("new-real-frame".utf8)
    let selected = HTTPServer.jpegForStream(nextFrame: next, previousFrame: Data("old".utf8))

    #expect(selected.jpeg == next)
    #expect(selected.previousFrame == next)
}
