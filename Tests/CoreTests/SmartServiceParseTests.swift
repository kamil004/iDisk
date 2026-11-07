import XCTest
@testable import Core

/// Testy dla SmartService - parsowanie danych SMART.
final class SmartServiceParseTests: XCTestCase {

    func testValueFrom() {
        let text = """
        Model Number: Samsung SSD 870 EVO 1TB
        Serial Number: S5YWNF0M123456B
        Firmware Version: RVT03B6Q
        """

        XCTAssertEqual(SmartService.valueFrom(text, key: "Model Number"), "Samsung SSD 870 EVO 1TB")
        XCTAssertEqual(SmartService.valueFrom(text, key: "Serial Number"), "S5YWNF0M123456B")
        XCTAssertEqual(SmartService.valueFrom(text, key: "Firmware Version"), "RVT03B6Q")
        XCTAssertNil(SmartService.valueFrom(text, key: "NonExistent"))
    }

    func testModelFrom() {
        let text = "Device Model:     WDC WD10EZEX-08WN4A0"
        XCTAssertEqual(SmartService.modelFrom(text), "WDC WD10EZEX-08WN4A0")

        let text2 = "Model Number: Samsung SSD 870 EVO 1TB"
        XCTAssertEqual(SmartService.modelFrom(text2), "Samsung SSD 870 EVO 1TB")
    }

    func testParseAttributes_ATA() {
        let text = """
        SMART Attributes Data Structure revision number: 16
        Vendor Specific SMART Attributes with Thresholds:
        ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
          5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
         9 Power_On_Hours          0x0032   095   095   000    Old_age   Always       -       2500
        194 Temperature_Celsius     0x0022   055   045   000    Old_age   Always       -       55
        """

        let attrs = SmartService.parseAttributes(text)
        XCTAssertEqual(attrs.count, 3)
        XCTAssertEqual(attrs[0].id, 5)
        XCTAssertEqual(attrs[0].name, "Reallocated_Sector_Ct")
        XCTAssertEqual(attrs[0].current, 100)
        XCTAssertEqual(attrs[0].worst, 100)
        XCTAssertEqual(attrs[0].threshold, 10)
        XCTAssertEqual(attrs[0].raw, "0")

        XCTAssertEqual(attrs[1].id, 9)
        XCTAssertEqual(attrs[1].raw, "2500")
    }

    func testParseAttributes_NoHexFlag() {
        let text = """
        SMART Attributes Data Structure revision number: 1
        ID# ATTRIBUTE_NAME          VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
          5 Reallocated_Sector_Ct   100   100   010    Pre-fail  Always       -       0
        """

        let attrs = SmartService.parseAttributes(text)
        XCTAssertEqual(attrs.count, 1)
        XCTAssertEqual(attrs[0].id, 5)
        XCTAssertEqual(attrs[0].current, 100)
    }

    func testParseFields() {
        let text = """
        SMART overall-health self-assessment test result: PASSED
        Temperature: 35 C
        Available Spare: 100%
        """

        let fields = SmartService.parseFields(text)
        // Should skip the health line
        let keys = fields.map { $0.key }
        XCTAssertFalse(keys.contains("SMART overall-health self-assessment test result"))
        XCTAssertTrue(keys.contains("Temperature"))
        XCTAssertTrue(keys.contains("Available Spare"))
    }

    func testHealthText() {
        var device = SmartDevice(
            bsdName: "/dev/disk0",
            model: "Test",
            serial: "123",
            firmware: "1.0",
            deviceType: "SATA",
            sizeBytes: 1000000000,
            health: "PASSED",
            fields: [],
            attributes: [],
            rawOutput: ""
        )
        XCTAssertTrue(device.isHealthy)
        XCTAssertEqual(device.healthText, "Sprawny")

        device.health = "FAILED"
        XCTAssertFalse(device.isHealthy)
        XCTAssertEqual(device.healthText, "USZKODZONY")

        device.health = "UNKNOWN"
        XCTAssertFalse(device.isHealthy)
        XCTAssertEqual(device.healthText, "Nieznany")
    }
}
