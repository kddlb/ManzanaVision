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
final class PictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    private(set) var controller: AVPictureInPictureController?
    /// Told when Picture in Picture starts and stops (captions go into the picture meanwhile)
    var activeChanged: (Bool) -> Void = { _ in }
    private weak var layer: AVSampleBufferDisplayLayer?
    private var panelObserver: NSObjectProtocol?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.layer = layer
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.requiresLinearPlayback = true
        c.delegate = self
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

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        activeChanged(true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        followPanel()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ c: AVPictureInPictureController) {
        releaseLayer()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        releaseLayer()
        activeChanged(false)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        releaseLayer()
        activeChanged(false)
    }

    // MARK: - sizing
    //
    // macOS shows a sample-buffer layer in the PiP panel by mirroring it pixel
    // for pixel (a CALayerHost) without scaling it (FB22411168), so the panel
    // showed a crop of the in-window picture. While in PiP the layer takes the
    // panel's size instead, and the main window covers it with a placeholder.

    /// The panel's content view: AVKit's panel lives in our process
    private var panelContent: NSView? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("PIPPanel") }?.contentView
    }

    private func followPanel() {
        guard let content = panelContent else { return }
        resizeLayer(to: content.bounds.size)
        content.postsFrameChangedNotifications = true
        panelObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: content, queue: .main
        ) { [weak self, weak content] _ in
            MainActor.assumeIsolated {
                guard let self, let content else { return }
                self.resizeLayer(to: content.bounds.size)
            }
        }
    }

    private func resizeLayer(to size: CGSize) {
        guard let layer, size.width > 0, size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.autoresizingMask = []
        layer.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
    }

    private func releaseLayer() {
        if let panelObserver { NotificationCenter.default.removeObserver(panelObserver) }
        panelObserver = nil
        guard let layer, let parent = layer.superlayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = parent.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        CATransaction.commit()
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
