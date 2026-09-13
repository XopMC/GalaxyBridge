import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): "Mac clipboard payload policy: \(message)"
        }
    }
}

@main
private enum MacClipboardPayloadPolicySpec {
    static func main() throws {
        let text = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.utf8-plain-text"],
            text: "hello",
            png: nil
        )
        try require(text?.kind == .text && text?.content == Data("hello".utf8), "plain text must be published")

        let webURL = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.url"],
            text: "https://example.com/path",
            png: nil
        )
        try require(webURL?.kind == .url, "HTTP(S) links must be identified as URLs")

        let nonWebURL = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.url"],
            text: "file:///Users/example/report.txt",
            png: nil
        )
        try require(nonWebURL?.kind == .text, "non-web URI text must remain transferable text")

        let concealed = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            text: "password",
            png: nil
        )
        try require(concealed == nil, "concealed pasteboard items must never leave the Mac")

        let transient = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
            text: "one-time secret",
            png: nil
        )
        try require(transient == nil, "transient pasteboard items must never leave the Mac")

        let oversizedText = String(repeating: "x", count: MacClipboardPayloadPolicy.maximumTextBytes + 1)
        try require(
            MacClipboardPayloadPolicy.candidate(pasteboardTypes: [], text: oversizedText, png: nil) == nil,
            "text above the Android limit must be rejected locally"
        )

        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let image = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: ["public.png"],
            text: "fallback",
            png: png
        )
        try require(image?.kind == .png && image?.content == png, "PNG must take precedence over fallback text")
        try require(image?.scrcpyText == nil, "PNG fallback text must not replace an unsupported image on the enhanced channel")
        try require(text?.scrcpyText == "hello", "text candidates must remain available to the enhanced channel")

        print("PASS Mac clipboard payload policy excludes sensitive data and matches Android limits")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure.failed(message) }
    }
}
