//
//  AgenticBrowserActionTests.swift
//  SearxlyTests
//
//  Integration tests for the browser-action tools (page_snapshot / click / type / scroll /
//  read_current_page) — the riskiest agentic code, since it injects JavaScript into live pages.
//  Each test loads a small HTML page into a real, offscreen WKWebView, points the tools at it via
//  BrowserActions.testWebViewOverride, runs the tool, and asserts the DOM actually changed. No LLM.
//

import XCTest
import WebKit
@testable import Searxly

@MainActor
final class AgenticBrowserActionTests: XCTestCase {

    private var window: NSWindow?
    private var webView: WKWebView?

    private let page = """
    <!DOCTYPE html><html><body>
    <button id="btn" onclick="document.getElementById('out').textContent='clicked'">Press me</button>
    <input id="field" type="text" placeholder="name">
    <input id="pw" type="password" placeholder="password">
    <form id="frm" onsubmit="document.getElementById('out').textContent='submitted';return false;">
      <input id="fname" name="fullname" type="text" placeholder="Full name">
      <select id="sel" name="choice"><option>One</option><option>Two</option></select>
      <button id="go" type="submit">Send</button>
    </form>
    <div id="out">idle</div>
    <div style="height:3000px"></div>
    </body></html>
    """

    override func tearDown() async throws {
        AgenticApproval.shared.resolve(false)   // clear any pending approval a test left behind
        BrowserActions.testWebViewOverride = nil
        webView = nil
        window = nil
    }

    /// Load HTML into a WKWebView placed in a real (ordered-in) window so it actually lays out —
    /// `getBoundingClientRect` visibility and `innerText` both need layout. Waits for the page to be
    /// complete AND laid out. Skips gracefully in a headless environment with no window server.
    private func loadPage() async throws -> WKWebView {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let win = NSWindow(contentRect: wv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = wv
        win.orderFrontRegardless()   // give the web content a live layout without stealing focus
        window = win
        webView = wv
        wv.loadHTMLString(page, baseURL: URL(string: "https://test.example/"))
        for _ in 0..<120 {   // up to ~6s
            let ready = (try? await wv.evaluateJavaScript("document.readyState")) as? String
            let width = ((try? await wv.evaluateJavaScript(
                "document.getElementById('btn') ? document.getElementById('btn').getBoundingClientRect().width : 0")) as? Double) ?? 0
            if ready == "complete" && width > 0 {
                BrowserActions.testWebViewOverride = wv
                return wv
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("WKWebView did not lay out in this environment (headless / no window server)")
    }

    private func ref(of elementID: String, in wv: WKWebView) async -> Int? {
        let raw = (try? await wv.evaluateJavaScript("document.getElementById('\(elementID)').getAttribute('data-searxly-ref')")) as? String
        return raw.flatMap { Int($0) }
    }

    private func js(_ expr: String, _ wv: WKWebView) async -> String? {
        (try? await wv.evaluateJavaScript(expr)) as? String
    }

    func testSnapshotFindsInteractiveElements() async throws {
        _ = try await loadPage()
        let out = await PageSnapshotTool().run([:])
        guard case .ok(let text) = out else { return XCTFail("snapshot failed: \(out)") }
        XCTAssertTrue(text.contains("Press me"), "snapshot lists the button — got: \(text)")
        XCTAssertTrue(text.contains("[0]"), "elements are ref-tagged")
    }

    func testClickChangesTheDOM() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "btn", in: wv) else { return XCTFail("button was not ref-tagged") }
        _ = await ClickTool().run(["ref": r])
        let out = await js("document.getElementById('out').textContent", wv)
        XCTAssertEqual(out, "clicked", "clicking the button ran its handler")
    }

    func testTypeSetsInputValue() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "field", in: wv) else { return XCTFail("input was not ref-tagged") }
        let result = await TypeTool().run(["ref": r, "text": "hello world"])
        guard case .ok = result else { return XCTFail("type failed: \(result)") }
        let value = await js("document.getElementById('field').value", wv)
        XCTAssertEqual(value, "hello world")
    }

    func testTypeRefusesPasswordField() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "pw", in: wv) else { return XCTFail("password input was not ref-tagged") }
        let result = await TypeTool().run(["ref": r, "text": "hunter2"])
        guard case .failed(let message) = result else { return XCTFail("password field must be refused, got \(result)") }
        XCTAssertTrue(message.lowercased().contains("password"))
        let value = await js("document.getElementById('pw').value", wv)
        XCTAssertEqual(value, "", "nothing was typed into the password field")
    }

    func testScrollMovesTheViewport() async throws {
        let wv = try await loadPage()
        _ = await ScrollTool().run(["direction": "bottom"])
        try await Task.sleep(nanoseconds: 150_000_000)
        let y = (try? await wv.evaluateJavaScript("window.scrollY")) as? Double ?? 0
        XCTAssertGreaterThan(y, 0, "the page scrolled")
    }

    func testReadCurrentPageReturnsReadableText() async throws {
        _ = try await loadPage()
        let out = await ReadCurrentPageTool().run([:])
        guard case .ok(let text) = out else { return XCTFail("read_current_page failed: \(out)") }
        XCTAssertTrue(text.contains("Press me"), "readable text includes the page content")
    }

    // MARK: - describe_form

    func testDescribeFormListsFieldsAndOptions() async throws {
        _ = try await loadPage()
        let out = await DescribeFormTool().run([:])
        let text: String
        switch out {
        case .ok(let t): text = t
        case .okStructured(let t, _): text = t
        default: return XCTFail("describe_form failed: \(out)")
        }
        XCTAssertTrue(text.contains("Full name"), "lists the text field by label/placeholder: \(text)")
        XCTAssertTrue(text.contains("select"), "lists the select field: \(text)")
        XCTAssertTrue(text.contains("One") && text.contains("Two"), "select options are enumerated: \(text)")
    }

    // MARK: - Confirmation gate for irreversible actions

    /// Runs `body` with the confirm-before-acting setting forced to a value, restoring it after.
    private func withConfirmActions(_ enabled: Bool, _ body: () async throws -> Void) async throws {
        let mgr = AgenticServerManager.shared
        let prev = mgr.confirmActionsEnabled
        mgr.confirmActionsEnabled = enabled
        defer { mgr.confirmActionsEnabled = prev }
        try await body()
    }

    private func waitForPendingApproval() async throws -> Bool {
        for _ in 0..<80 {   // up to ~2s
            if AgenticApproval.shared.pending != nil { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    func testTypeSubmitPausesForApprovalAndDeclineKeepsFieldFilled() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "fname", in: wv) else { return XCTFail("field not ref-tagged") }
        try await withConfirmActions(true) {
            let task = Task { await TypeTool().run(["ref": r, "text": "Ada", "submit": true]) }
            let paused = try await waitForPendingApproval()
            XCTAssertTrue(paused, "type+submit pauses for the user's approval")
            AgenticApproval.shared.resolve(false)   // decline
            let result = await task.value
            guard case .ok(let msg) = result else { return XCTFail("expected ok, got \(result)") }
            XCTAssertTrue(msg.contains("not submitted"), "declined submit fills but doesn't submit: \(msg)")
            let value = await js("document.getElementById('fname').value", wv)
            XCTAssertEqual(value, "Ada", "the field is filled even though submit was declined")
        }
    }

    func testTypeSubmitProceedsWhenConfirmDisabled() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "fname", in: wv) else { return XCTFail("field not ref-tagged") }
        try await withConfirmActions(false) {
            let result = await TypeTool().run(["ref": r, "text": "Ada", "submit": true])
            guard case .ok(let msg) = result else { return XCTFail("expected ok, got \(result)") }
            XCTAssertTrue(msg.contains("submitted") && !msg.contains("not submitted"),
                          "with confirmation off, submit proceeds without asking: \(msg)")
            XCTAssertNil(AgenticApproval.shared.pending, "no approval prompt when confirmation is off")
        }
    }

    func testSubmitButtonClickPausesForApprovalWhenConfirmOn() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "go", in: wv) else { return XCTFail("submit button not ref-tagged") }
        try await withConfirmActions(true) {
            let task = Task { await ClickTool().run(["ref": r]) }
            let paused = try await waitForPendingApproval()
            XCTAssertTrue(paused, "clicking a form-submit button pauses for approval")
            AgenticApproval.shared.resolve(true)   // approve
            let result = await task.value
            guard case .ok(let msg) = result else { return XCTFail("approved submit should succeed: \(result)") }
            XCTAssertTrue(msg.contains("Submitted"), "approved click runs the submit: \(msg)")
        }
    }

    func testPlainClickDoesNotPauseForApproval() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let r = await ref(of: "btn", in: wv) else { return XCTFail("button not ref-tagged") }
        try await withConfirmActions(true) {
            _ = await ClickTool().run(["ref": r])   // #btn is not a form-submit control
            XCTAssertNil(AgenticApproval.shared.pending, "a non-submit click never asks for approval")
            let out = await js("document.getElementById('out').textContent", wv)
            XCTAssertEqual(out, "clicked", "the ordinary click still ran")
        }
    }

    // MARK: - fill_form (batch)

    func testFillFormBatchFillsMultipleFieldsInOneCall() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let fname = await ref(of: "fname", in: wv), let sel = await ref(of: "sel", in: wv) else {
            return XCTFail("form fields not ref-tagged")
        }
        let result = await FillFormTool().run(["fields": [
            ["ref": fname, "value": "Ada Lovelace"],
            ["ref": sel, "value": "Two"]
        ]])
        guard case .ok(let msg) = result else { return XCTFail("fill_form failed: \(result)") }
        XCTAssertTrue(msg.contains("Filled 2"), "one call filled both fields: \(msg)")
        let fv = await js("document.getElementById('fname').value", wv)
        XCTAssertEqual(fv, "Ada Lovelace")
        let sv = await js("document.getElementById('sel').value", wv)
        XCTAssertEqual(sv, "Two", "the <select> was set to the named option")
    }

    func testFillFormSkipsPasswordField() async throws {
        let wv = try await loadPage()
        _ = await PageSnapshotTool().run([:])
        guard let pw = await ref(of: "pw", in: wv), let field = await ref(of: "field", in: wv) else {
            return XCTFail("fields not ref-tagged")
        }
        let result = await FillFormTool().run(["fields": [
            ["ref": field, "value": "ok"],
            ["ref": pw, "value": "secret"]
        ]])
        guard case .ok(let msg) = result else { return XCTFail("fill_form failed: \(result)") }
        XCTAssertTrue(msg.contains("skipped 1 password"), "the password field is refused: \(msg)")
        let pv = await js("document.getElementById('pw').value", wv)
        XCTAssertEqual(pv, "", "nothing was written into the password field")
    }
}
