// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ManzanaStream

/// When a caption screen belongs on the program's timeline
struct CaptionClock {
    /// Caption PTS further than this from the video muxed alongside is
    /// taken to be on another clock
    var tolerance = 5.0
    private(set) var retimed = 0
    private var unwrap = TimestampUnwrapper()

    mutating func reset() {
        unwrap.reset()
    }

    /// The screen's time from its PTS, or, when the caption encoder stamps its
    /// own clock (Mega's runs ~4 h ahead of the video), the time of the
    /// pictures it was muxed next to. Invalid before there are any pictures
    /// or sound to check the PTS against.
    mutating func time(pts: UInt64?, muxedWith: CMTime) -> CMTime {
        let time = pts.map { CMTime(value: unwrap.unwrap($0), timescale: 90000) } ?? .invalid
        guard muxedWith.isValid else { return .invalid }
        guard !time.isValid || abs((time - muxedWith).seconds) > tolerance else { return time }
        retimed += 1
        return muxedWith
    }
}

/// Caption screens with the time each takes effect, for looking up by frame
/// time from the video queue
final class CaptionTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(time: CMTime, page: CaptionPage)] = []

    func append(_ page: CaptionPage, at time: CMTime) {
        lock.withLock {
            // keep it sorted; a screen can't take effect before the one it follows
            let t = entries.last.map { max($0.time, time) } ?? time
            entries.append((t, page))
            if entries.count > 256 { entries.removeFirst(entries.count - 256) }
        }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    /// The screen showing at `time` (frames come in order, so older ones are dropped)
    func page(at time: CMTime) -> CaptionPage? {
        lock.withLock {
            guard let i = entries.lastIndex(where: { $0.time <= time }) else { return nil }
            entries.removeFirst(i)
            return entries[0].page
        }
    }
}

/// Draws caption screens into video frames, for Picture in Picture, which
/// only shows the video layer. Looks like the app's overlay: the
/// broadcaster's positions and colours, scaled to the frame.
final class CaptionBurnIn {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType) = (0, 0, 0)
    private var cached: (page: CaptionPage, width: Int, height: Int, image: CIImage)?

    /// A copy of `frame` with the captions on it, or nil when there's nothing to draw
    func composite(_ frame: CVPixelBuffer, page: CaptionPage) -> CVPixelBuffer? {
        guard !page.isEmpty else { return nil }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        let overlay: CIImage
        if let c = cached, c.page == page, c.width == w, c.height == h {
            overlay = c.image
        } else {
            guard let image = Self.render(page, width: w, height: h) else { return nil }
            overlay = CIImage(cgImage: image)
            cached = (page, w, h, overlay)
        }
        guard let out = makeBuffer(like: frame) else { return nil }
        CVBufferPropagateAttachments(frame, out)
        let composed = overlay.composited(over: CIImage(cvPixelBuffer: frame))
        context.render(composed, to: out)
        return out
    }

    private func makeBuffer(like frame: CVPixelBuffer) -> CVPixelBuffer? {
        let key = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), CVPixelBufferGetPixelFormatType(frame))
        if pool == nil || poolKey != key {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: key.2,
                kCVPixelBufferWidthKey: key.0,
                kCVPixelBufferHeightKey: key.1,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolKey = key
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// The captions on a transparent image the size of the frame
    static func render(_ page: CaptionPage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // the plane maps onto the whole frame (also right for anamorphic pictures)
        let sx = CGFloat(width) / CGFloat(page.width), sy = CGFloat(height) / CGFloat(page.height)
        for line in page.lines where !line.text.allSatisfy(\.isWhitespace) {
            let fontSize = CGFloat(line.runs.map(\.fontSize).max() ?? 24) * sy * 0.9
            let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let text = NSMutableAttributedString()
            for run in line.runs {
                text.append(NSAttributedString(string: run.text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor(run.foreground),
                    kCTUnderlineStyleAttributeName as NSAttributedString.Key: run.underline ? CTUnderlineStyle.single.rawValue : 0,
                ]))
            }
            let ctLine = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            let top = CGFloat(line.y) * sy, boxHeight = CGFloat(line.height) * sy
            let background = line.runs[0].background
            let uniform = line.runs.allSatisfy { $0.background == background }
            let pad = uniform && background.alpha > 0 ? fontSize * 0.2 : 0
            let x = CGFloat(line.x) * sx
            // CoreGraphics counts up from the bottom
            let boxBottom = CGFloat(height) - top - boxHeight
            let baseline = boxBottom + (boxHeight - ascent - descent) / 2 + descent

            if uniform {
                if background.alpha > 0 {
                    ctx.setFillColor(cgColor(background))
                    ctx.fill(CGRect(x: x, y: boxBottom, width: textWidth + 2 * pad, height: boxHeight))
                }
            } else {
                var offset = 0
                for run in line.runs {
                    let length = run.text.utf16.count
                    let from = CTLineGetOffsetForStringIndex(ctLine, offset, nil)
                    let to = CTLineGetOffsetForStringIndex(ctLine, offset + length, nil)
                    offset += length
                    guard run.background.alpha > 0 else { continue }
                    ctx.setFillColor(cgColor(run.background))
                    ctx.fill(CGRect(x: x + from, y: boxBottom, width: to - from, height: boxHeight))
                }
            }
            ctx.saveGState()
            if background.alpha == 0 {
                // no box of its own: still stand out from the picture
                ctx.setShadow(offset: .zero, blur: 3 * sy, color: CGColor(gray: 0, alpha: 0.9))
            }
            ctx.textPosition = CGPoint(x: x + pad, y: baseline)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func cgColor(_ c: CaptionColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255,
                alpha: CGFloat(c.alpha) / 255)
    }
}
