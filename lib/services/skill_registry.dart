/// Skill Registry — markdown-based instruction sets for local LLM agents.
///
/// Skills are subdirectories each containing a `SKILL.md` file (plus optional
/// auxiliary scripts) under the app's default skills directory.
///
/// SKILL.md format:
/// ```
/// ---
/// name: My Skill
/// description: What this skill does
/// ---
/// ... body ...
/// ```
/// The YAML front matter `name` field is authoritative for the skill's display
/// name and directory name. If front matter is absent the first `# ` heading is
/// used as a fallback (legacy support).
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'logger_service.dart';

/// Thrown when importing a skill whose name conflicts with an existing skill.
class SkillImportConflictException implements Exception {
  final String existingToolName;
  final String displayName;
  SkillImportConflictException(this.existingToolName, this.displayName);

  @override
  String toString() =>
      'SkillImportConflictException: skill "$displayName" ($existingToolName) already exists';
}

/// Describes a single skill parsed from a subdirectory or markdown file.
class SkillDefinition {
  /// Tool name used in function-calling (e.g. `skill_code_review`).
  final String toolName;

  /// Human-readable name extracted from YAML front matter or `# ` heading.
  final String displayName;

  /// Brief description from YAML front matter or first non-blank line after heading.
  final String description;

  /// Absolute path to the main `SKILL.md` file.
  final String filePath;

  /// Absolute path to the skill's subdirectory (or parent dir for legacy files).
  final String directoryPath;

  /// Total number of files in the skill directory.
  final int fileCount;

  const SkillDefinition({
    required this.toolName,
    required this.displayName,
    required this.description,
    required this.filePath,
    required this.directoryPath,
    required this.fileCount,
  });
}

// ---------------------------------------------------------------------------
// Front matter parser result
// ---------------------------------------------------------------------------

class _FrontMatter {
  final String? name;
  final String? description;

  const _FrontMatter({this.name, this.description});
}

/// Central registry for markdown-based skills.
class SkillRegistry {
  SkillRegistry._();
  static final SkillRegistry instance = SkillRegistry._();

  String _directoryPath = '';
  List<SkillDefinition> _skills = [];

  /// Absolute path to the skills directory.
  String get directoryPath => _directoryPath;

  /// All currently loaded skill definitions.
  List<SkillDefinition> get skills => List.unmodifiable(_skills);

  /// All skill tool names.
  Set<String> get allSkillNames => _skills.map((s) => s.toolName).toSet();

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Resolves the default skills directory under the app's documents path
  /// and performs the initial scan. Call once at app startup.
  Future<void> initialize() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final skillsDir = Directory(p.join(docsDir.path, 'shepaw', 'skills'));
    if (!await skillsDir.exists()) {
      await skillsDir.create(recursive: true);
    }
    _directoryPath = skillsDir.path;
    await rescan();
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Re-scans the skills directory for skill packages (subdirectories)
  /// and legacy top-level `.md` files.
  Future<void> rescan() async {
    _skills = [];
    if (_directoryPath.isEmpty) return;

    final dir = Directory(_directoryPath);
    if (!await dir.exists()) return;

    try {
      final seenToolNames = <String>{};

      // 1. Scan subdirectories first — each subdir is a skill package
      final entries = dir.listSync();
      final subDirs = entries.whereType<Directory>().toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      for (final subDir in subDirs) {
        final def = await _parseSkillDirectory(subDir);
        if (def != null && !seenToolNames.contains(def.toolName)) {
          _skills.add(def);
          seenToolNames.add(def.toolName);
        }
      }

      // 2. Legacy fallback: top-level .md files
      final mdFiles = entries
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      for (final file in mdFiles) {
        final def = await _parseSkillFile(file);
        if (def != null && !seenToolNames.contains(def.toolName)) {
          _skills.add(def);
          seenToolNames.add(def.toolName);
        }
      }

      // Sort by display name for stable UI ordering
      _skills.sort((a, b) => a.displayName.compareTo(b.displayName));
    } catch (e) {
      LoggerService().error('Rescan error', tag: 'SkillRegistry', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // Import / Delete
  // ---------------------------------------------------------------------------

  /// Imports a skill from a ZIP file.
  ///
  /// Recursively searches the extracted archive (from the root) for the first
  /// file named `SKILL.md` (case-insensitive). Parses its YAML front matter
  /// for `name`. Copies that file and all its siblings (same directory) into
  /// `<skillsDir>/<sanitized_name>/`.
  ///
  /// Throws [SkillImportConflictException] if a skill with the same name
  /// already exists and [overwrite] is false.
  Future<SkillDefinition> importSkillZip(
    String zipPath, {
    bool overwrite = false,
  }) async {
    if (_directoryPath.isEmpty) {
      throw Exception('Skill registry not initialized');
    }

    // 1. Extract ZIP to a temp directory
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final tempDir = await Directory.systemTemp.createTemp('skill_import_');
    try {
      for (final entry in archive) {
        final filePath = p.join(tempDir.path, entry.name);
        if (entry.isFile) {
          final outFile = File(filePath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(entry.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }

      // 2. Recursively find the first SKILL.md (BFS by directory depth)
      final skillMd = await _findSkillMd(tempDir);
      if (skillMd == null) {
        throw Exception('No SKILL.md found in the ZIP archive');
      }

      // 3. Parse front matter for name
      final content = await skillMd.readAsString();
      final fm = _parseFrontMatter(content);
      final displayName = (fm.name != null && fm.name!.isNotEmpty)
          ? fm.name!
          : _extractHeadingName(content);
      if (displayName == null || displayName.isEmpty) {
        throw Exception(
            'SKILL.md has no "name" in front matter and no # heading');
      }

      // 4. Conflict check
      final toolName = 'skill_${_sanitizeName(displayName)}';
      final existing = getDefinition(toolName);
      if (existing != null && !overwrite) {
        throw SkillImportConflictException(toolName, displayName);
      }

      // 5. Destination: <skillsDir>/<sanitized_name>/
      final destName = _sanitizeName(displayName);
      final destDir = Directory(p.join(_directoryPath, destName));
      if (await destDir.exists()) {
        await destDir.delete(recursive: true);
      }
      await destDir.create(recursive: true);

      // 6. Copy SKILL.md, all siblings, and subdirectories recursively
      final sourceDir = skillMd.parent;
      await _copyDirectory(sourceDir, destDir);

      // 7. Rescan and return
      await rescan();
      final newDef = getDefinition(toolName);
      if (newDef == null) {
        throw Exception('Imported skill not found after rescan');
      }
      return newDef;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Downloads a skill from [url] and imports it.
  ///
  /// - `.zip` URL → downloads to a temp file → delegates to [importSkillZip]
  /// - `.md` URL  → downloads content        → delegates to [importSkillMd]
  ///
  /// [onProgress] callback: `(int received, int total)`;
  /// `total == -1` means the server did not send Content-Length.
  ///
  /// Throws [SkillImportConflictException] on name conflict when overwrite=false.
  /// Throws [ArgumentError] for invalid URL or unsupported file type.
  Future<SkillDefinition> importSkillFromUrl(
    String url, {
    bool overwrite = false,
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError('无效的 URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('仅支持 http/https 协议');
    }

    final pathLower = uri.path.toLowerCase();
    final isZip = pathLower.endsWith('.zip');
    final isMd = pathLower.endsWith('.md');
    if (!isZip && !isMd) {
      throw ArgumentError('仅支持 .zip 和 .md 文件');
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));

    try {
      if (isZip) {
        // Download ZIP to a temp file, then reuse importSkillZip
        final tempDir = await Directory.systemTemp.createTemp('skill_url_');
        final tempFile = File('${tempDir.path}/download.zip');
        try {
          await dio.download(
            url,
            tempFile.path,
            onReceiveProgress: onProgress,
          );
          return await importSkillZip(tempFile.path, overwrite: overwrite);
        } finally {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      } else {
        // Download .md content as plain text
        final response = await dio.get<String>(
          url,
          onReceiveProgress: onProgress,
          options: Options(responseType: ResponseType.plain),
        );
        final content = response.data;
        if (content == null || content.trim().isEmpty) {
          throw Exception('下载的 .md 文件内容为空');
        }
        // Use URL filename as fallback name (stripped of .md extension)
        final fileName = uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => 'imported_skill',
        );
        final fallbackName = fileName.endsWith('.md')
            ? fileName.substring(0, fileName.length - 3)
            : fileName;
        return await importSkillMd(content, fallbackName, overwrite: overwrite);
      }
    } on DioException catch (e) {
      final msg = switch (e.type) {
        DioExceptionType.connectionTimeout => '连接超时',
        DioExceptionType.receiveTimeout => '接收数据超时',
        DioExceptionType.badResponse =>
          'HTTP ${e.response?.statusCode}: ${e.response?.statusMessage}',
        DioExceptionType.cancel => '下载已取消',
        _ => '网络错误: ${e.message}',
      };
      throw Exception(msg);
    } finally {
      dio.close();
    }
  }

  /// Saves a SKILL.md string as a standalone skill.
  ///
  /// Storage layout: `<skillsDir>/<sanitized_name>/SKILL.md`
  ///
  /// The `name` field in YAML front matter is used as the skill name.
  /// Falls back to the first `# ` heading, then to [fallbackName].
  ///
  /// Throws [SkillImportConflictException] on name conflict when overwrite=false.
  Future<SkillDefinition> importSkillMd(
    String content,
    String fallbackName, {
    bool overwrite = false,
  }) async {
    if (_directoryPath.isEmpty) {
      throw Exception('Skill registry not initialized');
    }
    if (content.trim().isEmpty) {
      throw ArgumentError('Markdown 内容不能为空');
    }

    // Resolve display name: front matter name > # heading > fallback
    final fm = _parseFrontMatter(content);
    final effectiveName = (fm.name != null && fm.name!.isNotEmpty)
        ? fm.name!
        : (_extractHeadingName(content) ?? fallbackName);

    if (effectiveName.trim().isEmpty) {
      throw Exception('无法提取技能名称，请确保 SKILL.md 的 front matter 含 name 字段或包含 # 标题');
    }

    // Conflict check
    final toolName = 'skill_${_sanitizeName(effectiveName)}';
    final existing = getDefinition(toolName);
    if (existing != null && !overwrite) {
      throw SkillImportConflictException(toolName, effectiveName);
    }

    // Write to <skillsDir>/<sanitized>/SKILL.md
    final sanitized = _sanitizeName(effectiveName);
    final destDir = Directory(p.join(_directoryPath, sanitized));
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);

    final destFile = File(p.join(destDir.path, 'SKILL.md'));
    await destFile.writeAsString(content);

    await rescan();

    final newDef = getDefinition(toolName);
    if (newDef == null) {
      throw Exception('导入的技能在重新扫描后未找到，请检查 SKILL.md 格式');
    }
    return newDef;
  }

  /// Deletes a skill by removing its directory and rescanning.
  Future<void> deleteSkill(String toolName) async {
    final def = getDefinition(toolName);
    if (def == null) return;

    final dir = Directory(def.directoryPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    await rescan();
  }

  // ---------------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------------

  /// Whether [name] is a registered skill tool.
  bool isSkillTool(String name) => _skills.any((s) => s.toolName == name);

  /// Lookup a definition by tool name, or null.
  SkillDefinition? getDefinition(String toolName) {
    for (final s in _skills) {
      if (s.toolName == toolName) return s;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Content reading
  // ---------------------------------------------------------------------------

  /// Reads the full markdown content of a skill at call time (not cached).
  Future<String> readSkillContent(String toolName) async {
    final def = getDefinition(toolName);
    if (def == null) return 'Error: skill "$toolName" not found.';
    try {
      final file = File(def.filePath);
      return await file.readAsString();
    } catch (e) {
      return 'Error reading skill file: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // LLM tool formats
  // ---------------------------------------------------------------------------

  /// Returns skills in OpenAI function-calling format.
  List<Map<String, dynamic>> openAITools({Set<String>? enabledSkills}) {
    return _filteredSkills(enabledSkills)
        .map((s) => <String, dynamic>{
              'type': 'function',
              'function': {
                'name': s.toolName,
                'description':
                    '${s.description} — Call this tool to receive detailed instructions for the "${s.displayName}" skill.',
                'parameters': {'type': 'object', 'properties': {}},
              },
            })
        .toList();
  }

  /// Returns skills in Claude (Anthropic) format.
  List<Map<String, dynamic>> claudeTools({Set<String>? enabledSkills}) {
    return _filteredSkills(enabledSkills)
        .map((s) => <String, dynamic>{
              'name': s.toolName,
              'description':
                  '${s.description} — Call this tool to receive detailed instructions for the "${s.displayName}" skill.',
              'input_schema': {'type': 'object', 'properties': {}},
            })
        .toList();
  }

  /// System prompt suffix describing available skills.
  String systemPromptSuffix(Set<String> enabledSkills) {
    final filtered = _filteredSkills(enabledSkills);
    if (filtered.isEmpty) return '';
    final skillLines =
        filtered.map((s) => '- ${s.toolName}: ${s.description}').join('\n');
    return '''

You also have access to skill tools. Each skill provides detailed step-by-step instructions for a specific task.
When you need to perform one of these tasks, call the corresponding skill tool to receive the full instructions.
Available skills:
$skillLines''';
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Iterable<SkillDefinition> _filteredSkills(Set<String>? enabledSkills) {
    if (enabledSkills == null) return _skills;
    return _skills.where((s) => enabledSkills.contains(s.toolName));
  }

  /// Recursively finds the first file named `SKILL.md` (case-insensitive)
  /// using BFS so shallower matches win.
  Future<File?> _findSkillMd(Directory root) async {
    final queue = <Directory>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final List<Directory> subDirs = [];
      for (final entity in current.listSync()) {
        if (entity is File &&
            p.basename(entity.path).toLowerCase() == 'skill.md') {
          return entity;
        }
        if (entity is Directory) {
          subDirs.add(entity);
        }
      }
      // Sort for deterministic traversal
      subDirs.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      queue.addAll(subDirs);
    }
    return null;
  }

  /// Parses a skill subdirectory into a [SkillDefinition].
  ///
  /// Looks for `SKILL.md` at the top level first; falls back to any `.md`
  /// file (recursive) for legacy compatibility.
  Future<SkillDefinition?> _parseSkillDirectory(Directory dir) async {
    try {
      // Prefer SKILL.md at the top level
      File? mainFile;
      for (final entity in dir.listSync()) {
        if (entity is File &&
            p.basename(entity.path).toLowerCase() == 'skill.md') {
          mainFile = entity;
          break;
        }
      }

      // Legacy fallback: first .md file recursively
      if (mainFile == null) {
        final mdFiles = dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
        if (mdFiles.isEmpty) return null;
        mainFile = mdFiles.first;
      }

      final content = await mainFile.readAsString();
      final fm = _parseFrontMatter(content);

      // Resolve display name: front matter > # heading
      final displayName = (fm.name != null && fm.name!.isNotEmpty)
          ? fm.name!
          : _extractHeadingName(content);
      if (displayName == null || displayName.isEmpty) return null;

      // Resolve description: front matter > first non-blank line after heading
      final description = (fm.description != null && fm.description!.isNotEmpty)
          ? fm.description!
          : (_extractHeadingDescription(content) ?? displayName);

      final toolName = 'skill_${_sanitizeName(displayName)}';

      final fileCount =
          dir.listSync(recursive: true).whereType<File>().length;

      return SkillDefinition(
        toolName: toolName,
        displayName: displayName,
        description: description,
        filePath: mainFile.path,
        directoryPath: dir.path,
        fileCount: fileCount,
      );
    } catch (e) {
      return null;
    }
  }

  /// Parses a single legacy `.md` file into a [SkillDefinition].
  Future<SkillDefinition?> _parseSkillFile(File file) async {
    try {
      final content = await file.readAsString();
      final fm = _parseFrontMatter(content);

      final displayName = (fm.name != null && fm.name!.isNotEmpty)
          ? fm.name!
          : _extractHeadingName(content);
      if (displayName == null || displayName.isEmpty) return null;

      final description = (fm.description != null && fm.description!.isNotEmpty)
          ? fm.description!
          : (_extractHeadingDescription(content) ?? displayName);

      // For legacy files the tool name comes from the filename
      final fileName = file.uri.pathSegments.last;
      final baseName = fileName.endsWith('.md')
          ? fileName.substring(0, fileName.length - 3)
          : fileName;
      final toolName = 'skill_${_sanitizeName(baseName)}';

      return SkillDefinition(
        toolName: toolName,
        displayName: displayName,
        description: description,
        filePath: file.path,
        directoryPath: file.parent.path,
        fileCount: 1,
      );
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Front matter & heading parsers
  // ---------------------------------------------------------------------------

  /// Parses YAML front matter delimited by `---` lines.
  ///
  /// Supports only simple scalar key: value pairs (no nested structures).
  /// Returns empty [_FrontMatter] if no front matter is found.
  static _FrontMatter _parseFrontMatter(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines[0].trim() != '---') {
      return const _FrontMatter();
    }

    // Find closing ---
    int closeIndex = -1;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        closeIndex = i;
        break;
      }
    }
    if (closeIndex == -1) return const _FrontMatter();

    String? name;
    String? description;

    for (int i = 1; i < closeIndex; i++) {
      final line = lines[i];
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;
      final key = line.substring(0, colonIdx).trim().toLowerCase();
      final value = line.substring(colonIdx + 1).trim();
      // Strip optional surrounding quotes
      final unquoted = value.length >= 2 &&
              ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'")))
          ? value.substring(1, value.length - 1)
          : value;
      if (key == 'name') name = unquoted;
      if (key == 'description') description = unquoted;
    }

    return _FrontMatter(name: name, description: description);
  }

  /// Extracts the display name from the first `# ` heading in [content].
  static String? _extractHeadingName(String content) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('# ') && !trimmed.startsWith('## ')) {
        final name = trimmed.substring(2).trim();
        return name.isEmpty ? null : name;
      }
    }
    return null;
  }

  /// Extracts description as the first non-blank line after the `# ` heading.
  static String? _extractHeadingDescription(String content) {
    final lines = content.split('\n');
    bool foundHeading = false;
    for (final line in lines) {
      final trimmed = line.trim();
      if (!foundHeading) {
        if (trimmed.startsWith('# ') && !trimmed.startsWith('## ')) {
          foundHeading = true;
        }
        continue;
      }
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Recursively copies all files and subdirectories from [src] to [dest].
  static Future<void> _copyDirectory(Directory src, Directory dest) async {
    for (final entity in src.listSync()) {
      final destPath = p.join(dest.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        final newDir = Directory(destPath);
        await newDir.create(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  /// Sanitizes a name into a valid tool name component.
  static String _sanitizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}
