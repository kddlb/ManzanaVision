// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import AVKit
import SwiftUI

/// Hosts the engine's display layer. The layer is created once by the model
/// and must stay the same instance (Picture in Picture holds on to it).
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        view.layer = root
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Picture in Picture for a live sample-buffer layer
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var controller: AVPictureInPictureController?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.requiresLinearPlayback = true
        controller = c
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    // live TV: always playing, no seekable range
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
