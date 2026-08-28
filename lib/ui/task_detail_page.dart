import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zemote_client.dart';
import 'structured_data_view.dart';
import 'theme.dart';

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
                  if (_snapshot == null)
                    const Text('暂无快照数据')
                  else
                    _TaskSnapshotSummary(snapshot: _snapshot!),
                  if (_snapshot != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => showRawDataDialog(
                          context,
                          title: '任务快照 · 原始数据',
                          data: _snapshot,
                        ),
                        icon: const Icon(Icons.data_object, size: 16),
                        label: const Text('查看原始数据'),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _TaskSnapshotSummary extends StatelessWidget {
  final Object snapshot;

  const _TaskSnapshotSummary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final data = snapshot is Map
        ? (snapshot as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final control = (data['control'] as Map?)?.cast<String, dynamic>();
    final config = (data['config'] as Map?)?.cast<String, dynamic>();
    final usage = (data['usage'] as Map?)?.cast<String, dynamic>();
    final window = (usage?['contextWindow'] as Map?)?.cast<String, dynamic>();
    final rows = data['rows'];
    final rowList = rows is Map ? rows['window'] as List? : null;
    final fields = <MapEntry<String, Object?>>[
      MapEntry('状态', control?['phase']),
      MapEntry('模型', config?['model']),
      MapEntry('模式', config?['mode']),
      MapEntry('思考等级', config?['thought']),
      MapEntry(
          '已用上下文',
          window == null
              ? null
              : '${window['usedTokens'] ?? 0} / ${window['maxTokens'] ?? 0}'),
      MapEntry('消息数量', rowList?.length),
      MapEntry('总消息数', rows is Map ? rows['totalCount'] : null),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('会话摘要',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final field in fields)
              if (field.value != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(field.key,
                          style: TextStyle(color: ZInk.muted(context))),
                      Flexible(
                        child: Text('${field.value}',
                            textAlign: TextAlign.end,
                            style: TextStyle(color: ZInk.solid(context))),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 8),
            StructuredDataView(data: {
              if (data['goal'] != null) '目标': data['goal'],
              if (data['plan'] != null) '计划': data['plan'],
              if (data['backgroundWorks'] != null)
                '后台任务': data['backgroundWorks'],
            }),
          ],
        ),
      ),
    );
  }
}
