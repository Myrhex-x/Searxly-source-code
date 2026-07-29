//
//  AnswerEngineTests.swift
//  SearxlyTests
//
//  Unit tests for the answer engine's model-response parsing — the trickiest part, since local models
//  emit tool-call arguments as either a JSON string (the spec) or a JSON object. No network.
//

import XCTest
@testable import Searxly

final class AnswerEngineTests: XCTestCase {

    func testParsesContentOnlyAsFinalAnswer() {
        let message: [String: Any] = ["role": "assistant", "content": "The answer is 42."]
        let c = LocalModelClient.parseMessage(message)
        XCTAssertEqual(c.content, "The answer is 42.")
        XCTAssertTrue(c.toolCalls.isEmpty, "no tool calls ⇒ this turn is the final answer")
    }

    func testParsesToolCallWithStringArguments() {
        let message: [String: Any] = [
            "role": "assistant",
            "tool_calls": [[
                "id": "call_1", "type": "function",
                "function": ["name": "web_search", "arguments": "{\"query\":\"giant pacific octopus\"}"]
            ]]
        ]
        let c = LocalModelClient.parseMessage(message)
        XCTAssertEqual(c.toolCalls.count, 1)
        XCTAssertEqual(c.toolCalls.first?.name, "web_search")
        XCTAssertEqual(c.toolCalls.first?.arguments["query"] as? String, "giant pacific octopus")
    }

    func testParsesToolCallWithObjectArguments() {
        // Some local models emit arguments as an object instead of a JSON string — must still work.
        let message: [String: Any] = [
            "role": "assistant",
            "tool_calls": [[
                "id": "call_2", "type": "function",
                "function": ["name": "read_page", "arguments": ["url": "https://example.com/story"]]
            ]]
        ]
        let c = LocalModelClient.parseMessage(message)
        XCTAssertEqual(c.toolCalls.first?.name, "read_page")
        XCTAssertEqual(c.toolCalls.first?.arguments["url"] as? String, "https://example.com/story")
        XCTAssertTrue((c.toolCalls.first?.rawArguments ?? "").contains("example.com"),
                      "the object is re-serialized so it can be echoed back to the model")
    }

    func testProviderDefaultsAreLoopback() {
        XCTAssertEqual(LocalModelProvider.ollama.defaultBaseURL, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(LocalModelProvider.lmStudio.defaultBaseURL, "http://127.0.0.1:1234/v1")
    }
}
