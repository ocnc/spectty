import XCTest
import MetalKit
import SpecttyTerminal
@testable import SpecttyUI

final class DisplayLifecycleTests: XCTestCase {
    @MainActor func testSessionSwitchDetachesOldDisplayCallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let old = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let next = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: .zero, emulator: old)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertNotNil(old.onDisplayChange)
        view.setEmulator(next)
        XCTAssertNil(old.onDisplayChange)
        XCTAssertNotNil(next.onDisplayChange)
    }
    @MainActor func testIdleViewStopsDrawingAndOutputWakesIt() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), emulator: emulator)
        let counter = DrawCounter()
        view.delegate = counter
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let idleCount = counter.count
        XCTAssertGreaterThan(idleCount, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.count, idleCount, "Idle terminals must not continuously render")
        emulator.feed(Data("hello".utf8))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(counter.count, idleCount)
    }
}

@MainActor private final class DrawCounter: NSObject, MTKViewDelegate {
    var count = 0
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        count += 1
        (view as? TerminalMetalView)?.draw(in: view)
    }
}
