import 'package:flutter/material.dart';

import '../peer/services/hub_she_mind.dart';
import '../service_locator.dart';
import '../services/logger_service.dart';

/// 惜宝的长期记忆。正文存在主机上。
class SheMemoryScreen extends StatefulWidget {
  const SheMemoryScreen({super.key});

  @override
  State<SheMemoryScreen> createState() => _SheMemoryScreenState();
}

class _SheMemoryScreenState extends State<SheMemoryScreen> {
  final _controller = TextEditingController();
  var _loading = true;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await getIt<HubSheMind>().longTermMemory();
      if (!mounted) return;
      setState(() {
        _controller.text = text;
        _loading = false;
      });
    } catch (error) {
      LoggerService().warning('load she memory failed: $error', tag: 'SheMemory');
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有读到主机上的长期记忆')),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await getIt<HubSheMind>().saveLongTermMemory(_controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存到主机')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('惜宝的长期记忆')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  alignLabelWithHint: true,
                  labelText: '长期记忆',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
    );
  }
}
