// SPDX-License-Identifier: GPL-2.0-only
import CoreImage
import CoreVideo
import Foundation
@testable import ManzanaPlayback
@testable import ManzanaStream
import Testing

/// Captions drawn into frames for Picture in Picture
@Suite struct CaptionBurnInTests {
    /// A 1920×1080 NV12 frame in four flat quadrants
    private func quadrants() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let frame = try #require(pb)
        CVPixelBufferLockBaseAddress(frame, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(frame, plane)
            let ph = CVPixelBufferGetHeightOfPlane(frame, plane), pw = CVPixelBufferGetWidthOfPlane(frame, plane)
            for y in 0..<ph {
                for x in 0..<pw {
                    let q = (x * 2 >= pw ? 1 : 0) + (y * 2 >= ph ? 2 : 0)
                    if plane == 0 {
                        base[y * bpr + x] = [60, 120, 180, 235][q]
                    } else {
                        base[y * bpr + x * 2] = [90, 160, 128, 128][q]
                        base[y * bpr + x * 2 + 1] = [200, 60, 128, 128][q]
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return frame
    }

    private func luma(_ pb: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x]
    }

    @Test func drawsTheBoxWhereTheBroadcasterPutIt() throws {
        let frame = try quadrants()
        var page = CaptionPage()
        page.lines = [CaptionLine(x: 237, y: 403, height: 24,
                                  runs: [CaptionRun(text: "PARA BRINDARLE UNA AYUDA", foreground: .white,
                                                    background: CaptionColor(0, 0, 0), fontSize: 24)], nextX: 0)]
        let out = try #require(CaptionBurnIn().composite(frame, page: page))
        #expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080)
        #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        // the picture is untouched away from the caption, in every quadrant
        for (x, y) in [(200, 200), (1700, 200), (200, 1000), (1700, 1000)] {
            #expect(abs(Int(luma(out, x: x, y: y)) - Int(luma(frame, x: x, y: y))) <= 3, "at \(x),\(y)")
        }
        // the black box starts at 237/960 across, 403/540 down (just inside its left edge, above the glyphs)
        #expect(luma(out, x: 480, y: 808) < 30)
        #expect(luma(frame, x: 480, y: 808) > 100)
    }

    @Test func nothingToDrawForABlankScreen() throws {
        #expect(CaptionBurnIn().composite(try quadrants(), page: CaptionPage()) == nil)
    }
}
