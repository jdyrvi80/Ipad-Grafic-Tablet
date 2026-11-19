//
//  ProtocolTests.swift
//  Test del protocollo binario, del framing, della curva di pressione,
//  dello stabilizzatore e della geometria.
//
//  Esecuzione:
//   • Xcode: schema "TabletCoreTests" → ⌘U
//   • Terminale: cd Shared && swift test
//

import XCTest
#if canImport(TabletCore)
@testable import TabletCore
#endif

final class ProtocolTests: XCTestCase {

    private func roundTrip(_ m: TabletMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        var decoder = FrameDecoder()
        decoder.append(m.framed())
        let out = try decoder.drainMessages()
        XCTAssertEqual(out.count, 1, file: file, line: line)
        XCTAssertEqual(out.first, m, file: file, line: line)
    }

    func testHelloRoundTrip() throws {
        try roundTrip(.hello(HelloMessage(deviceID: "ABC", deviceName: "iPad di Jody", model: "iPad16,3",
                                          systemVersion: "26.1", capabilities: [.pressure, .tilt, .hover],
                                          surfaceWidth: 1194, surfaceHeight: 834, screenScale: 2)))
    }

    func testSessionConfigRoundTrip() throws {
        let cfg = SessionConfigMessage(
            mode: .photoshop, profileName: "Photoshop Retouching", displayName: "Studio Display",
            inputRect: NormRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9), showInputRect: true,
            leftHanded: false, toolbarVisible: true,
            toolbar: [ToolbarItemInfo(id: 1, label: "Annulla", symbol: "arrow.uturn.backward", isHold: false),
                      ToolbarItemInfo(id: 8, label: "Alt", symbol: "option", isHold: true)],
            cursorLocked: false, precisionMode: true, palmRejection: true, eraserActive: false,
            macCanPostEvents: true, macRTTms: 3.5)
        try roundTrip(.sessionConfig(cfg))
    }

    func testAllSmallMessages() throws {
        try roundTrip(.welcome(WelcomeMessage(macID: "M1", macName: "MacBook Pro", accepted: true)))
        try roundTrip(.gesture(GestureMessage(kind: .scroll, dx: 3.5, dy: -12, scale: 1, fingers: 2)))
        try roundTrip(.button(ButtonMessage(buttonID: 7, pressed: true)))
        try roundTrip(.pencilGesture(PencilGestureMessage(kind: .squeeze, phase: .ended)))
        try roundTrip(.control(ControlMessage(command: .setMode, value: 2)))
        try roundTrip(.ping(PingMessage(id: 42, sentAt: 1234.5)))
        try roundTrip(.pong(PongMessage(id: 42, sentAt: 1234.5, peerTime: 99.25)))
        try roundTrip(.pairingKey(PairingKeyMessage(macID: "M", macName: "Mac", key: Data(repeating: 7, count: 32))))
        try roundTrip(.deviceUpdate(DeviceUpdateMessage(capabilities: [.pressure], surfaceWidth: 834, surfaceHeight: 1194)))
        try roundTrip(.bye("fine"))
        try roundTrip(.frameAck(77))
        try roundTrip(.videoFrame(VideoFrameMessage(frameID: 9, captureTime: 12.5, width: 1600, height: 1200,
                                                    data: Data(repeating: 0xAB, count: 300_000))))
        try roundTrip(.videoFrame(VideoFrameMessage(frameID: 10, captureTime: 13, width: 800, height: 600,
                                                    data: Data([1, 2, 3]),
                                                    region: NormRect(x: 0.25, y: 0.125, width: 0.5, height: 0.375))))
        try roundTrip(.gesture(GestureMessage(kind: .pointTo, dx: 0.25, dy: 0.75)))
        try roundTrip(.gesture(GestureMessage(kind: .tapAt, dx: 0.5, dy: 0.25)))
        try roundTrip(.gesture(GestureMessage(kind: .doubleTapAt, dx: 0.5, dy: 0.25)))
        try roundTrip(.gesture(GestureMessage(kind: .rightTapAt, dx: 0.1, dy: 0.9, fingers: 2)))
        try roundTrip(.gesture(GestureMessage(kind: .multiMove, dx: 12, dy: -30, fingers: 3)))
        try roundTrip(.gesture(GestureMessage(kind: .multiPinch, scale: 0.9, fingers: 4)))
        try roundTrip(.gesture(GestureMessage(kind: .multiEnd, fingers: 4)))
        try roundTrip(.gesture(GestureMessage(kind: .threeFingerTap, fingers: 3)))
        try roundTrip(.gesture(GestureMessage(kind: .pinch, dx: 0.5, dy: 0.5, scale: 1.05, fingers: 2)))
    }

    /// Fotogramma senza area (versione precedente): si decodifica come schermo intero.
    func testVideoFrameWithoutRegion() throws {
        let frame = VideoFrameMessage(frameID: 3, captureTime: 1, width: 16, height: 16, data: Data([9]),
                                      region: NormRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        var w = ByteWriter()
        TabletMessage.videoFrame(frame).encodePayload(into: &w)
        let trimmed = w.data.prefix(w.data.count - 16)
        let decoded = try TabletMessage.decode(type: MessageType.videoFrame.rawValue, payload: Data(trimmed))
        var expected = frame
        expected.region = .full
        XCTAssertEqual(decoded, .videoFrame(expected))
    }

    func testSessionConfigMirrorFields() throws {
        let cfg = SessionConfigMessage(
            mode: .display, profileName: "Display", displayName: "Studio Display",
            inputRect: NormRect(x: 0, y: 0.1, width: 1, height: 0.8), showInputRect: true,
            leftHanded: false, toolbarVisible: true, toolbar: [],
            cursorLocked: false, precisionMode: false, palmRejection: true, eraserActive: false,
            macCanPostEvents: true, macRTTms: 2, mirrorActive: true, mirrorStatus: "Serve il permesso",
            mirrorRegion: NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        try roundTrip(.sessionConfig(cfg))

        // Senza l'area (versione intermedia): area = tutto lo schermo.
        var w = ByteWriter()
        TabletMessage.sessionConfig(cfg).encodePayload(into: &w)
        let trimmed = w.data.prefix(w.data.count - 16)
        let decoded = try TabletMessage.decode(type: MessageType.sessionConfig.rawValue, payload: Data(trimmed))
        var expected = cfg
        expected.mirrorRegion = .full
        XCTAssertEqual(decoded, .sessionConfig(expected))
    }

    /// Un sessionConfig senza i campi della modalità Display (versione precedente) si decodifica ancora.
    func testSessionConfigWithoutMirrorFields() throws {
        let old = SessionConfigMessage(
            mode: .screen, profileName: "P", displayName: "D", inputRect: .full, showInputRect: false,
            leftHanded: false, toolbarVisible: false, toolbar: [], cursorLocked: false, precisionMode: false,
            palmRejection: true, eraserActive: false, macCanPostEvents: true, macRTTms: 1)
        var w = ByteWriter()
        TabletMessage.sessionConfig(old).encodePayload(into: &w)
        // Rimuove bool mirrorActive (1 byte) + stringa vuota (2 byte) + area (16 byte) in coda.
        let trimmed = w.data.prefix(w.data.count - 19)
        let decoded = try TabletMessage.decode(type: MessageType.sessionConfig.rawValue, payload: Data(trimmed))
        XCTAssertEqual(decoded, .sessionConfig(old))
    }

    func testProfileDecodingToleratesMissingFields() throws {
        let json = #"{"id":"6F1C6A10-0001-4C8B-9E3A-7A0B11111111","name":"Vecchio","mode":2}"#
        let p = try JSONDecoder().decode(TabletProfile.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Vecchio")
        XCTAssertEqual(p.mode, .display, "I profili delle vecchie modalità diventano Display")
        XCTAssertEqual(p.penMapping, .absolute)
        XCTAssertEqual(p.displayRegion, .full)
        XCTAssertEqual(p.mirrorMaxFPS, 30)
        XCTAssertEqual(p.displayGestures, .area)
        XCTAssertTrue(p.mirrorSharpenWhenIdle)
    }

    // MARK: Trackpad

    func testProfileModeDisplayOrTrackpad() {
        var p = TabletProfile(name: "Prova")
        XCTAssertEqual(p.mode, .display)
        p.mode = .touchpad
        XCTAssertEqual(p.mode, .touchpad)
        p.mode = .photoshop
        XCTAssertEqual(p.mode, .display, "Le vecchie modalità diventano Display")
    }

    func testTrackpadOptionsDefaultsAndTolerantDecoding() throws {
        let t = TrackpadOptions()
        XCTAssertEqual(t.secondaryClick, .twoFingers)
        XCTAssertTrue(t.naturalScrolling)
        XCTAssertEqual(t.missionControl, .three)
        XCTAssertEqual(t.swipeBetweenSpaces, .three)
        XCTAssertEqual(t.appExpose, .off)
        // Opzioni mancanti o non valide → valori predefiniti.
        let json = Data(#"{"naturalScrolling": false, "missionControl": 4, "secondaryClick": "boh"}"#.utf8)
        let decoded = try JSONDecoder().decode(TrackpadOptions.self, from: json)
        XCTAssertFalse(decoded.naturalScrolling)
        XCTAssertEqual(decoded.missionControl, .four)
        XCTAssertEqual(decoded.secondaryClick, .twoFingers)
        XCTAssertTrue(decoded.holdToDrag)
    }

    func testSecondaryClickCorners() {
        XCTAssertTrue(SecondaryClickMode.bottomRight.isSecondary(u: 0.9, v: 0.9))
        XCTAssertFalse(SecondaryClickMode.bottomRight.isSecondary(u: 0.1, v: 0.9))
        XCTAssertTrue(SecondaryClickMode.bottomLeft.isSecondary(u: 0.1, v: 0.9))
        XCTAssertFalse(SecondaryClickMode.twoFingers.isSecondary(u: 0.9, v: 0.9))
    }

    func testMirrorQualityPresets() {
        var p = TabletProfile(name: "Prova")
        for preset in MirrorQualityPreset.allCases {
            preset.apply(to: &p)
            XCTAssertEqual(MirrorQualityPreset.matching(p), preset)
        }
        p.mirrorQuality = 0.42
        XCTAssertNil(MirrorQualityPreset.matching(p), "Valori a mano = Personalizzata")
        XCTAssertEqual(MirrorQualityPreset.sharp.resolution, 1, "Nitida = risoluzione Retina piena")
    }

    func testPenSampleQuantization() throws {
        let s = PenSample(sequence: 9, timestamp: 1000.123456, x: 0.25, y: 0.75, pressure: 0.5,
                          altitude: 1.0, azimuth: 3.0, roll: 0.5, hoverDistance: 0.2,
                          flags: [.contact, .strokeBegan])
        var w = ByteWriter()
        s.encode(into: &w)
        XCTAssertEqual(w.data.count, PenSample.encodedSize)
        var r = ByteReader(w.data)
        let d = try PenSample.decode(from: &r)
        XCTAssertEqual(d.sequence, 9)
        XCTAssertEqual(d.timestamp, 1000.123456, accuracy: 1e-9)
        XCTAssertEqual(d.x, 0.25)
        XCTAssertEqual(d.pressure, 0.5, accuracy: 1.0 / 65535)
        XCTAssertEqual(d.altitude, 1.0, accuracy: 0.0001)
        XCTAssertEqual(d.azimuth, 3.0, accuracy: 0.0002)
        XCTAssertEqual(d.flags, [.contact, .strokeBegan])
    }

    /// Passa un campione attraverso codifica/decodifica: i valori quantizzati
    /// a 16 bit diventano così confrontabili esattamente.
    private func canonical(_ s: PenSample) throws -> PenSample {
        var w = ByteWriter()
        s.encode(into: &w)
        var r = ByteReader(w.data)
        return try PenSample.decode(from: &r)
    }

    func testFragmentedStream() throws {
        var messages: [TabletMessage] = []
        for i in 0..<50 {
            var batch: [PenSample] = []
            for j in 0..<4 {
                batch.append(try canonical(PenSample(sequence: UInt32(i * 4 + j), timestamp: Double(i),
                                                     x: 0.1, y: 0.2, pressure: 0.3, altitude: 0.4,
                                                     azimuth: 0.5, flags: [.contact])))
            }
            messages.append(.penBatch(batch))
        }
        var stream = Data()
        for m in messages { stream.append(m.framed()) }
        // Spezza il flusso in pezzi da 7 byte, come potrebbe fare TCP.
        var decoder = FrameDecoder()
        var decoded: [TabletMessage] = []
        var i = 0
        while i < stream.count {
            let end = min(i + 7, stream.count)
            decoder.append(stream.subdata(in: i..<end))
            decoded.append(contentsOf: try decoder.drainMessages())
            i = end
        }
        XCTAssertEqual(decoded, messages)
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testOversizedFrameRejected() {
        var w = ByteWriter()
        w.u32(UInt32(TabletWire.maxFrameBytes + 10))
        w.u8(4)
        var decoder = FrameDecoder()
        decoder.append(w.data)
        XCTAssertThrowsError(try decoder.nextFrame())
    }

    func testTruncatedPayloadRejected() {
        // penBatch che dichiara 3 campioni ma ne contiene 1.
        var w = ByteWriter()
        w.u16(3)
        PenSample(timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, flags: []).encode(into: &w)
        XCTAssertThrowsError(try TabletMessage.decode(type: MessageType.penBatch.rawValue, payload: w.data))
    }

    func testUnknownTypeRejected() {
        XCTAssertThrowsError(try TabletMessage.decode(type: 200, payload: Data()))
    }
}

final class PressureCurveTests: XCTestCase {

    func testLinearIsIdentity() {
        let c = PressureCurve.linear
        for v in stride(from: Float(0), through: 1, by: 0.1) {
            XCTAssertEqual(c.apply(v), v, accuracy: 0.002)
        }
    }

    func testMonotonicAndBounded() {
        for curve in [PressureCurve.soft, .firm, .linear] {
            var last: Float = -1
            for v in stride(from: Float(0), through: 1, by: 0.01) {
                let out = curve.apply(v)
                XCTAssertGreaterThanOrEqual(out, last - 0.0005)
                XCTAssertGreaterThanOrEqual(out, 0)
                XCTAssertLessThanOrEqual(out, 1)
                last = out
            }
        }
    }

    func testSoftIsAboveFirm() {
        XCTAssertGreaterThan(PressureCurve.soft.apply(0.3), PressureCurve.firm.apply(0.3))
    }

    func testSensitivityRange() {
        var c = PressureCurve.linear
        c.minimumInput = 0.2
        c.maximumInput = 0.6
        XCTAssertEqual(c.apply(0.1), 0, accuracy: 0.001)
        XCTAssertEqual(c.apply(0.4), 0.5, accuracy: 0.01)
        XCTAssertEqual(c.apply(0.9), 1, accuracy: 0.001)
    }

    func testFloorOnContact() {
        let c = PressureCurve(control1: CurvePoint(x: 0.33, y: 0.33), control2: CurvePoint(x: 0.66, y: 0.66),
                              outputFloor: 0.05)
        XCTAssertEqual(c.contactPressure(0), 0.05, accuracy: 0.0001)
    }
}

final class StabilizerTests: XCTestCase {

    func testDisabledIsPassthrough() {
        var s = PointStabilizer(strength: 0)
        let (x, y) = s.process(x: 0.3, y: 0.7, time: 1)
        XCTAssertEqual(x, 0.3)
        XCTAssertEqual(y, 0.7)
    }

    func testReducesJitter() {
        var s = PointStabilizer(strength: 0.8)
        var maxDev = 0.0
        var t = 0.0
        for i in 0..<480 {
            t += 1.0 / 240
            let noise = (i % 2 == 0 ? 1.0 : -1.0) * 0.002
            let (x, _) = s.process(x: 0.5 + noise, y: 0.5, time: t)
            if i > 60 { maxDev = max(maxDev, abs(x - 0.5)) }
        }
        XCTAssertLessThan(maxDev, 0.0015, "Il tremolio deve essere attenuato")
    }
}

final class GeometryTests: XCTestCase {

    func testRotationInverse() {
        for k in 0..<4 {
            let (rx, ry) = QuarterTurn.rotatePoint(0.2, 0.9, turns: k)
            let (bx, by) = QuarterTurn.inversePoint(rx, ry, turns: k)
            XCTAssertEqual(bx, 0.2, accuracy: 1e-12)
            XCTAssertEqual(by, 0.9, accuracy: 1e-12)
        }
    }

    func testAspectFitWide() {
        // iPad 4:3 orizzontale verso monitor 16:9 → altezza ridotta.
        let r = InputArea.effectiveRect(activeArea: .full, rotatedAspect: 4.0 / 3.0, targetAspect: 16.0 / 9.0)
        XCTAssertEqual(r.width, 1, accuracy: 1e-5)
        XCTAssertEqual(Double(r.height), (4.0 / 3.0) / (16.0 / 9.0), accuracy: 1e-5)
        XCTAssertEqual(r.y + r.height / 2, 0.5, accuracy: 1e-5)
    }

    func testAspectFitTall() {
        let r = InputArea.effectiveRect(activeArea: .full, rotatedAspect: 16.0 / 9.0, targetAspect: 4.0 / 3.0)
        XCTAssertEqual(r.height, 1, accuracy: 1e-5)
        XCTAssertEqual(Double(r.width), (4.0 / 3.0) / (16.0 / 9.0), accuracy: 1e-5)
    }

    // MARK: Modalità Display: zoom e spostamento

    func testViewportPanStaysOnDisplay() {
        let r = NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let moved = DisplayViewport.pan(r, dx: 0.8, dy: -0.8)
        XCTAssertEqual(moved.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(moved.y, 0, accuracy: 1e-6)
        XCTAssertEqual(moved.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(DisplayViewport.pan(.full, dx: 0.3, dy: 0.3), .full)
    }

    func testViewportZoomKeepsPointUnderFingers() {
        let r = NormRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let z = DisplayViewport.zoom(r, scale: 2, anchorX: 0.25, anchorY: 0.75, fillAspect: nil)
        XCTAssertEqual(z.width, 0.2, accuracy: 1e-6)
        XCTAssertEqual(z.height, 0.2, accuracy: 1e-6)
        // Il punto (0.3, 0.5) del monitor resta sotto le dita.
        XCTAssertEqual(z.x + 0.25 * z.width, 0.3, accuracy: 1e-6)
        XCTAssertEqual(z.y + 0.75 * z.height, 0.5, accuracy: 1e-6)
    }

    func testViewportZoomOutReachesFullDisplay() {
        let r = NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        XCTAssertEqual(DisplayViewport.zoom(r, scale: 0.01, anchorX: 0.5, anchorY: 0.5, fillAspect: 0.75), .full)
    }

    func testViewportZoomInFillsIPadAspect() {
        // Da tutto lo schermo: ingrandendo, l'area prende le proporzioni dell'iPad (niente bande nere).
        var r = NormRect.full
        for _ in 0..<4 {
            r = DisplayViewport.zoom(r, scale: 1.25, anchorX: 0.5, anchorY: 0.5, fillAspect: 0.75)
        }
        XCTAssertEqual(Double(r.width / r.height), 0.75, accuracy: 1e-4)
        XCTAssertLessThan(r.width, 1)
        XCTAssertGreaterThanOrEqual(r.x, 0)
        XCTAssertLessThanOrEqual(r.maxY, 1.0001)
    }

    func testViewportZoomHasLimit() {
        let z = DisplayViewport.zoom(.full, scale: 1000, anchorX: 0.5, anchorY: 0.5, fillAspect: nil)
        XCTAssertGreaterThanOrEqual(Double(min(z.width, z.height)), DisplayViewport.minSide - 1e-6)
    }

    func testViewportPlacement() {
        let view = NormRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        XCTAssertEqual(DisplayViewport.placement(frame: view, view: view), .full)
        let p = DisplayViewport.placement(frame: NormRect(x: 0, y: 0, width: 0.8, height: 0.8), view: view)
        XCTAssertEqual(p.x, -0.5, accuracy: 1e-6)
        XCTAssertEqual(p.width, 2, accuracy: 1e-6)
    }

    func testProfilesCodable() throws {
        let data = try JSONEncoder().encode(ProfilePresets.all)
        let back = try JSONDecoder().decode([TabletProfile].self, from: data)
        XCTAssertEqual(back, ProfilePresets.all)
    }

    func testLatencyOffsetEstimate() {
        var stats = LatencyStats()
        // Peer avanti di 100 s, RTT 4 ms simmetrico.
        stats.record(sentAt: 10.000, receivedAt: 10.004, peerTime: 110.002)
        XCTAssertEqual(stats.clockOffset ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.summary.avgMs, 4, accuracy: 1e-6)
    }
}
