//
//  DisplayManager.swift
//  iPad Graphic Tablet — Mac
//
//  Elenco dei monitor attivi con identificativo stabile (UUID del display),
//  nome leggibile e coordinate nello spazio globale Quartz.
//

import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    /// Coordinate globali Quartz (origine in alto a sinistra del monitor principale, y verso il basso).
    let bounds: CGRect
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int

    var aspect: Double {
        bounds.height > 0 ? Double(bounds.width / bounds.height) : 16.0 / 9.0
    }

    var subtitle: String {
        "\(Int(bounds.width))×\(Int(bounds.height)) pt · \(pixelWidth)×\(pixelHeight) px\(isMain ? " · principale" : "")"
    }

    // Conformità esplicita (CGRect non è Hashable su tutti gli SDK).
    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool {
        a.id == b.id && a.uuid == b.uuid && a.name == b.name && a.bounds.equalTo(b.bounds)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uuid)
    }
}

enum DisplayManager {

    static func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let screens = NSScreen.screens
        return ids.prefix(Int(count)).map { id in
            let uuid: String
            if let cfuuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, cfuuid) as String
            } else {
                uuid = "display-\(id)"
            }
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Monitor integrato" : "Monitor \(id)")
            return DisplayInfo(id: id, uuid: uuid, name: name, bounds: CGDisplayBounds(id),
                               isMain: CGDisplayIsMain(id) != 0,
                               pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id))
        }
    }

    /// Monitor scelto nel profilo, oppure il principale.
    static func resolve(uuid: String?, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let uuid, let d = displays.first(where: { $0.uuid == uuid }) { return d }
        return displays.first(where: { $0.isMain }) ?? displays.first
    }

    /// Mantiene il punto dentro uno dei monitor (per il movimento relativo).
    static func clamp(_ p: CGPoint, to displays: [DisplayInfo], preferring fallback: DisplayInfo?) -> CGPoint {
        if displays.contains(where: { $0.bounds.contains(p) }) { return p }
        // Fuori da tutti i monitor: si riporta dentro quello più vicino.
        let candidates = displays.isEmpty ? (fallback.map { [$0] } ?? []) : displays
        var best = p
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for d in candidates {
            let r = d.bounds
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let dist = hypot(q.x - p.x, q.y - p.y)
            if dist < bestDistance { bestDistance = dist; best = q }
        }
        return best
    }
}

/// Conversioni dell'area del monitor (modalità Display).
enum DisplayRegion {
    /// Area in punti relativa all'angolo in alto a sinistra del monitor (come vuole ScreenCaptureKit).
    static func localRect(_ r: NormRect, displaySize: CGSize) -> CGRect {
        let x: CGFloat = CGFloat(r.x) * displaySize.width
        let y: CGFloat = CGFloat(r.y) * displaySize.height
        let w: CGFloat = CGFloat(r.width) * displaySize.width
        let h: CGFloat = CGFloat(r.height) * displaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Area nello spazio globale Quartz (quello degli eventi del mouse).
    static func globalRect(_ r: NormRect, in bounds: CGRect) -> CGRect {
        let local = localRect(r, displaySize: bounds.size)
        return local.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    /// Allarga l'area finché ha le proporzioni indicate (larghezza/altezza in punti),
    /// restando centrata e dentro il monitor.
    static func fitted(_ r: NormRect, toAspect aspect: Double, displaySize: CGSize) -> NormRect {
        guard aspect > 0, displaySize.width > 0, displaySize.height > 0 else { return r }
        let local = localRect(r.clamped(), displaySize: displaySize)
        var w: CGFloat = local.width
        var h: CGFloat = local.height
        let a = CGFloat(aspect)
        if w / h < a { w = h * a } else { h = w / a }
        // Se non entra nel monitor si riduce mantenendo le proporzioni.
        if w > displaySize.width { w = displaySize.width; h = w / a }
        if h > displaySize.height { h = displaySize.height; w = h * a }
        var x: CGFloat = local.midX - w / 2
        var y: CGFloat = local.midY - h / 2
        x = min(max(x, 0), displaySize.width - w)
        y = min(max(y, 0), displaySize.height - h)
        let nx = Float(x / displaySize.width)
        let ny = Float(y / displaySize.height)
        let nw = Float(w / displaySize.width)
        let nh = Float(h / displaySize.height)
        return NormRect(x: nx, y: ny, width: nw, height: nh)
    }
}
