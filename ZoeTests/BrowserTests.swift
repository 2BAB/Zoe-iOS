import Foundation
import Testing
@testable import Zoe

@Suite(.serialized) @MainActor
struct BrowserTests {
    let html = """
    <html><body><div id="items">Page one</div>
    <button id="next" onclick="setTimeout(()=>{document.querySelector('#items').textContent='Page two';this.disabled=true},80)">Next</button>
    <select id="date" onchange="document.querySelector('#items').textContent=this.value"><option>Today</option><option>Tomorrow</option></select>
    <input id="query" oninput="document.querySelector('#items').textContent=this.value">
    </body></html>
    """
    @Test func clickWaitsForSameURLSPAAndSelection() async throws {
        let browser = Browser()
        try await browser.loadFixture(html)
        let before = browser.currentURL
        try await browser.act(.init(kind: .click, selector: "#next",
                                    wait: .init(script: "return document.querySelector('#next').disabled;",
                                                changedSelector: "#items")), variables: [:])
        #expect(try await browser.read("return document.querySelector('#items').textContent;") == .string("Page two"))
        #expect(browser.currentURL == before)
        try await browser.act(.init(kind: .select, selector: "#date", value: .value(.string("Tomorrow")),
                                    wait: .init(script: "return document.querySelector('#items').textContent==='Tomorrow';")),
                              variables: [:])
        #expect(try await browser.read("return document.querySelector('#items').textContent;") == .string("Tomorrow"))
    }
    @Test func generatedJavaScriptCanInteractAndAwaitPageLocalChange() async throws {
        let browser = Browser()
        try await browser.loadFixture(html)
        let result = try await browser.read("""
            const button = document.querySelector('#next');
            if (!button) throw new Error('Missing button');
            button.click();
            return new Promise((resolve, reject) => {
              let checks = 0;
              const timer = setInterval(() => {
                const value = document.querySelector('#items')?.textContent;
                if (value === 'Page two') { clearInterval(timer); resolve(value); }
                else if (++checks > 20) { clearInterval(timer); reject(new Error('Page did not change')); }
              }, 20);
            });
            """)
        #expect(result == .string("Page two"))
    }
    @Test(arguments: ["/other", "about:blank"])
    func scriptCannotReplaceTheMainDocument(destination: String) async throws {
        let browser = Browser()
        let url = URL(string: "https://example.com/current")!
        try await browser.loadFixture("<h1>Current document</h1>", at: url)
        do {
            _ = try await browser.read("location.assign(input.destination); return new Promise(resolve => setTimeout(() => resolve(true), 100));",
                                       inputs: ["destination": .string(destination)])
            Issue.record("Expected navigation to be rejected")
        } catch let error as ZoeError {
            #expect(error.status == .needsRebuild)
            #expect(error.stopsRun)
            #expect(error.message.contains("act.navigate"))
        }
        #expect(browser.currentURL == url)
        try await browser.loadFixture("<h1>Fresh document</h1>", at: url)
        #expect(try await browser.read("return document.querySelector('h1').textContent;") == .string("Fresh document"))
    }
    @Test func scriptCanChangeAFragmentAndSPAState() async throws {
        let browser = Browser()
        try await browser.loadFixture("<h1>Same document</h1>", at: URL(string: "https://example.com/current")!)
        _ = try await browser.read("history.pushState({}, '', '/filtered'); return true;")
        let result = try await browser.read("location.hash='section'; return new Promise(resolve=>setTimeout(()=>resolve(document.querySelector('h1').textContent),80));")
        #expect(result == .string("Same document"))
    }
    @Test func argumentBindingAndQueryInput() async throws {
        let browser = Browser()
        try await browser.loadFixture(html)
        let hostile = "'; throw new Error('injection'); //"
        let value = try await browser.read("return input.value;", inputs: ["value": .string(hostile)])
        #expect(value == .string(hostile))
        try await browser.act(.init(kind: .fill, selector: "#query", value: .value(.string("Apple")),
                                    wait: .init(script: "return document.querySelector('#items').textContent==='Apple';")),
                              variables: [:])
    }
    @Test func rejectsAmbiguousTarget() async throws {
        let browser = Browser()
        try await browser.loadFixture("<button>one</button><button>two</button>")
        await #expect(throws: (any Error).self) {
            try await browser.act(.init(kind: .click, selector: "button",
                                        wait: .init(script: "return true;")), variables: [:])
        }
    }
    @Test func missingStateTimesOutInsteadOfEmptySuccess() async throws {
        let browser = Browser()
        try await browser.loadFixture(html)
        await #expect(throws: ZoeError.self) {
            try await browser.act(.init(kind: .wait, wait: .init(script: "return false;", timeoutSeconds: 1)), variables: [:])
        }
    }
    @Test func freshSessionDoesNotKeepStorage() async throws {
        let browser = Browser()
        try await browser.loadFixture(html)
        _ = try await browser.read("localStorage.setItem('test','old'); return true;")
        try await browser.loadFixture(html)
        #expect(try await browser.read("return localStorage.getItem('test');") == .null)
    }
    @Test func accessChallengeIsNotAnEmptyPage() async throws {
        let browser = Browser()
        try await browser.loadFixture("<div id='boxes_container'></div><textarea id='g-recaptcha-response'></textarea>")
        do { _ = try await browser.read("return []; "); Issue.record("Expected needsUser") }
        catch let error as ZoeError { #expect(error.status == .needsUser) }
        do {
            try await browser.act(.init(kind: .wait, wait: .init(script: "return true;", timeoutSeconds: 1)), variables: [:])
            Issue.record("Wait must preserve needsUser")
        } catch let error as ZoeError { #expect(error.status == .needsUser) }
    }
    @Test func svgQueryControlCanBeClicked() async throws {
        let browser = Browser()
        try await browser.loadFixture("<div id='state'>before</div><svg id='search' width='40' height='40' onclick=\"document.querySelector('#state').textContent='after'\"></svg>")
        try await browser.act(.init(kind: .click, selector: "#search",
            wait: .init(script: "return document.querySelector('#state').textContent==='after';")), variables: [:])
    }
    @Test func suspendedJavaScriptCanTimeOutAndANewPageStillWorks() async throws {
        let browser = Browser()
        try await browser.loadFixture("<h1>Old</h1>")
        let started = ContinuousClock.now
        do {
            _ = try await withTimeout(after: .milliseconds(80), onCancel: { browser.stop() }) {
                try await browser.read("return new Promise(resolve => setTimeout(() => resolve('old'), 1500));")
            }
            Issue.record("Expected deadline")
        } catch let error as ZoeError { #expect(error.status == .partial) }
        #expect(started.duration(to: .now) < .seconds(1))
        try await browser.loadFixture("<h1>New</h1>")
        #expect(try await browser.read("return document.querySelector('h1').textContent;") == .string("New"))
    }
}
