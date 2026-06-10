# Changelog

All notable changes to semantic-agent-ios are documented here.

## [v0.2.0] — 2026-06-08

Bumped from the originally-planned v0.1.0 because that tag already existed at f925e9e ("mock layer verified + hit counter + viewport filter off"). Today's three commits land as v0.2.0 on top.

### Added
- **TD-75 /login endpoint** (32ef479): `POST /login` route — hosts register a `loginHandler` closure at agent boot; recipes call `/login` with credentials, the handler runs in-app (knows about auth flow internals the toolchain can't reach), agent returns success/failure. iOS sibling of Android TD-66.
- **TD-58 /text-field/set endpoint** (45e78c1): `POST /text-field/set` — agent sets text on the currently focused text field via Compose-aware focus probe. Mirror of the Android TD-58 fix; unblocks t12 (paste) class TCs.

### Removed
- **harvestWindowAXTree walker change reverted** (e6df8e7): TD-30 / TD-36 ITER attempted to walk the public UIView AX hierarchy to recover SwiftUI lazy-container labels; empirically demonstrated unreachable via public API (TD-68a research C confirmed SwiftUI keeps button AX in the XCAccessibility private path). Defensive changes kept where no-op; the windowing path was reverted to avoid carrying dead code.
