import XCTest
@testable import CodexTouchBarNative

final class InterfaceSpecsTests: XCTestCase {
    // MARK: VDO decoding

    func testDecodesPassiveCableVDOByteFields() {
        // Raw e-marker bytes of VDO[3] for this Mac's iPad cable are
        // `44 26 0a 00`, which little-endian loads as 0x000a2644:
        // speed=4 (USB4 class), current=2 (5 A), maxVbus=3 (50 V),
        // plug=2 (Type-C), EPR capable.
        guard let raw = InterfaceSpecsReader.vdoFromData(
            Data([0x44, 0x26, 0x0a, 0x00])
        ) else {
            return XCTFail("VDO data should decode")
        }
        XCTAssertEqual(raw, 0x000a_2644)
        let live = InterfaceSpecsReader.decodeCableCapabilities(raw)
        XCTAssertEqual(live.speedRaw, 4)
        XCTAssertEqual(live.currentRaw, 2)
        XCTAssertEqual(live.maxVoltsRaw, 3)
        XCTAssertEqual(live.plugRaw, 2)
        XCTAssertTrue(live.eprCapable)
        XCTAssertEqual(live.maxAmps, 5)
        XCTAssertEqual(live.maxVolts, 50)
        XCTAssertEqual(live.maxWatts, 240)
    }

    func testCablePowerIsCappedAtSpecCeiling() {
        // 50 V × 5 A is 250 W of insulation headroom; USB-PD tops out at
        // 240 W, so the reported figure must not exceed that.
        let capabilities = CableCapabilities(
            speedRaw: 4,
            currentRaw: 2,
            maxVoltsRaw: 3,
            plugRaw: 2,
            eprCapable: true
        )
        XCTAssertEqual(capabilities.maxWatts, 240)
    }

    func testSpeedWordingStaysConservative() {
        // Encoding 3/4 differ between USB-PD 3.0 and 3.1, so the UI must not
        // promise the higher figure.
        let encodingThree = CableCapabilities(
            speedRaw: 3, currentRaw: 1, maxVoltsRaw: 0, plugRaw: 2, eprCapable: false
        )
        XCTAssertFalse(encodingThree.speedLabel.contains("40 Gbps"))
        XCTAssertTrue(encodingThree.speedLabel.contains("≥20 Gbps"))
        XCTAssertTrue(encodingThree.speedRawNote.contains("歧义"))

        let encodingFour = CableCapabilities(
            speedRaw: 4, currentRaw: 1, maxVoltsRaw: 0, plugRaw: 2, eprCapable: false
        )
        XCTAssertFalse(encodingFour.speedLabel.contains("80 Gbps"))
        XCTAssertTrue(encodingFour.speedLabel.contains("≥40 Gbps"))
        XCTAssertTrue(encodingFour.speedRawNote.contains("原始值 4"))
    }

    func testTwoAmpCableReportsThreeAmps() {
        let capabilities = CableCapabilities(
            speedRaw: 0, currentRaw: 0, maxVoltsRaw: 0, plugRaw: 2, eprCapable: false
        )
        // Type-C default current is 3 A even when the field says "default".
        XCTAssertEqual(capabilities.maxAmps, 3)
        XCTAssertEqual(capabilities.maxWatts, 60)
    }

    // MARK: Underpowered detection

    func testUnderpoweredDetectedWhenBatterySuppliesLoad() {
        XCTAssertTrue(PowerDiagnosis.isUnderpowered(.previewUnderpowered))
    }

    func testHealthyChargingIsNotUnderpowered() {
        XCTAssertFalse(PowerDiagnosis.isUnderpowered(.preview))
    }

    func testUnpluggedIsNotUnderpowered() {
        var metrics = SystemMetrics.previewUnderpowered
        metrics = SystemMetrics(
            externalPower: false,
            adapterLimitWatts: nil,
            inputWatts: nil,
            inputVoltage: nil,
            inputCurrent: nil,
            systemWatts: 12,
            batteryWatts: -12,
            batteryPercent: 67,
            batteryTemperature: nil,
            memoryPercent: nil,
            gpuPercent: nil,
            usbOutputs: []
        )
        XCTAssertFalse(PowerDiagnosis.isUnderpowered(metrics))
    }

    // MARK: Verdicts

    func testVerdictBlamesChargerWhenCableIsAdequate() {
        let verdict = PowerDiagnosis.verdict(
            specs: .preview,
            metrics: .previewUnderpowered
        )
        XCTAssertEqual(verdict.severity, .warning)
        XCTAssertEqual(verdict.title, "瓶颈在充电器")
        XCTAssertTrue(verdict.detail.contains("18.5 W"))
        XCTAssertTrue(verdict.detail.contains("≥45 W"))
    }

    func testVerdictBlamesCableWhenCableCannotCarryTheLoad() {
        // A 3 A / 20 V cable tops out at 60 W; drive a 95 W load so the
        // cable — not the charger — is the limiting part.
        var specs = InterfaceSpecs.preview
        specs.ports[0].cable = CableCapabilities(
            speedRaw: 0, currentRaw: 1, maxVoltsRaw: 0, plugRaw: 2, eprCapable: false
        )
        let heavyLoad = SystemMetrics(
            externalPower: true,
            adapterLimitWatts: 140,
            inputWatts: 45,
            inputVoltage: 20,
            inputCurrent: 2.25,
            systemWatts: 95,
            batteryWatts: -50,
            batteryPercent: 60,
            batteryTemperature: nil,
            memoryPercent: nil,
            gpuPercent: nil,
            usbOutputs: []
        )
        let verdict = PowerDiagnosis.verdict(specs: specs, metrics: heavyLoad)
        XCTAssertEqual(verdict.title, "瓶颈在线缆")
        XCTAssertTrue(verdict.detail.contains("60 W"))
    }

    func testAdequateCableDoesNotBlameTheCable() {
        // The same 95 W load with a 240 W cable must fall back to blaming
        // the charger instead.
        let heavyLoad = SystemMetrics(
            externalPower: true,
            adapterLimitWatts: 140,
            inputWatts: 45,
            inputVoltage: 20,
            inputCurrent: 2.25,
            systemWatts: 95,
            batteryWatts: -50,
            batteryPercent: 60,
            batteryTemperature: nil,
            memoryPercent: nil,
            gpuPercent: nil,
            usbOutputs: []
        )
        let verdict = PowerDiagnosis.verdict(specs: .preview, metrics: heavyLoad)
        XCTAssertEqual(verdict.title, "瓶颈在充电器")
        // 95 W load + 15 W headroom, rounded up to the next 5 W step.
        XCTAssertTrue(verdict.detail.contains("≥110 W"))
    }

    func testVerdictReportsHealthyWhenLoadIsCovered() {
        var metrics = SystemMetrics.preview
        metrics = SystemMetrics(
            externalPower: true,
            adapterLimitWatts: 85,
            inputWatts: 40,
            inputVoltage: 20,
            inputCurrent: 2,
            systemWatts: 30,
            batteryWatts: 8,
            batteryPercent: 47,
            batteryTemperature: nil,
            memoryPercent: nil,
            gpuPercent: nil,
            usbOutputs: []
        )
        let verdict = PowerDiagnosis.verdict(specs: .preview, metrics: metrics)
        XCTAssertEqual(verdict.severity, .ok)
        XCTAssertEqual(verdict.title, "供电正常")
    }

    func testVerdictWithoutChargerIsInformational() {
        let metrics = SystemMetrics(
            externalPower: false,
            adapterLimitWatts: nil,
            inputWatts: nil,
            inputVoltage: nil,
            inputCurrent: nil,
            systemWatts: 12,
            batteryWatts: -12,
            batteryPercent: 50,
            batteryTemperature: nil,
            memoryPercent: nil,
            gpuPercent: nil,
            usbOutputs: []
        )
        let verdict = PowerDiagnosis.verdict(specs: .empty, metrics: metrics)
        XCTAssertEqual(verdict.severity, .info)
        XCTAssertEqual(verdict.title, "未连接充电器")
    }

    // MARK: Panel summaries

    func testChargerSummaryUsesBrandRatedWattsAndNegotiatedOption() {
        XCTAssertEqual(InterfaceSpecs.preview.charger?.summary, "Apple 20W · 9V/2.22A")
    }

    func testPrimaryCablePortPrefersHighestPowerCable() {
        var specs = InterfaceSpecs.preview
        specs.ports.append(PortSpecs(
            portNumber: 3,
            cable: CableCapabilities(
                speedRaw: 2, currentRaw: 1, maxVoltsRaw: 0, plugRaw: 2, eprCapable: false
            )
        ))
        XCTAssertEqual(specs.primaryCablePort?.portNumber, 1)
        XCTAssertEqual(specs.primaryCablePort?.cableSummary, "240W · ≥40Gbps")
    }

    func testEmptySpecsHaveNoPanelContent() {
        XCTAssertFalse(InterfaceSpecs.empty.hasPanelContent)
        XCTAssertNil(InterfaceSpecs.empty.primaryCablePort?.cableSummary)
    }

    @MainActor
    func testLiveReaderReturnsSomethingOnThisMac() {
        // The reader must never throw or crash; on a Mac with a charger
        // attached it should find at least the adapter details.
        let specs = InterfaceSpecsReader.read()
        _ = specs
    }
}
