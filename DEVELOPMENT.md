# ShePaw Development Guide

Conventions for contributing to the Flutter app. Product overview lives in `README.md` / `README_CN.md`.

## Stack conventions

| Scenario | Approach |
|----------|----------|
| Business state (chat, peers, agents) | Service + Stream / `ChangeNotifier`, obtained via `getIt` |
| Local UI state (forms, expansion, scroll) | `StatefulWidget` + `setState` |
| Light global prefs (locale, notification toggles) | Provider + `ChangeNotifier` in `lib/providers/` |

Do **not** introduce GetX / Riverpod / Bloc unless there is an RFC that retires the existing paths.

### Dependency injection

- Composition root: `lib/service_locator.dart` (`get_it`)
- Startup: `lib/app_bootstrap.dart` (`AppBootstrap.initialize`)
- New shared services → register in `setupServiceLocator` / bootstrap; avoid new top-level `late` globals

### Local identity

Use `lib/services/local_user_identity.dart` (`LocalUserIdentity.id` / `displayName`). Do not reintroduce HTTP login + global WebSocket `AppState`.

## Commands

```bash
flutter pub get
flutter analyze
flutter test --exclude-tags=needs-plugins
flutter test test/eval
dart format .
```

Integration tests that need `path_provider` / platform channels are tagged `@Tags(['needs-plugins'])` and are excluded from CI.

Offline local-agent capability contracts live under `test/eval/` (see `test/eval/README.md`).

Golden / visual tests live under `test/widgets/` and use `matchesGoldenFile`. Update baselines with:

```bash
flutter test test/widgets/ --update-goldens
```

## Layout of important packages

```
lib/
  controllers/     # Chat / conversation coordinators (thin UI + composition)
  services/        # Domain services; SQLite DAOs under services/database/
  peer/            # Device pairing & P2P
  group/           # Group orchestration
  providers/       # Light prefs only
```

Prefer extracting pure helpers / coordinators over growing screen files. See `.ai_workspace/CHAT_CONTROLLER_SPLIT_PLAN.md` for the chat split pattern.

## Related docs

- [BUILD_GUIDE.md](BUILD_GUIDE.md) — release builds & Android signing
- [docs/STORE_RELEASE_CHECKLIST.md](docs/STORE_RELEASE_CHECKLIST.md) — store / PrivacyInfo checklist
- [docs/USER_GUIDE_EN.md](docs/USER_GUIDE_EN.md) / [docs/USER_GUIDE.md](docs/USER_GUIDE.md)
