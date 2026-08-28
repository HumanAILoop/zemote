import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'theme.dart';

class DiagnosticsPage extends StatefulWidget {
  final ZemoteClient? client;
  final BridgeSession? bridge;

  const DiagnosticsPage({
    super.key,
    this.client,
    this.bridge,
  });

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    widget.client?.relay.stateListenable.addListener(_onChanged);
    widget.bridge?.degraded.addListener(_onChanged);
    widget.bridge?.recovered.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.client?.relay.stateListenable.removeListener(_onChanged);
    widget.bridge?.degraded.removeListener(_onChanged);
    widget.bridge?.recovered.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final relay = widget.client?.relay;
    final logs = LogStore.instance.entries
        .where((entry) =>
            entry.contains('[诊断]') ||
            entry.contains('failed') ||
            entry.contains('error'))
        .toList()
        .reversed
        .take(100)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('诊断中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            title: '连接状态',
            rows: [
              _StatusRow('Relay', relay?.state.name ?? '未连接'),
              _StatusRow('Bridge', widget.bridge == null ? '未打开' : '已打开'),
              if (widget.bridge != null)
                _StatusRow('Bridge 类型',
                    '${widget.bridge!.bridge['kind'] ?? 'unknown'}'),
              if (widget.bridge != null)
                _StatusRow('健康状态', widget.bridge!.degraded.value ?? '正常'),
              if (widget.bridge != null)
                _StatusRow('恢复次数', '${widget.bridge!.recovered.value}'),
            ],
          ),
          const SizedBox(height: 12),
          _StatusCard(
            title: '订阅状态',
            rows: [
              _StatusRow(
                  'Conversation', widget.bridge == null ? '未打开' : '按页面订阅'),
              _StatusRow(
                  'Sessions index', widget.bridge == null ? '未打开' : '按工作区订阅'),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final text = [
                'Relay: ${relay?.state.name ?? '未连接'}',
                'Bridge: ${widget.bridge == null ? '未打开' : '已打开'}',
                if (widget.bridge != null)
                  '健康状态: ${widget.bridge!.degraded.value ?? '正常'}',
                ...logs,
              ].join('\n');
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制脱敏诊断信息')));
              }
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('复制诊断摘要'),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('最近诊断',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (logs.isEmpty)
                    Text('暂无诊断记录', style: TextStyle(color: ZInk.muted(context)))
                  else
                    for (final entry in logs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText(
                          entry,
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: entry.contains('[诊断]')
                                  ? ZColors.danger
                                  : ZInk.muted(context)),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final List<_StatusRow> rows;

  const _StatusCard({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(row.label,
                          style: TextStyle(color: ZInk.muted(context))),
                      Text(row.value,
                          style: TextStyle(
                              color: ZInk.solid(context),
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

class _StatusRow {
  final String label;
  final String value;

  const _StatusRow(this.label, this.value);
}
