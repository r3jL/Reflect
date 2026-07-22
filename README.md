# Reflect

Local-first macOS journaling app with a layered AI understanding system.
Spec: [GENESIS_SPEC_journal_app.md](GENESIS_SPEC_journal_app.md) ·
Build plan: [docs/PHASE0_PLAN.md](docs/PHASE0_PLAN.md) ·
Design reference: `design/living-memory/`

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated, not committed:

```sh
xcodegen generate
open Reflect.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project Reflect.xcodeproj -scheme Reflect build
```

## Layout

- `Reflect/` — SwiftUI app target (features, design system, resources)
- `Packages/` — UI-independent SwiftPM modules: `ReflectCore` (DB, repos,
  queue), `ReflectAI` (providers, pipeline), `ReflectSTT` (whisper.cpp),
  `ReflectMedia` (thumbnails/posters)
- `prototypes/` — standalone de-risk spikes (DB, editor)
- `design/` — design mockups; `living-memory/` is authoritative
