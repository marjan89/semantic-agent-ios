# Semantic Agent — iOS

Embeddable HTTP server for UI automation. Walks the SwiftUI/UIKit view hierarchy, exposes semantic elements via YAML, handles auth/navigation/idle detection via REST endpoints.

## Integration

### 1. Add via SPM

```swift
.package(url: "https://github.com/user/semantic-agent-ios", branch: "main")
```

### 2. Implement protocols

```swift
class MyAuthProvider: AgentAuthProvider {
    var isAuthenticated: Bool { /* ... */ }
    var userId: String { /* ... */ }
    func login(email: String, password: String) async -> (success: Bool, error: String?) { /* ... */ }
    func logout() { /* ... */ }
    func resetState() { /* ... */ }
}

class MyNavProvider: AgentNavigationProvider {
    func navigateToSite(id: Int) async -> UIViewController? { /* ... */ }
    func navigateToUser(id: Int) async -> UIViewController? { /* ... */ }
}
```

### 3. Start in AppDelegate

```swift
#if DEBUG
SemanticAgentEngine.shared.start(
    auth: MyAuthProvider(),
    nav: MyNavProvider()
)
#endif
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /health | Agent status |
| GET | /version | Git hash + build time |
| GET | /semantic | YAML view tree dump |
| GET | /idle | Idle state |
| POST | /auth/login | Login via provider |
| POST | /auth/logout | Logout |
| GET | /auth/state | Auth status |
| POST | /navigate/site/{id} | Navigate to site |
| POST | /navigate/user/{id} | Navigate to user |
| GET | /overlay | Debug overlay |
| POST | /animations | Enable/disable animations |

## Port

Default: 9877. Override via `IDB_AGENT_PORT` env var.
