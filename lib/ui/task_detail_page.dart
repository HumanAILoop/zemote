import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zemote_client.dart';

/// Task detail via `getTaskSnapshotWithEtag` on the `zcode-task` channel.
class TaskDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final Map<String, dynamic> scope;
  final BridgeSession session;

  const TaskDetailPage({
    super.key,
    required this.task,
    required this.scope,
    required this.session,
  });

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  Object? _snapshot;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.session.channels.call(
        Channels.zcodeTask,
        'getTaskSnapshotWithEtag',
        [
          {
            ...widget.scope,
            'taskId': widget.task['taskId'] ?? widget.task['id'],
          },
        ],
      );
      if (!mounted) return;
      setState(() {
        _snapshot = result is Map ? (result['snapshot'] ?? result) : result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    final title = widget.task['title'] ?? widget.task['taskId'] ?? '任务详情';
    return Scaffold(
      appBar: AppBar(
        title: Text('$title', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Text('加载失败: $_error',
                        style: TextStyle(color: Colors.red.shade200)),
                  SelectableText(
                    _snapshot == null
                        ? '（无快照数据）'
                        : encoder.convert(_snapshot),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ],
              ),
            ),
    );
  }
}
