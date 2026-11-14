import Foundation
import GhosttyVt

/// Owns the native terminal. Callers serialize access on the session's main actor.
public final class GhosttyTerminalEmulator: TerminalEmulator, @unchecked Sendable {
    private let snapshot: TerminalState
    private var snapshotDirty = true
    public var state: TerminalState {
        if snapshotDirty { refreshState() }
        return snapshot
    }
    public var title: String {
        var title = GhosttyString()
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title)
        return Self.string(title)
    }
    let terminal: GhosttyTerminal
    var nativeRender: GhosttyRenderState?
    var nativeImages: GhosttyRenderStateImageIterator?
    var pixelCellWidth: UInt32 = 0
    var pixelCellHeight: UInt32 = 0
    var imagePixels: [UInt64: TerminalImage] = [:]
    private let keyEncoder = KeyEncoder()
    public var onDisplayChange: (@Sendable () -> Void)?
    public var onBell: (@Sendable () -> Void)?
    var renderHoldStarted: TimeInterval?
    private var focused = false
    public var onResponse: ((Data) -> Void)?
    public var onSetClipboard: ((String) -> Void)?
    public var onGetClipboard: (() -> String?)?

    public init(columns: Int = 80, rows: Int = 24, scrollbackCapacity: Int = 10_000) {
        precondition((1...Int(UInt16.max)).contains(columns) && (1...Int(UInt16.max)).contains(rows))
        precondition(scrollbackCapacity >= 0)
        _ = Self.configurePNG
        var handle: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &handle, UInt16(columns), UInt16(rows))
        precondition(result == GHOSTTY_SUCCESS, "Cannot allocate terminal: \(result)")
        terminal = handle!
        snapshot = TerminalState(columns: columns, rows: rows, scrollbackCapacity: scrollbackCapacity)
        var byteLimit: UInt = scrollbackCapacity == 0 ? 0 : .max
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &byteLimit)
        var limit = scrollbackCapacity
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &limit)
        // Remote hosts must transmit pixels, never access files on the phone.
        for option in [GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM] {
            ghostty_terminal_set(terminal, option, nil)
        }
        let renderResult = ghostty_render_state_new(nil, &nativeRender)
        precondition(renderResult == GHOSTTY_SUCCESS)
        let imagesResult = ghostty_render_state_image_iterator_new(nil, &nativeImages)
        precondition(imagesResult == GHOSTTY_SUCCESS)
        installCallbacks()
        refreshState()
    }

    deinit {
        ghostty_render_state_image_iterator_free(nativeImages)
        ghostty_render_state_free(nativeRender)
        ghostty_terminal_free(terminal)
    }

    public var scrollbackCount: Int {
        var count = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &count)
        return count
    }

    public func feed(_ data: Data) {
        data.withUnsafeBytes { bytes in
            ghostty_terminal_vt_write(terminal, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        snapshotDirty = true
        onDisplayChange?()
    }

    public func resize(columns: Int, rows: Int) {
        guard (1...Int(UInt16.max)).contains(columns), (1...Int(UInt16.max)).contains(rows) else { return }
        guard ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), pixelCellWidth, pixelCellHeight) == GHOSTTY_SUCCESS else { return }
        snapshotDirty = true
        onDisplayChange?()
    }

    public func renderDelay(now: TimeInterval) -> TimeInterval {
        guard let start = renderHoldStarted else { return 0 }
        return max(0, start + 1 - now)
    }

    public func setFocused(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1004, false), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS, mode.value else { return }
        var bytes = [UInt8](repeating: 0, count: 3)
        var count = 0
        if ghostty_focus_encode(value ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &bytes, bytes.count, &count) == GHOSTTY_SUCCESS {
            onResponse?(Data(bytes.prefix(count)))
        }
    }

    public func setDefaultCursorStyle(_ style: CursorStyle) {
        var native = style == .bar ? GHOSTTY_CURSOR_STYLE_BAR : style == .underline ? GHOSTTY_CURSOR_STYLE_UNDERLINE : GHOSTTY_CURSOR_STYLE_BLOCK
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &native)
        snapshotDirty = true
        onDisplayChange?()
    }

    public func encodeKey(_ event: KeyEvent) -> Data {
        keyEncoder.encode(event, modes: [], terminal: terminal)
    }

    public func scrollbackLine(at index: Int) -> TerminalLine? {
        guard index >= 0, index < scrollbackCount else { return nil }
        _ = state
        return readLine(row: index, tag: GHOSTTY_POINT_TAG_HISTORY)
    }

    private func refreshState() {
        snapshotDirty = false
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        snapshot.activeScreen = screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY ? snapshot.primaryScreen : snapshot.alternateScreen
        let active = snapshot.activeScreen
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        active.columns = Int(columns)
        active.rows = Int(rows)
        active.lines = (0..<Int(rows)).map { readLine(row: $0, tag: GHOSTTY_POINT_TAG_ACTIVE) ?? TerminalLine(columns: Int(columns)) }
        var x: UInt16 = 0
        var y: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        active.cursor.col = Int(x)
        active.cursor.row = Int(y)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &active.cursor.visible)
        var title = GhosttyString()
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title)
        active.title = Self.string(title)
        snapshot.modes = []
        var keyboardFlags: UInt8 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &keyboardFlags)
        if keyboardFlags != 0 { snapshot.modes.insert(.kittyKeyboard) }
        for (number, ansi, flag): (UInt16, Bool, TerminalModes) in [
            (1, false, .applicationCursor), (66, false, .applicationKeypad),
            (7, false, .autoWrap), (6, false, .originMode), (4, true, .insertMode),
            (20, true, .lineFeedNewLine), (2004, false, .bracketedPaste),
            (1004, false, .focusEvents), (1000, false, .mouseButton),
            (1002, false, .mouseButton), (1003, false, .mouseAny),
            (1006, false, .mouseSGR), (25, false, .cursorVisible)
        ] {
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS, config.value {
                snapshot.modes.insert(flag)
            }
        }
        if screen != GHOSTTY_TERMINAL_SCREEN_PRIMARY { snapshot.modes.insert(.alternateScreen) }
        var history = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history)
        snapshot.scrollback = TerminalBuffer(count: history, capacity: snapshot.scrollback.capacity) { [weak self] index in
            self?.scrollbackLine(at: index)
        }
    }

    private func readLine(row: Int, tag: GhosttyPointTag) -> TerminalLine? {
        var line = TerminalLine(columns: snapshot.columns)
        var codepoints = [UInt32](repeating: 0, count: 8)
        var uriBytes = [UInt8](repeating: 0, count: 256)
        for column in 0..<snapshot.columns {
            var point = GhosttyPoint()
            point.tag = tag
            point.value.coordinate = GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))
            var ref = GhosttyGridRef()
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
            if column == 0 {
                var rawRow = GhosttyRow()
                var wrapped = false
                ghostty_grid_ref_row(&ref, &rawRow)
                ghostty_row_get(rawRow, GHOSTTY_ROW_DATA_WRAP, &wrapped)
                line.wrappedColumns = wrapped ? snapshot.columns : nil
            }
            var raw = GhosttyCell()
            var style = GhosttyStyle()
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_grid_ref_cell(&ref, &raw)
            ghostty_grid_ref_style(&ref, &style)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            var count = 0
            var result = ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.count, &count)
            if result == GHOSTTY_OUT_OF_SPACE {
                codepoints = [UInt32](repeating: 0, count: count)
                result = ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.count, &count)
            }
            let text = result == GHOSTTY_SUCCESS ? String(String.UnicodeScalarView(codepoints.prefix(count).compactMap(UnicodeScalar.init))) : ""
            var attributes: CellAttributes = []
            // GhosttyStyleFlags has a frozen ABI; its C cast macros are not imported by Swift.
            for (mask, attribute): (UInt16, CellAttributes) in [
                (1 << 0, .bold), (1 << 1, .italic),
                (1 << 2, .dim), (1 << 3, .blink),
                (1 << 4, .inverse), (1 << 5, .hidden),
                (1 << 6, .strikethrough), (7 << 8, .underline)
            ] {
                if style.flags & mask != 0 { attributes.insert(attribute) }
            }
            if wide == GHOSTTY_CELL_WIDE_WIDE { attributes.insert(.wideChar) }
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { attributes.insert(.wideCharTail) }
            if wide == GHOSTTY_CELL_WIDE_SPACER_HEAD, line.wrappedColumns != nil { line.wrappedColumns = column }
            var background = Self.color(style.bg_color)
            var content = GHOSTTY_CELL_CONTENT_CODEPOINT
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &content)
            if content == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
                var index: UInt8 = 0
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
                background = .indexed(index)
            } else if content == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                var rgb = GhosttyColorRgb()
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
                background = .rgb(rgb.r, rgb.g, rgb.b)
            }
            var hyperlink: String?
            var hasHyperlink = false
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasHyperlink)
            if hasHyperlink {
                var length = 0
                var result = ghostty_grid_ref_hyperlink_uri(&ref, &uriBytes, uriBytes.count, &length)
                if result == GHOSTTY_OUT_OF_SPACE {
                    uriBytes = [UInt8](repeating: 0, count: length)
                    result = ghostty_grid_ref_hyperlink_uri(&ref, &uriBytes, uriBytes.count, &length)
                }
                if result == GHOSTTY_SUCCESS, length > 0 { hyperlink = String(decoding: uriBytes.prefix(length), as: UTF8.self) }
            }
            line.cells[column] = TerminalCell(character: text.first ?? " ", fg: Self.color(style.fg_color), bg: background, attributes: attributes, hyperlink: hyperlink)
        }
        return line
    }

    private static func color(_ color: GhosttyStyleColor) -> TerminalColor {
        switch UInt32(color.tag) {
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return .indexed(color.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB.rawValue:
            let rgb = color.value.rgb
            return .rgb(rgb.r, rgb.g, rgb.b)
        default: return .default
        }
    }

    static func string(_ string: GhosttyString) -> String {
        String(decoding: UnsafeBufferPointer(start: string.ptr, count: string.len), as: UTF8.self)
    }

    private func installCallbacks() {
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(nativeBell as GhosttyTerminalBellFn, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(nativeRenderHold as GhosttyTerminalRenderHoldFn, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(nativeWrite as GhosttyTerminalWritePtyFn, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(nativeClipboardWrite as GhosttyTerminalClipboardWriteFn, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(nativeClipboardRead as GhosttyTerminalClipboardReadFn, to: UnsafeRawPointer.self))
    }
}

private func nativeWrite(_ terminal: GhosttyTerminal?, _ context: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
    guard let context, let bytes else { return }
    Unmanaged<GhosttyTerminalEmulator>.fromOpaque(context).takeUnretainedValue().onResponse?(Data(bytes: bytes, count: count))
}

private func nativeClipboardWrite(_ terminal: GhosttyTerminal?, _ context: UnsafeMutableRawPointer?, _ request: UnsafePointer<GhosttyClipboardWrite>?) {
    guard let context, let request else { return }
    let owner = Unmanaged<GhosttyTerminalEmulator>.fromOpaque(context).takeUnretainedValue()
    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    if let write = owner.onSetClipboard {
        if request.pointee.contents_len == 0 {
            write("")
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        } else if request.pointee.contents_len == 1, let content = request.pointee.contents?.pointee,
                  GhosttyTerminalEmulator.string(content.mime).hasPrefix("text/plain") {
            write(GhosttyTerminalEmulator.string(content.data))
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        }
    }
    request.pointee.reply?(request, &reply)
}

private func nativeClipboardRead(_ terminal: GhosttyTerminal?, _ context: UnsafeMutableRawPointer?, _ request: UnsafePointer<GhosttyClipboardRead>?) {
    guard let context, let request else { return }
    let owner = Unmanaged<GhosttyTerminalEmulator>.fromOpaque(context).takeUnretainedValue()
    var reply = GhosttyClipboardReadReply()
    reply.size = MemoryLayout<GhosttyClipboardReadReply>.size
    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
    guard let text = owner.onGetClipboard?() else {
        request.pointee.reply?(request, &reply)
        return
    }
    Array("text/plain".utf8).withUnsafeBufferPointer { mime in
        Array(text.utf8).withUnsafeBufferPointer { data in
            var content = GhosttyClipboardContent(mime: GhosttyString(ptr: mime.baseAddress, len: mime.count), data: GhosttyString(ptr: data.baseAddress, len: data.count))
            withUnsafePointer(to: &content) { contents in
                reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
                reply.contents = contents
                reply.contents_len = 1
                request.pointee.reply?(request, &reply)
            }
        }
    }
}

private func nativeBell(_ terminal: GhosttyTerminal?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<GhosttyTerminalEmulator>.fromOpaque(context).takeUnretainedValue().onBell?()
}

private func nativeRenderHold(_ terminal: GhosttyTerminal?, _ context: UnsafeMutableRawPointer?, _ held: Bool) {
    guard let context else { return }
    Unmanaged<GhosttyTerminalEmulator>.fromOpaque(context).takeUnretainedValue().renderHoldStarted = held ? ProcessInfo.processInfo.systemUptime : nil
}
