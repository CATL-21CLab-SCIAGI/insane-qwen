import XCTest

final class EmbryoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
    }

    func testDemoRunShowsFinishedTrajectory() {
        XCTAssertTrue(app.staticTexts["demo.badge"].waitForExistence(timeout: 10))
        let prompt = app.textViews["prompt.editor"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("Calculate 17 times 23, then verify the result with Python.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let run = app.buttons["run.button"]
        for _ in 0..<4 where !run.isHittable { app.swipeUp() }
        XCTAssertTrue(run.isEnabled)
        run.tap()
        let finished = app.staticTexts["Finished"].firstMatch
        for _ in 0..<4 where !finished.exists { app.swipeUp() }
        XCTAssertTrue(finished.waitForExistence(timeout: 10))
    }

    func testSettingsAndHistoryNavigation() {
        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.textFields["connection.endpoint"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Playground"].tap()
        XCTAssertTrue(app.textViews["prompt.editor"].waitForExistence(timeout: 5))
    }

    func testDemoComparisonCreatesTwoFinishedLanes() {
        let compare = app.switches["compare.toggle"]
        for _ in 0..<5 where !compare.isHittable { app.swipeUp() }
        XCTAssertTrue(compare.exists)
        compare.tap()
        let run = app.buttons["run.button"]
        for _ in 0..<4 where !run.isHittable { app.swipeUp() }
        XCTAssertTrue(run.label.contains("comparison"))
        run.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Live comparison"].waitForExistence(timeout: 5))
        let bothFinished = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.staticTexts.matching(identifier: "Finished").count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [bothFinished], timeout: 10), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Offline model comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
