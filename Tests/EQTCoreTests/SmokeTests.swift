import XCTest

final class SmokeTests: XCTestCase {
    func test_ringContractConstantsAreSane() {
        XCTAssertEqual(EQT_RING_CHANNELS, 2)
        XCTAssertEqual(Int(EQT_RING_CAPACITY_FRAMES) & (Int(EQT_RING_CAPACITY_FRAMES) - 1), 0)
        XCTAssertLessThanOrEqual(MemoryLayout<EQTRingHeader>.size, Int(EQT_RING_HEADER_BYTES))
    }
}

final class RingContractImportTests: XCTestCase {
    func test_derivedSizesAndNamesImportIntoSwift() {
        XCTAssertEqual(EQTRingTotalBytes(), EQT_RING_HEADER_BYTES + EQTRingSampleBytes())
        XCTAssertEqual(EQTRingSampleBytes(), EQT_RING_CAPACITY_FRAMES * EQT_RING_CHANNELS * 4)
        XCTAssertEqual(EQT_RING_SHM_NAME, "/eqtargets.audio.ring")
        XCTAssertEqual(EQT_DEVICE_UID, "com.eqtargets.audio.device")
    }
}
