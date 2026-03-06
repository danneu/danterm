func dragDropInputTests() {
    print("DragDropInput")

    test("shellQuote: simple path") {
        try expectEqual(DragDropInput.shellQuote("/path/to/file"), "'/path/to/file'")
    }

    test("shellQuote: path with spaces") {
        try expectEqual(DragDropInput.shellQuote("/path/to/my file.png"), "'/path/to/my file.png'")
    }

    test("shellQuote: path with embedded single quote") {
        try expectEqual(DragDropInput.shellQuote("/path/to/it's here"), "'/path/to/it'\\''s here'")
    }

    test("buildContent: single file path") {
        let result = DragDropInput.buildContent(filePaths: ["/path/to/my file.png"], urlString: nil, plainString: nil)
        try expectEqual(result, "'/path/to/my file.png'")
    }

    test("buildContent: multiple file paths") {
        let result = DragDropInput.buildContent(filePaths: ["/a/b", "/c/d"], urlString: nil, plainString: nil)
        try expectEqual(result, "'/a/b' '/c/d'")
    }

    test("buildContent: file paths take priority over urlString and plainString") {
        let result = DragDropInput.buildContent(filePaths: ["/a/b"], urlString: "https://example.com", plainString: "hello")
        try expectEqual(result, "'/a/b'")
    }

    test("buildContent: non-file URL string") {
        let result = DragDropInput.buildContent(filePaths: [], urlString: "https://example.com", plainString: nil)
        try expectEqual(result, "'https://example.com'")
    }

    test("buildContent: plain string passthrough unquoted") {
        let result = DragDropInput.buildContent(filePaths: [], urlString: nil, plainString: "hello world")
        try expectEqual(result, "hello world")
    }

    test("buildContent: all inputs empty/nil returns nil") {
        try expect(DragDropInput.buildContent(filePaths: [], urlString: nil, plainString: nil) == nil)
        try expect(DragDropInput.buildContent(filePaths: [], urlString: "", plainString: "") == nil)
        try expect(DragDropInput.buildContent(filePaths: [], urlString: "  ", plainString: "  ") == nil)
    }

    test("buildContent: empty-string file paths filtered out") {
        let result = DragDropInput.buildContent(filePaths: ["", "  "], urlString: "https://example.com", plainString: nil)
        try expectEqual(result, "'https://example.com'")
    }
}
