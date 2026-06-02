# SemanticAgent — iOS

Embeddable HTTP server for automated QA. Exposes the app's accessibility tree, idle state, and mock layer over HTTP. Debug builds only.

## Integration

### 1. Add Swift Package dependency

In Xcode: File → Add Package Dependencies → Add Local → select this directory.

Or in `Package.swift`:
```swift
.package(path: "../semantic-agent")
```

### 2. Add to your target (debug only)

```swift
// In your app target's dependencies:
.product(name: "SemanticAgent", package: "SemanticAgent", condition: .when(platforms: [.iOS]))
```

In Xcode: add `SemanticAgent` to your app target's "Frameworks, Libraries, and Embedded Content" — set to Debug configuration only.

### 3. Start the agent

In your `AppDelegate` or `@main` App struct:

```swift
#if DEBUG
import SemanticAgent

// In application(_:didFinishLaunchingWithOptions:) or init:
SemanticAgent.shared.start()
#endif
```

The agent listens on port 9877 by default. Override via `IDB_AGENT_PORT` environment variable.

### 4. MockBootstrap (automatic)

`MockBootstrap.m` runs at `+load` time — no manual setup needed. It swizzles `URLSessionConfiguration.protocolClasses` so all URL sessions route through `MockURLProtocol` when mocks are registered.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /health | Agent status |
| GET | /version | Git hash + build time |
| GET | /semantic | Full accessibility tree (YAML) |
| GET | /idle | Idle state (true/false) |
| GET | /idle-resources | Per-resource idle status |
| POST | /query-when-idle | Wait for idle, then find element |
| POST | /scroll-search | Scroll + search for element |
| POST | /mock | Register URL mock |
| POST | /unmock | Remove URL mock |
| GET | /mock-status | Mock hit log |
| POST | /pop-to-root | Dismiss all modals, pop navigation |
| GET | /overlay | Debug overlay |
| POST | /animations | Animation control |

## Mock Layer

Register mocks via POST /mock:
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

Mocks match on `url.path.contains(pattern)`. Register order matters — first match wins.

## Requirements

- iOS 16+
- Swift 5.9+
- Debug configuration only (all source files wrapped in `#if DEBUG`)
