// SPDX-License-Identifier: GPL-2.0-only
import CLibUSB
import ManzanaCore

let usb = libusb_get_version().pointee
print("ManzanaCore \(String(cString: mzv_version())), libusb \(usb.major).\(usb.minor).\(usb.micro)")
