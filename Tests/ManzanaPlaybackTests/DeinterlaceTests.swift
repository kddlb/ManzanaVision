// SPDX-License-Identifier: GPL-2.0-only
import CoreVideo
import Foundation
@testable import ManzanaPlayback
import Testing

/// NV12 test frames: luma from a closure (0...255), flat chroma
func frame(_ w: Int = 256, _ h: Int = 128, chroma: (UInt8, UInt8) = (128, 128),
           luma: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
    for r in 0..<h { for c in 0..<w { y[r * ys + c] = luma(c, r) } }
    let uv = CVPixelBufferGetBaseAddressOfPlane(p, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvs = CVPixelBufferGetBytesPerRowOfPlane(p, 1)
    for r in 0..<h / 2 { for c in 0..<w / 2 { uv[r * uvs + 2 * c] = chroma.0; uv[r * uvs + 2 * c + 1] = chroma.1 } }
    CVPixelBufferUnlockBaseAddress(p, [])
    return p
}

func lumaRows(_ p: CVPixelBuffer) -> [[Int]] {
    CVPixelBufferLockBaseAddress(p, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
    let w = CVPixelBufferGetWidth(p), h = CVPixelBufferGetHeight(p)
    let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
    let s = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
    return (0..<h).map { r in (0..<w).map { Int(y[r * s + $0]) } }
}

/// Mean |line - average of its neighbours|: high for combed images
func combing(_ rows: [[Int]]) -> Double {
    var sum = 0, n = 0
    for r in 1..<(rows.count - 1) {
        for c in 0..<rows[r].count {
            sum += abs(2 * rows[r][c] - rows[r - 1][c] - rows[r + 1][c])
            n += 1
        }
    }
    return Double(sum) / Double(2 * n)
}

@Suite struct DeinterlaceKernels {
    let d: Deinterlacer

    init() throws { d = try Deinterlacer() }

    @Test func staticDetailSurvivesYADIF() throws {
        // 2-on/2-off horizontal stripes: detail finer than a field can carry alone
        let still = frame { _, r in (r / 2) % 2 == 0 ? 220 : 30 }
        for first in [true, false] {
            let yadif = lumaRows(try d.field(prev: still, cur: still, next: still, first: first, topFieldFirst: true, mode: .yadif))
            let bob = lumaRows(try d.field(prev: still, cur: still, next: still, first: first, topFieldFirst: true, mode: .bob))
            let orig = lumaRows(still)
            let yadifErr = zip(yadif, orig).map { zip($0, $1).map { abs($0 - $1) }.max()! }.max()!
            let bobErr = zip(bob, orig).map { zip($0, $1).map { abs($0 - $1) }.max()! }.max()!
            #expect(yadifErr <= 1, "YADIF should weave static content (err \(yadifErr))")
            #expect(bobErr > 50, "bob can't recover the missing field's detail (err \(bobErr))")
        }
    }

    @Test func motionIsNotCombed() throws {
        // a bright bar moving right 4 px per field: top field at t, bottom at t + ½
        func weave(_ n: Int) -> CVPixelBuffer {
            frame { c, r in
                let x0 = 40 + 8 * n + (r % 2 == 0 ? 0 : 4)
                return (x0..<(x0 + 24)).contains(c) ? 235 : 16
            }
        }
        let prev = weave(0), cur = weave(1), next = weave(2)
        let input = combing(lumaRows(cur))
        for mode in [DeinterlaceMode.yadif, .bob] {
            for first in [true, false] {
                let out = combing(lumaRows(try d.field(prev: prev, cur: cur, next: next, first: first,
                                                       topFieldFirst: true, mode: mode)))
                #expect(out < input / 4, "\(mode) field \(first ? 1 : 2): combing \(out) vs input \(input)")
            }
        }
    }

    @Test func chromaAndSizeArePreserved() throws {
        let f = frame(chroma: (90, 200)) { c, _ in UInt8(c % 256) }
        let out = try d.field(prev: f, cur: f, next: f, first: true, topFieldFirst: true, mode: .yadif)
        #expect(CVPixelBufferGetWidth(out) == 256 && CVPixelBufferGetHeight(out) == 128)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self)
        #expect(abs(Int(uv[0]) - 90) <= 1 && abs(Int(uv[1]) - 200) <= 1)
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
        let fc = CVBufferCopyAttachment(out, kCVImageBufferFieldCountKey, nil) as? NSNumber
        #expect(fc?.intValue == 1)
    }

    @Test func fullHDFieldIsFast() throws {
        let f = frame(1920, 1080) { c, r in UInt8((c + r) & 0xff) }
        var times: [Double] = []
        for i in 0..<20 {
            _ = try d.field(prev: f, cur: f, next: f, first: i % 2 == 0, topFieldFirst: true, mode: .yadif)
            if i >= 4 { times.append(d.lastGPUTime) }  // skip warm-up
        }
        let avg = times.reduce(0, +) / Double(times.count) * 1000
        print("DEINTERLACE 1080 field GPU time: \(String(format: "%.2f", avg)) ms")
        #expect(avg < 3, "GPU time per field \(avg) ms")
    }
}
