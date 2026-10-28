import XCTest

/// Explicitly enabled live-device check. Never supplies or reads bearer tokens.
final class EmbryoLiveUITests: XCTestCase {
    func testConfiguredGatewayAndRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EMBRYO_LIVE_DEVICE_TEST"] == "1",
                          "Live tests require an explicitly enabled, preconfigured device.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--live-test"]
        app.launch()

        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.staticTexts["Gateway connected"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.staticTexts["Token saved in this device’s Keychain"].exists)
        XCTAssertFalse(app.staticTexts["demo.badge"].exists)

        app.tabBars.buttons["Playground"].tap()
        let run = app.buttons["run.button"]
        for _ in 0..<6 where !run.isHittable { app.swipeUp() }
        XCTAssertTrue(run.isEnabled)
        run.tap() // Exactly one bounded task; a failure never retries the POST.
        for _ in 0..<3 { app.swipeUp() }

        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["Finished"].firstMatch.exists || app.staticTexts["Step limit"].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 120), .completed)
        let agentStep = app.staticTexts["Agent"].firstMatch
        XCTAssertTrue(agentStep.exists)
        let exitCode = app.staticTexts["exit 0"].firstMatch
        for _ in 0..<8 where !exitCode.isHittable { app.swipeUp() }
        XCTAssertTrue(exitCode.exists, "A tool must actually complete with exit code zero.")

        let observation = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Observation")).firstMatch
        if observation.exists && observation.isHittable { observation.tap() }
        let trajectory = XCTAttachment(screenshot: app.screenshot())
        trajectory.name = "Live gateway trajectory"
        trajectory.lifetime = .keepAlways
        add(trajectory)

        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.staticTexts["Token saved in this device’s Keychain"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "Live run history"
        history.lifetime = .keepAlways
        add(history)
    }
}
