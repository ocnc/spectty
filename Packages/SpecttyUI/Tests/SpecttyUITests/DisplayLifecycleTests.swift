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
        XCTAssertNil(old.onBell)
        XCTAssertNotNil(next.onDisplayChange)
        XCTAssertNotNil(next.onBell)
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
    @MainActor func testAnimationStopsInBackgroundAndAfterSessionSwitch() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator()
        emulator.feed(Data(("\u{1b}_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\u{1b}\\" +
            "\u{1b}_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\u{1b}\\" +
            "\u{1b}_Ga=a,i=1,r=1,z=40\u{1b}\\\u{1b}_Ga=a,i=1,s=3\u{1b}\\").utf8))
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), emulator: emulator)
        let counter = DrawCounter()
        view.delegate = counter
        let window = UIWindow(frame: view.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil) }
        try await Task.sleep(for: .milliseconds(500))
        let running = counter.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(counter.count, running)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let paused = counter.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.count, paused)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(counter.count, paused)
        let next = GhosttyTerminalEmulator()
        view.setEmulator(next)
        try await Task.sleep(for: .milliseconds(200))
        let switched = counter.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(counter.count, switched)
    }

    @MainActor func testFocusReportsAndBellReachVisibleView() async throws {
        let emulator = GhosttyTerminalEmulator()
        emulator.feed(Data("\u{1b}[?1004h".utf8))
        var responses = Data()
        emulator.onResponse = { responses.append($0) }
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), emulator: emulator)
        let window = UIWindow(frame: view.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertEqual(responses, Data("\u{1b}[I".utf8))
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(responses, Data("\u{1b}[I\u{1b}[O\u{1b}[I".utf8))
        emulator.feed(Data([7]))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(view.layer.sublayers?.contains { $0.animation(forKey: "bell") != nil } == true)
        let next = GhosttyTerminalEmulator()
        next.feed(Data("\u{1b}[?1004h".utf8))
        var nextResponses = Data()
        next.onResponse = { nextResponses.append($0) }
        view.setEmulator(next)
        XCTAssertEqual(responses, Data("\u{1b}[I\u{1b}[O\u{1b}[I\u{1b}[O".utf8))
        XCTAssertEqual(nextResponses, Data("\u{1b}[I".utf8))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(nextResponses, Data("\u{1b}[I\u{1b}[O".utf8))
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
