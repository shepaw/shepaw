# CLI Tests

This directory contains unit tests for the ShepawCLI framework.

## Test Files

### cli_help_flag_test.dart
Comprehensive test suite for CLI help flag functionality across all levels (namespace, sub-namespace, command).

**What it tests:**
- Help flag handling (--help and -h)
- Hierarchical namespace help
- Flat namespace help  
- Sub-namespace direct access
- Command-level help with dot notation
- Help structure validation
- Help preventing command execution
- Multi-level help chains

**20 test cases** covering:
1. Namespace-level help with --help
2. Namespace-level help with -h
3. Direct namespace access (auto-help)
4. Direct sub-namespace access (auto-help)
5. Sub-namespace with --help flag
6. Command-level help with dot notation
7. Command help without help flag
8. Flat namespace help (chat)
9. Flat namespace without help flag
10. Help flag on flat namespace command
11. Memory sub-namespace help
12. getHelp() structure at namespace level
13. getHelp() structure at command level
14. Verification --help prevents execution
15. Namespace hierarchy in help output
16. Error handling for invalid sub-namespace
17. Help keyword triggering help
18. Sub-namespace getHelp() validation
19. Multi-level hierarchical help
20. --help and -h flag equivalence

## Running Tests

```bash
# All CLI tests
flutter test test/clis/cli_help_flag_test.dart

# Specific test by name
flutter test test/clis/cli_help_flag_test.dart --name "context"

# Verbose output
flutter test test/clis/cli_help_flag_test.dart -v
```

## Test Structure

- Uses `flutter_test` framework
- All tests are async (CLI uses Futures)
- Tests use direct instance access (no service initialization needed)
- Tests focus on CLI routing logic, not command execution
- Clear comments separate test sections for maintainability

## Key Test Patterns

1. **Async execution**: Tests use `async/await` for Future-returning execute()
2. **Flag passing**: Flags are Map<String, String> with 'true' values
3. **Instance testing**: Creates instances and calls methods directly
4. **Hierarchical testing**: Tests full navigation chain (namespace → sub-namespace → command)
5. **Structure validation**: Verifies help output contains expected keys

## CLI Levels Tested

### Hierarchical (Context Layer)
- ContextNamespace (main)
  - ProfileNamespace (sub)
    - query command
  - MemoryNamespace (sub)

### Flat (Chat Layer)  
- ChatNamespace (main)
  - channels command
  - messages command

## Notes

- Tests don't require database setup
- Tests don't require ChatService initialization
- Tests only validate CLI routing and help functionality
- Add new tests when CLI architecture changes
- Update expectations if namespace/command structure changes
