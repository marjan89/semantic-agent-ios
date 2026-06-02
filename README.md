# semantic-agent (iOS)

Debug-only in-process HTTP server exposing the iOS accessibility tree, idle state, and tap/type surface for automated QA. Distributed as a local Swift Package.

See [tctl/docs/agent-porting-guide.md](../../tctl/docs/agent-porting-guide.md) for the cross-platform contract and [tctl/docs/agent-capability-matrix.md](../../tctl/docs/agent-capability-matrix.md) for per-platform feature status.

## Recent SHAs

| SHA | Change |
|---|---|
| ea6f281 | `POST /text-field/set` (`insertText`) + `POST /keyboard/dismiss` |
| 5d42d31 | `NetworkIdleURLProtocol` module prefix fix |
| 288d88b | `URLSession.shared` swizzle (mock + network-idle protocolClasses) |
| ab251b2 | Layer 1 fixtures + 8 YAMLParserTests |
| dbd9848 | Crawl consolidated onto shared test primitives |

## Consume

```swift
// Package.swift
.package(path: "../semantic-agent")

// App target
.product(name: "SemanticAgent", package: "SemanticAgent",
         condition: .when(platforms: [.iOS]))
```

Xcode: add `SemanticAgent` to app target's Frameworks/Libraries/Embedded Content; restrict to Debug config.

## Start

```swift
#if DEBUG
import SemanticAgent
SemanticAgent.shared.start()
#endif
```

Default port `9877` (override via `IDB_AGENT_PORT`). `MockBootstrap.m` runs at `+load`; no manual setup required for the mock layer.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET  | `/health` | agent status |
| GET  | `/version` | git hash + build time |
| GET  | `/semantic` | accessibility tree as YAML |
| GET  | `/semantic?scroll=0` | full-page semantic |
| GET  | `/idle` | `{"idle":bool}` |
| GET  | `/idle-resources` | per-resource status |
| POST | `/query-when-idle` | wait for idle + element |
| POST | `/scroll-search` | scroll until element surfaces |
| POST | `/click` | tap by `{resource_id|content_fuzzy|bounds}` |
| POST | `/text-field/set` (ea6f281) | atomic `insertText` on focused field; required for SwiftUI `SecureTextField` (WDA keystroke drops chars) |
| POST | `/keyboard/dismiss` (ea6f281) | `UIApplication.sendAction(#selector(UIResponder.resignFirstResponder))` |
| POST | `/mock` | register mock URL rules |
| POST | `/unmock` | clear mocks |
| GET  | `/mock-status` | hit log |
| POST | `/pop-to-root` | dismiss modals, pop nav |
| GET  | `/overlay` | optional debug overlay |
| POST | `/animations` | animation toggle |

## Mock body

```json
{
  "mocks": [{
    "url_pattern": "/v3.1/sites/123/relationships/questions",
    "method": "GET",
    "response": {
      "status": 200,
      "body": {"data": []},
      "headers": {"Content-Type": "application/json"}
    }
  }]
}
```

Match: `url.path.contains(pattern)`. First-match-wins.

## Endpoint selection

| Use case | Endpoint | Why |
|---|---|---|
| Plain text input | `insertText` via `/text-field/set` | atomic, no per-char drops |
| `SecureTextField` (password) | `/text-field/set` (required) | WDA `/type` drops chars on SwiftUI secure fields |
| Tap addressable element | `/click` with `resource_id` | stable |
| Dismiss keyboard between fields | `/keyboard/dismiss` | required so `Log in` button isn't off-screen |

## Requirements

- iOS 16+
- Swift 5.9+
- Debug only (`#if DEBUG` wrapped; release builds contain no agent symbols)

## Known limitations

See [tctl/docs/agent-capability-matrix.md](../../tctl/docs/agent-capability-matrix.md) §"Known limitations" rows L1 (`URLSession.shared`), L3 (SecureTextField via WDA — superseded by `/text-field/set`), L4 (SwiftUI cached tab leakage), L10 (test-data gaps for Q&A asserts).
