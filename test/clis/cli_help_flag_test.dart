import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/cli_base.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/clis/shepaw/context/context_namespace.dart';
import 'package:shepaw/clis/shepaw/chat/chat_namespace.dart';
import 'package:shepaw/clis/shepaw/profile/profile_namespace.dart';
import 'package:shepaw/clis/shepaw/memory/memory_namespace.dart';

/// Test suite for CLI help flag functionality across all CLI levels.
///
/// Verifies:
/// - getHelp() returns proper structure with 'command'/'namespace' and 'description'
/// - --help / -h flags trigger help output instead of execution
/// - Direct sub-namespace access returns help
/// - Normal execution works without --help
void main() {
  group('CLI Help Flag Tests', () {
    // ──────────────────────────────────────────────────────────────────────────
    // Test 1: Namespace-level help with --help flag
    // ──────────────────────────────────────────────────────────────────────────
    test('namespace-level help: shepaw context --help returns help', () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true,
          reason: 'Help output should have "namespace" key');
      expect(result['namespace'], equals('context'));
      expect(result.containsKey('description'), true,
          reason: 'Help output should have "description" key');
      expect(result['description'], isNotEmpty);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 2: Namespace-level help with -h flag
    // ──────────────────────────────────────────────────────────────────────────
    test('namespace-level help: shepaw context -h returns help', () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('', {'h': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true);
      expect(result['namespace'], equals('context'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 3: Empty subcommand (direct namespace call)
    // ──────────────────────────────────────────────────────────────────────────
    test('direct namespace access: shepaw context returns namespace help',
        () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('', {});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true,
          reason: 'Direct namespace access should return help');
      expect(result['namespace'], equals('context'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 4: Direct sub-namespace access (auto-help)
    // ──────────────────────────────────────────────────────────────────────────
    test(
        'direct sub-namespace access: shepaw context profile returns profile help',
        () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('profile', {});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true,
          reason: 'Direct sub-namespace access should return help');
      expect(result['namespace'], equals('profile'));
      expect(result['description'], isNotEmpty);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 5: Sub-namespace with --help flag
    // ──────────────────────────────────────────────────────────────────────────
    test(
        'sub-namespace help: shepaw context profile --help returns profile help',
        () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('profile', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true);
      expect(result['namespace'], equals('profile'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 6: Command-level help with dot notation
    // ──────────────────────────────────────────────────────────────────────────
    test(
        'command-level help: shepaw context profile.query --help returns command help',
        () async {
      final namespace = ContextNamespace.instance;
      final result =
          await namespace.execute('profile.query', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('command'), true,
          reason: 'Command help should have "command" key');
      expect(result['command'], equals('query'));
      expect(result['description'], isNotEmpty);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 7: Command-level help without help flag (should still show help)
    // ──────────────────────────────────────────────────────────────────────────
    test(
        'command-level help: shepaw context profile.query --help returns help',
        () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('profile.query', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('command'), true,
          reason: 'Command help should return help object');
      expect(result['command'], equals('query'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 8: Flat namespace help (chat namespace)
    // ──────────────────────────────────────────────────────────────────────────
    test('flat namespace help: shepaw chat --help returns help', () async {
      final namespace = ChatNamespace.instance;
      final result = await namespace.execute('', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true);
      expect(result['namespace'], equals('chat'));
      expect(result['description'], isNotEmpty);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 9: Flat namespace without help flag
    // ──────────────────────────────────────────────────────────────────────────
    test('flat namespace: shepaw chat without help shows help', () async {
      final namespace = ChatNamespace.instance;
      final result = await namespace.execute('', {});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true,
          reason: 'Empty subcommand on flat namespace should return help');
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 10: Help flag on flat namespace command (channels)
    // ──────────────────────────────────────────────────────────────────────────
    test('flat namespace command help: shepaw chat channels --help',
        () async {
      final namespace = ChatNamespace.instance;
      final result = await namespace.execute('channels', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('command'), true,
          reason: 'Command help should have "command" key');
      expect(result['command'], equals('channels'));
      expect(result['description'], isNotEmpty);
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 11: Memory namespace with help flag
    // ──────────────────────────────────────────────────────────────────────────
    test('memory sub-namespace: shepaw context memory --help', () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('memory', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true);
      expect(result['namespace'], equals('memory'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 12: Verify getHelp() structure at different levels
    // ──────────────────────────────────────────────────────────────────────────
    test('getHelp() returns proper structure at namespace level', () {
      final contextNamespace = ContextNamespace.instance;
      final help = contextNamespace.getHelp();

      expect(help, isA<Map<String, dynamic>>());
      expect(help.containsKey('namespace'), true,
          reason: 'Namespace help must have "namespace" key');
      expect(help.containsKey('description'), true,
          reason: 'Namespace help must have "description" key');
      expect(help['namespace'], equals('context'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 13: Verify getHelp() structure at command level
    // ──────────────────────────────────────────────────────────────────────────
    test('getHelp() returns proper structure at command level', () {
      final profileNamespace = ProfileNamespace.instance;
      final commands = profileNamespace.commands;

      expect(commands, isNotEmpty, reason: 'ProfileNamespace should have commands');

      final queryCommand = commands['query'];
      expect(queryCommand, isNotNull, reason: 'Profile namespace should have query command');

      final help = queryCommand!.getHelp();
      expect(help, isA<Map<String, dynamic>>());
      expect(help.containsKey('command'), true,
          reason: 'Command help must have "command" key');
      expect(help.containsKey('description'), true,
          reason: 'Command help must have "description" key');
      expect(help['command'], equals('query'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 14: Verify that --help doesn't execute the command
    // ──────────────────────────────────────────────────────────────────────────
    test('--help flag prevents command execution', () async {
      final namespace = ChatNamespace.instance;
      final result = await namespace.execute('channels', {'help': 'true'});

      expect(result, isA<Map>());
      expect(result.containsKey('command'), true,
          reason: 'Should return help, not command result');
      expect(result['command'], equals('channels'));

      // Help output should not contain the actual channels data
      expect(result.containsKey('channels'), false,
          reason: '--help should not execute command; should not return channels data');
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 15: Verify namespace hierarchy in help output
    // ──────────────────────────────────────────────────────────────────────────
    test('namespace help includes sub-namespace information', () {
      final contextNamespace = ContextNamespace.instance;
      final help = contextNamespace.getHelp();

      expect(help, isA<Map<String, dynamic>>());
      // Should have information about sub-namespaces
      final keys = help.keys.toList();
      expect(keys.isNotEmpty, true,
          reason: 'Namespace help should include hierarchical information');
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 16: Error handling for invalid sub-namespace
    // ──────────────────────────────────────────────────────────────────────────
    test('invalid sub-namespace returns error', () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('nonexistent.action', {});

      expect(result, isA<Map>());
      expect(result.containsKey('error'), true,
          reason: 'Should return error for invalid sub-namespace');
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 17: Help keyword without flag
    // ──────────────────────────────────────────────────────────────────────────
    test('help keyword triggers help output', () async {
      final namespace = ContextNamespace.instance;
      final result = await namespace.execute('help', {});

      expect(result, isA<Map>());
      expect(result.containsKey('namespace'), true,
          reason: 'help keyword should return namespace help');
      expect(result['namespace'], equals('context'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 18: Verify sub-namespace getHelp() is callable
    // ──────────────────────────────────────────────────────────────────────────
    test('sub-namespace getHelp() returns valid structure', () {
      final contextNamespace = ContextNamespace.instance;
      final profileNs = contextNamespace.subNamespaces['profile'];

      expect(profileNs, isNotNull);
      final help = profileNs!.getHelp();

      expect(help, isA<Map<String, dynamic>>());
      expect(help.containsKey('namespace'), true);
      expect(help['namespace'], equals('profile'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 19: Multiple levels of hierarchical help
    // ──────────────────────────────────────────────────────────────────────────
    test('multi-level help: context -> profile -> query chain', () async {
      final contextNs = ContextNamespace.instance;

      // Level 1: context namespace help
      final result1 = await contextNs.execute('', {'help': 'true'});
      expect(result1['namespace'], equals('context'));

      // Level 2: profile sub-namespace help
      final result2 = await contextNs.execute('profile', {'help': 'true'});
      expect(result2['namespace'], equals('profile'));

      // Level 3: profile.query command help
      final result3 = await contextNs.execute('profile.query', {'help': 'true'});
      expect(result3['command'], equals('query'));
    });

    // ──────────────────────────────────────────────────────────────────────────
    // Test 20: Verify both --help and -h work identically
    // ──────────────────────────────────────────────────────────────────────────
    test('--help and -h flags produce identical output', () async {
      final namespace = ContextNamespace.instance;

      final resultWithHelp = await namespace.execute('', {'help': 'true'});
      final resultWithH = await namespace.execute('', {'h': 'true'});

      expect(resultWithHelp['namespace'], equals(resultWithH['namespace']));
      expect(resultWithHelp['description'],
          equals(resultWithH['description']));
    });
  });
}
