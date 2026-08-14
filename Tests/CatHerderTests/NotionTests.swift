import Foundation
import Testing
@testable import CatHerder

@Suite("Notion id normalization")
struct NotionIDTests {

    @Test("accepts dashed and dashless ids")
    func accepts() {
        #expect(TranscriptParser.normalizeNotionID("3b9ba770-0d1e-8138-b98a-db80e16c948c")
                == "3b9ba7700d1e8138b98adb80e16c948c")
        #expect(TranscriptParser.normalizeNotionID("317ba7700d1e80b6984ff40f990e6902")
                == "317ba7700d1e80b6984ff40f990e6902")
        #expect(TranscriptParser.normalizeNotionID("3B9BA7700D1E8138B98ADB80E16C948C")
                == "3b9ba7700d1e8138b98adb80e16c948c")
    }

    @Test("strips a collection:// prefix")
    func collections() {
        #expect(TranscriptParser.normalizeNotionID("collection://5a8c9fb3-389a-469a-8f4d-9d804d4e4ffe")
                == "5a8c9fb3389a469a8f4d9d804d4e4ffe")
    }

    @Test("rejects anything that is not a 32-hex id",
          arguments: ["", "not-an-id", "3b9ba770", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
                      "3b9ba7700d1e8138b98adb80e16c948cAA"])
    func rejects(_ input: String) {
        #expect(TranscriptParser.normalizeNotionID(input) == nil)
    }
}

@Suite("Notion slug titles")
struct NotionSlugTests {

    @Test("turns a slug into a readable title")
    func readable() {
        #expect(TranscriptParser.titleFromSlug("Widget-App-Memory-leak-issues")
                == "Widget App Memory leak issues")
    }

    /// Short all-caps prefixes are project codes and read better with a dash.
    @Test("keeps a short uppercase project prefix separated")
    func projectPrefix() {
        #expect(TranscriptParser.titleFromSlug("XY-Add-additional-fields-to-Product")
                == "XY - Add additional fields to Product")
        #expect(TranscriptParser.titleFromSlug("AB-New-ops-notification-missing")
                == "AB - New ops notification missing")
    }

    @Test("decodes percent-encoding")
    func percentEncoding() {
        #expect(TranscriptParser.titleFromSlug("Fix-100%25-of-bugs")?.contains("100%") == true)
    }
}

@Suite("Notion reference mining")
struct NotionMiningTests {

    private func refs(_ records: [String]) -> [NotionRef] {
        let temp = TempDirectory()
        return TranscriptParser.digest(path: temp.writeTranscript(records), sessionID: "S").notionRefs
    }

    private let pageID = "3b5ba7700d1e809e8b3fdf8150fc2882"

    /// A link printed by some unrelated command is a mention, not work.
    @Test("a bare URL in tool output is only a mention")
    func mentionFromOutput() throws {
        let found = refs([
            Rec.toolResult("see https://www.notion.so/\(pageID) for details",
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z"),
        ])
        let ref = try #require(found.first)
        #expect(ref.pageID == pageID)
        #expect(ref.source == .mention)
        #expect(ref.touches == 0)
    }

    @Test("a slugged URL supplies a title")
    func slugFromURL() throws {
        let found = refs([
            Rec.toolResult("https://www.notion.so/XY-Remove-legacy-uploader-\(pageID)",
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z"),
        ])
        let ref = try #require(found.first)
        #expect(ref.title == "XY - Remove legacy uploader")
        #expect(ref.source == .slugURL)
    }

    @Test("a page id passed to a Notion tool counts as real work")
    func toolCall() throws {
        let found = refs([
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-fetch",
                                           input: ["id": pageID])],
                          at: "2026-08-01T10:00:00.000Z"),
        ])
        let ref = try #require(found.first)
        #expect(ref.source == .toolCall)
        #expect(ref.touches == 1)
    }

    /// The authoritative title arrives in the tool's own response, as JSON
    /// embedded in a text block.
    @Test("a Notion tool response confirms the title")
    func confirmedTitle() throws {
        let payload = """
        {"metadata":{"type":"page"},"title":"Widget App - Memory leak issues",\
        "url":"https://app.notion.com/p/\(pageID)?pvs=204"}
        """
        let found = refs([
            Rec.toolResult([["type": "text", "text": payload]],
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z",
                           mcpTool: "notion-fetch"),
        ])
        let ref = try #require(found.first)
        #expect(ref.title == "Widget App - Memory leak issues")
        #expect(ref.source == .confirmed)
    }

    @Test("decodes escapes in a confirmed title")
    func unescapesTitle() throws {
        let payload = """
        {"title":"User shouldn\\u2019t redeem twice","url":"https://app.notion.com/p/\(pageID)"}
        """
        let found = refs([
            Rec.toolResult([["type": "text", "text": payload]],
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z",
                           mcpTool: "notion-fetch"),
        ])
        #expect(try #require(found.first).title == "User shouldn\u{2019}t redeem twice")
    }

    /// Regression: a grep printing a Notion link must not look like Notion work.
    @Test("output from a non-Notion tool never counts as a tool call")
    func nonNotionToolOutput() throws {
        let found = refs([
            Rec.toolResult("grep hit: notion.so/\(pageID)",
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z",
                           mcpTool: "some-other-tool"),
        ])
        #expect(try #require(found.first).source == .mention)
    }

    /// Regression: a database is not a card.
    @Test("data_source_id is ignored")
    func ignoresDataSource() {
        let found = refs([
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-create-pages",
                                           input: ["parent": ["data_source_id": pageID]])],
                          at: "2026-08-01T10:00:00.000Z"),
        ])
        #expect(found.isEmpty)
    }

    @Test("a create-pages title is adopted by the page that follows")
    func pendingTitleAdoption() throws {
        let found = refs([
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-create-pages",
                                           input: ["pages": [["properties": ["Name": "Brand new card"]]]])],
                          at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-update-page",
                                           input: ["page_id": pageID], id: "t2")],
                          at: "2026-08-01T10:00:10.000Z"),
        ])
        #expect(try #require(found.first).title == "Brand new card")
    }

    @Test("stronger evidence upgrades an existing reference")
    func upgradesSource() throws {
        let found = refs([
            Rec.toolResult("mentioned: notion.so/\(pageID)",
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-fetch",
                                           input: ["id": pageID])],
                          at: "2026-08-01T10:00:10.000Z"),
        ])
        let ref = try #require(found.first)
        #expect(found.count == 1)          // same page, not two entries
        #expect(ref.source == .toolCall)   // upgraded from mention
    }

    @Test("repeated interactions accumulate touches")
    func touchCounting() throws {
        let calls = (0..<4).map { index in
            Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-update-page",
                                           input: ["page_id": pageID], id: "t\(index)")],
                          at: "2026-08-01T10:0\(index):00.000Z")
        }
        #expect(try #require(refs(calls).first).touches == 4)
    }

    @Test("recognises app.notion.com URLs as well as notion.so")
    func bothHosts() {
        let found = refs([
            Rec.toolResult("https://app.notion.com/p/\(pageID)",
                           toolUseID: "t1", at: "2026-08-01T10:00:00.000Z"),
        ])
        #expect(found.first?.pageID == pageID)
    }
}

@Suite("NotionRef presentation")
struct NotionRefTests {

    @Test("falls back to a readable placeholder without a title")
    func placeholder() {
        let ref = NotionRef(pageID: "3b5ba7700d1e809e8b3fdf8150fc2882", title: nil, lastSeen: .now)
        #expect(ref.displayTitle == "Notion card 3b5ba770")
    }

    @Test("prefers the real title")
    func realTitle() {
        let ref = NotionRef(pageID: "abc", title: "Fix the bug", lastSeen: .now)
        #expect(ref.displayTitle == "Fix the bug")
    }

    @Test("builds an openable URL")
    func url() {
        let id = "3b5ba7700d1e809e8b3fdf8150fc2882"
        #expect(NotionRef(pageID: id, title: nil, lastSeen: .now).url?.absoluteString
                == "https://www.notion.so/\(id)")
    }

    @Test("source strength is ordered")
    func ordering() {
        #expect(NotionRefSource.mention < .slugURL)
        #expect(NotionRefSource.slugURL < .toolCall)
        #expect(NotionRefSource.toolCall < .confirmed)
    }
}
