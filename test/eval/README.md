# Agent capability eval (offline)

Lightweight regression contracts for local-agent hardening work.

## Run

```bash
flutter test test/eval
```

Included in default CI via:

```bash
flutter test --exclude-tags=needs-plugins
```

## Scope

- Pure Dart / Flutter unit tests only
- No live LLM, network, path_provider, or plugin tags
- Domain unit tests under `test/models` / `test/services` remain the detailed source of truth; this suite is a cross-cutting checklist

## Covered capabilities

1. OS sandbox deny/allow matrix
2. Peer inbound boundary (CLI blocks + prompt strip)
3. Prompt stack factory defaults
4. History compaction plan + cache hit/prefix
5. History supplement turn planner outcomes
6. Token usage parsing merge
