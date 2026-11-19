//
//  NetworkInfo.swift
//  iPad Graphic Tablet — Mac
//
//  Indirizzi IPv4 del Mac (per l'IP da digitare sull'iPad) e QR code.
//

import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum NetworkInfo {

    struct Address: Hashable {
        let ip: String
        let interface: String

        /// Wi-Fi/Ethernet "normali" prima di VPN, bridge e simili.
        var priority: Int {
            if interface.hasPrefix("en") { return 0 }
            if interface.hasPrefix("bridge") { return 2 }
            return 1
        }
    }

    /// Indirizzi IPv4 delle interfacce attive (escluso il loopback).
    static func ipv4Addresses() -> [Address] {
        var result: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let iface = p.pointee
            let flags = Int32(bitPattern: iface.ifa_flags)
            if let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.append(Address(ip: String(cString: host), interface: String(cString: iface.ifa_name)))
                }
            }
            ptr = iface.ifa_next
        }
        return result.sorted { ($0.priority, $0.interface) < ($1.priority, $1.interface) }
    }

    /// QR code in bianco e nero, nitido a qualsiasi dimensione.
    static func qrCode(for text: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = (size / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
