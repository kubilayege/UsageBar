import AppKit
import Foundation

struct SystemControlTests {
    @MainActor func testSleepTracksSystemAndFailedChanges() async {
        XCTAssertEqual(SleepControl.parse("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1"), true)
        XCTAssertEqual(SleepControl.parse(" SleepDisabled 0\n sleep 1 (sleep prevented by coreaudiod)"), false)
        XCTAssertEqual(SleepControl.parse("sleep 1\ndisplaysleep 0"), nil)
        var system = true
        var writes: [Bool] = []
        let control = SleepControl(read: { system }, write: { value in writes.append(value); system = value; return nil })
        await control.refresh()
        XCTAssertEqual(control.isSleepDisabled, true)
        await control.toggle()
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(control.isSleepDisabled, false)
        system = true
        await control.refresh()
        XCTAssertEqual(control.isSleepDisabled, true)
        let rejected = SleepControl(read: { true }, write: { _ in "cancelled" })
        await rejected.toggle()
        XCTAssertEqual(rejected.isSleepDisabled, true)
        XCTAssertEqual(rejected.errorMessage, "cancelled")
        let unconfirmed = SleepControl(read: { true }, write: { _ in nil })
        await unconfirmed.toggle()
        XCTAssertTrue(unconfirmed.errorMessage != nil)
        XCTAssertEqual(unconfirmed.isChanging, false)
    }

    @MainActor func testWhiteIconAndBankedResets() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let icon = MenuBarIcon.whiteGauge()!
                XCTAssertEqual(icon.isTemplate, false)
                let bitmap = NSBitmapImageRep(data: icon.tiffRepresentation!)!
                var visible = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                        visible += 1
                        XCTAssertTrue(color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98)
                    }
                }
                XCTAssertTrue(visible > 10)
            }
        }
        let provider = CodexProvider()
        var json: JSON = ["rate_limit": ["primary_window": ["used_percent": 11, "limit_window_seconds": 604800]],
                          "rate_limit_reset_credits": ["available_count": 1, "applicable_available_count": 0]]
        let snapshot = try provider.parse(json)
        XCTAssertEqual(snapshot.bankedResets, BankedResets(available: 1, applicable: 0))
        let roundtrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundtrip.bankedResets, snapshot.bankedResets)
        json["rate_limit_reset_credits"] = nil
        XCTAssertEqual(try provider.parse(json).bankedResets, nil)
    }
}
