// SPDX-License-Identifier: GPL-2.0-only
import XCTest

/// Drives the app against recordings (MANZANA_RECORDINGS), no tuner needed.
/// Screenshots of each step are kept in the test results.
final class ManzanaVisionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = ProcessInfo.processInfo.environment["MANZANA_RECORDINGS"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../fixtures").standardized.path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir + "/rf27-5min-20s.ts"),
                          "needs fixture recordings (scripts/make-fixtures.sh)")
        app = XCUIApplication()
        app.launchEnvironment["MANZANA_RECORDINGS"] = dir
        app.launchArguments += ["-showOneSeg", "NO", "-lastRecordedChannel", "27:9728", "-showHUD", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
    }

    private func snapshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private var window: XCUIElement { app.windows.firstMatch }

    private func waitForTitle(_ prefix: String, timeout: TimeInterval = 10) -> Bool {
        let p = NSPredicate(format: "title BEGINSWITH %@", prefix)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: window)], timeout: timeout) == .completed
    }

    func testChannelListAndPlayback() throws {
        XCTAssertTrue(window.staticTexts["MEGA HD"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["Tevex"].exists)
        XCTAssertFalse(window.staticTexts["MEGA MOVIL"].exists, "one-seg hidden by default")
        XCTAssertTrue(waitForTitle("9.1"))
        sleep(4)
        snapshot("1 playing 9.1")
    }

    func testZapAndNumericEntry() throws {
        XCTAssertTrue(waitForTitle("9.1"))
        window.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(waitForTitle("9.2"), "⌘↓ goes to the next channel")
        window.typeText("14.3")
        snapshot("2 typing 14.3")
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForTitle("14.3"), "typed channel number")
        sleep(4)
        snapshot("3 playing 14.3")
    }

    func testSignalHUD() throws {
        XCTAssertTrue(waitForTitle("9.1"))
        sleep(3)
        window.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(window.staticTexts["SNR"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("4 signal HUD")
    }

    func testScanSheet() throws {
        XCTAssertTrue(waitForTitle("9.1"))
        window.buttons["Scan"].firstMatch.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["Scan for Channels"].waitForExistence(timeout: 5))
        snapshot("5 scan sheet")
        sheet.buttons["Scan"].click()
        XCTAssertTrue(sheet.buttons["Done"].waitForExistence(timeout: 30), "scan finishes")
        snapshot("6 scan results")
        sheet.buttons["Done"].click()
        XCTAssertTrue(waitForTitle("9.1"), "playback resumes after the scan")
    }
}
