// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import IOKit
import IOKit.usb

/// Watches for the STK8096GP (10b8:1fa0) coming and going. Firmware upload
/// doesn't re-enumerate the stick, so opening it causes no events.
public final class DeviceMonitor: @unchecked Sendable {
    public enum Event: Sendable, Equatable { case arrived, removed }

    public static let vendorID = 0x10b8
    public static let productID = 0x1fa0

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "mzv.devicemonitor")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        queue.sync { start() }
    }

    deinit {
        for it in iterators { IOObjectRelease(it) }
        if let port { IONotificationPortDestroy(port) }
        continuation.finish()
    }

    /// Whether a stick is connected right now (not just the last event)
    public static var isPresent: Bool {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict[kUSBVendorID] = vendorID
        dict[kUSBProductID] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dict)
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    /// Returns once a stick is connected, checking the real state first so
    /// stale buffered events don't count
    public func waitForArrival() async {
        while !Task.isCancelled {
            if Self.isPresent { return }
            var it = events.makeAsyncIterator()
            guard let e = await it.next() else { return }
            if e == .arrived, Self.isPresent { return }
        }
    }

    private func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict[kUSBVendorID] = Self.vendorID
        dict[kUSBProductID] = Self.productID
        return dict
    }

    private func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for (type, event) in [(kIOFirstMatchNotification, Event.arrived), (kIOTerminatedNotification, Event.removed)] {
            var it: io_iterator_t = 0
            let callback: IOServiceMatchingCallback = event == .arrived
                ? { ctx, it in Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().drain(it, .arrived) }
                : { ctx, it in Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().drain(it, .removed) }
            IOServiceAddMatchingNotification(port, type, matching(), callback, ctx, &it)
            iterators.append(it)
            // arms the notification; for first-match it also reports a stick already plugged in
            drain(it, event)
        }
    }

    private func drain(_ it: io_iterator_t, _ event: Event) {
        var any = false
        while case let service = IOIteratorNext(it), service != 0 {
            IOObjectRelease(service)
            any = true
        }
        if any { continuation.yield(event) }
    }
}
