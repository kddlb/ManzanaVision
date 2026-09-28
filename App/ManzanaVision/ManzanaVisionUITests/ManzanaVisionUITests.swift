// SPDX-License-Identifier: GPL-2.0-only
import XCTest

/// Drives the app against recordings (MANZANA_RECORDINGS), no tuner needed.
/// Screenshots of each step are kept in the test results.
final class ManzanaVisionUITests: XCTestCase {
    var app: XCUIApplication!
    var recordings = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        recordings = ProcessInfo.processInfo.environment["MANZANA_RECORDINGS"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../fixtures").standardized.path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: recordings + "/rf27-5min-20s.ts"),
                          "needs fixture recordings (scripts/make-fixtures.sh)")
    }

    /// Starts the app on 9.1 in the given language (the tests find controls by their English labels)
    private func launch(language: String = "en") {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["MANZANA_RECORDINGS"] = recordings
        app.launchArguments += ["-showOneSeg", "NO", "-lastRecordedChannel", "27:9728", "-showHUD", "NO",
                                "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(\(language))"]
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
        launch()
        XCTAssertTrue(window.staticTexts["MEGA HD"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["Tevex"].exists)
        XCTAssertFalse(window.staticTexts["MEGA MOVIL"].exists, "one-seg hidden by default")
        XCTAssertTrue(waitForTitle("9.1"))
        sleep(4)
        snapshot("1 playing 9.1")
    }

    func testZapAndNumericEntry() throws {
        launch()
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
        launch()
        XCTAssertTrue(waitForTitle("9.1"))
        sleep(3)
        window.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(window.staticTexts["SNR"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("4 signal HUD")
    }

    func testScanSheet() throws {
        launch()
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

    /// The HUD and scan sheet in Spanish and Portuguese, for checking the translations fit
    func testLocalizations() throws {
        for (language, layers, scan, scanTitle) in [("es", "Capas", "Buscar", "Buscar canales"),
                                                    ("pt-BR", "Camadas", "Buscar", "Buscar canais")] {
            launch(language: language)
            XCTAssertTrue(waitForTitle("9.1"))
            window.typeKey("i", modifierFlags: .command)
            XCTAssertTrue(window.staticTexts[layers].waitForExistence(timeout: 5), "\(language) HUD")
            sleep(3)
            snapshot("\(language) playing with HUD")
            window.buttons[scan].firstMatch.click()
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.staticTexts[scanTitle].waitForExistence(timeout: 5), "\(language) scan sheet")
            snapshot("\(language) scan sheet")
            sheet.typeKey(.escape, modifierFlags: [])
        }
    }

    func testSignalLossAndFullScreen() throws {
        launch()
        XCTAssertTrue(waitForTitle("9.1"))
        sleep(3)
        window.typeKey("l", modifierFlags: [.command, .control])  // Simulate Signal Loss (6 s)
        let lost = window.staticTexts["Signal lost — re-tuning"]
        XCTAssertTrue(lost.waitForExistence(timeout: 5))
        sleep(4)
        snapshot("7 signal lost, blurred")
        XCTAssertTrue(lost.waitForNonExistence(timeout: 15), "recovers after the dropout")
        sleep(2)
        snapshot("8 recovered")

        let view = app.menuBars.menuBarItems["View"]
        view.click()
        view.menuItems["Enter Full Screen"].click()
        sleep(3)
        snapshot("9 full screen")
        XCTAssertFalse(window.staticTexts["Tevex"].isHittable, "no sidebar in full screen")
        window.typeKey(.escape, modifierFlags: [])  // leaves full screen
        sleep(3)
        XCTAssertTrue(window.staticTexts["Tevex"].isHittable, "sidebar back after full screen")
    }
}
