# Spectty

An iOS SSH client built on [libghostty-vt](https://github.com/ghostty-org/ghostty) with a custom Metal renderer and clean-room Mosh implementation.

## Status

**Phase 1 complete** — terminal emulation, Metal rendering, SSH transport, key management, and app shell are functional. Mosh is stubbed for Phase 2.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  SwiftUI App Shell                                   │
│  ConnectionList → SessionManager → TerminalSession   │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  SpecttyUI                                           │
│  TerminalMetalView (MTKView) + Metal glyph atlas     │
│  TerminalView (UIViewRepresentable)                  │
│  InputAccessory, GestureHandler                      │
└──────────────┬───────────────────────────────────────┘
               │ reads state from
┌──────────────▼───────────────────────────────────────┐
│  SpecttyTerminal                                     │
│  VTStateMachine (CSI/SGR/OSC parser)                 │
│  TerminalState (grid, cursor, modes, scrollback)     │
│  KeyEncoder (xterm key sequences)                    │
│  CGhosttyVT (C stubs for future libghostty-vt)      │
└──────────────┬───────────────────────────────────────┘
               │ TerminalEmulator protocol
┌──────────────▼───────────────────────────────────────┐
│  SpecttyTransport                                    │
│  SSHTransport (SwiftNIO SSH)                         │
│  MoshTransport (Phase 2 — clean-room Swift)          │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  SpecttyKeychain                                     │
│  iOS Keychain storage, Ed25519/ECDSA generation,     │
│  Secure Enclave, OpenSSH key import                  │
└──────────────────────────────────────────────────────┘
```

**Data flow:**
```
Keyboard → KeyEncoder → Transport → Remote Server
                                         │
TerminalMetalView ← TerminalState ← VTStateMachine ← Transport
```

## Packages

| Package | Purpose |
|---------|---------|
| `SpecttyTerminal` | VT100/xterm state machine, cell model, scrollback buffer, key encoder |
| `SpecttyTransport` | SSH (SwiftNIO SSH) and Mosh transports behind `TerminalTransport` protocol |
| `SpecttyUI` | Metal renderer with CoreText glyph atlas, SwiftUI wrapper, input accessory bar, gestures |
| `SpecttyKeychain` | iOS Keychain key storage, Ed25519/ECDSA/Secure Enclave generation, OpenSSH PEM import |

## Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Rendering | Metal from day 1 | Performance parity with Ghostty |
| Terminal emulation | Custom Swift + libghostty-vt stubs | Replaceable via `TerminalEmulator` protocol as libghostty matures |
| SSH | SwiftNIO SSH | Pure Swift, Apple-maintained, Apache-2.0 |
| Mosh | Clean-room Swift (Phase 2) | No GPL dependency |
| Persistence | SwiftData | Modern, built-in, iOS 17+ |
| Concurrency | Swift 6 strict | async/await, AsyncStream, actors throughout |
| Key storage | iOS Keychain + Secure Enclave | Hardware-backed, platform standard |

## Migration Path

The architecture is designed so libghostty components can be swapped in incrementally:

1. **Now**: Our VT parser + our Metal renderer
2. **When libghostty adds terminal state C API**: Replace `VTStateMachine` — `TerminalEmulator` protocol insulates everything else
3. **When libghostty adds Metal rendering C API**: Replace `TerminalMetalRenderer` — `TerminalRenderer` protocol insulates everything else

No big-bang migration needed. Each step is independent.

## Dependencies

| Package | License |
|---------|---------|
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | Apache-2.0 |

No other third-party dependencies.

## Build

Requires Xcode 26.2+, iOS 18+ deployment target.

```bash
xcodebuild build -scheme Spectty -destination 'generic/platform=iOS'
```

## License

MIT
