// SPDX-License-Identifier: GPL-2.0-only
import CryptoKit
import Foundation

/// Finds the DiB0700 bridge firmware. It ships with the app (DiBcom allows
/// redistribution, see firmware/LICENSE.dib0700); a copy in Application
/// Support or $MANZANA_FIRMWARE overrides it.
public enum FirmwareStore {
    public static let fileName = "dvb-usb-dib0700-1.20.fw"
    public static let sha1 = "415bd83150ebca3ed3ba8c1f74bf0b6a8a225c01"

    public static var overrideURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManzanaVision/firmware/\(fileName)")
    }

    /// Places searched, in order
    public static func candidates(bundle: Bundle = .main) -> [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MANZANA_FIRMWARE"], !env.isEmpty {
            urls.append(URL(fileURLWithPath: env))
        }
        urls.append(overrideURL)
        if let bundled = bundle.url(forResource: fileName, withExtension: nil) { urls.append(bundled) }
        // development: running from the repository
        urls.append(URL(fileURLWithPath: "firmware/\(fileName)"))
        return urls
    }

    /// The first candidate that exists and matches the known checksum
    public static func locate(bundle: Bundle = .main) throws(TunerError) -> URL {
        var found = false
        for url in candidates(bundle: bundle) {
            guard let data = try? Data(contentsOf: url) else { continue }
            found = true
            if verify(data) { return url }
        }
        throw .firmware(found ? "firmware file doesn't match the expected checksum" : "firmware file not found")
    }

    public static func verify(_ data: Data) -> Bool {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha1
    }
}
