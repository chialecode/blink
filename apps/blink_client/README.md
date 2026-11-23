# BLINK Client (`apps/blink_client`)

Five-platform Flutter desktop and mobile client for BLINK.

## Build & Test

From the repository root:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos
flutter test
```

Windows desktop packaging and local development installation are orchestrated via `scripts/package.py`.
