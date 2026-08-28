import 'dart:convert';

import 'package:flutter/material.dart';

import 'theme.dart';

class StructuredDataView extends StatelessWidget {
  final Object? data;
  final int maxDepth;

  const StructuredDataView({
    super.key,
    required this.data,
    this.maxDepth = 4,
  });

  @override
  Widget build(BuildContext context) => _StructuredNode(
        label: null,
        value: data,
        depth: 0,
        maxDepth: maxDepth,
      );
}

Future<void> showStructuredDataSheet(
  BuildContext context, {
  required String title,
  required Object? data,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: '查看原始数据',
                  icon: const Icon(Icons.data_object, size: 19),
                  onPressed: () => showRawDataDialog(
                    context,
                    title: '$title · 原始数据',
                    data: data,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: StructuredDataView(data: data),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> showRawDataDialog(
  BuildContext context, {
  required String title,
  required Object? data,
}) {
  const encoder = JsonEncoder.withIndent('  ');
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: SelectableText(
            data == null ? '（无数据）' : encoder.convert(data),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _StructuredNode extends StatelessWidget {
  final String? label;
  final Object? value;
  final int depth;
  final int maxDepth;

  const _StructuredNode({
    required this.label,
    required this.value,
    required this.depth,
    required this.maxDepth,
  });

  @override
  Widget build(BuildContext context) {
    if (value is Map) {
      return _map(context, (value as Map).cast<dynamic, dynamic>());
    }
    if (value is List) {
      return _list(context, value as List);
    }
    return _scalar(context);
  }

  Widget _map(BuildContext context, Map map) {
    if (map.isEmpty) return _empty(context, '无数据');
    final entries = map.entries.where((entry) => entry.value != null).toList();
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          _StructuredNode(
            label: _fieldLabel('${entry.key}'),
            value: entry.value,
            depth: depth + 1,
            maxDepth: maxDepth,
          ),
      ],
    );
    if (label == null) return body;
    if (depth >= maxDepth) return _collapsed(context, map);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: depth < 2,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(label!, style: const TextStyle(fontSize: 13)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [body],
      ),
    );
  }

  Widget _list(BuildContext context, List list) {
    if (list.isEmpty) {
      return _empty(context, label == null ? '暂无内容' : '$label：暂无内容');
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < list.length; i++)
          _StructuredNode(
            label: list[i] is Map || list[i] is List ? '第 ${i + 1} 项' : null,
            value: list[i],
            depth: depth + 1,
            maxDepth: maxDepth,
          ),
      ],
    );
    if (label == null) return body;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: depth < 2,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('$label · ${list.length}',
            style: const TextStyle(fontSize: 13)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [body],
      ),
    );
  }

  Widget _scalar(BuildContext context) {
    final text = _formatValue(value);
    if (label == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: TextStyle(color: ZInk.solid(context))),
      );
    }
    final color = _statusColor(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label!,
                style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: color ?? ZInk.solid(context),
                fontWeight: color == null ? FontWeight.w400 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _collapsed(BuildContext context, Object data) => ListTile(
        dense: true,
        title: Text(label ?? '数据'),
        subtitle: Text('包含嵌套数据', style: TextStyle(color: ZInk.muted(context))),
        trailing: const Icon(Icons.data_object, size: 18),
        onTap: () =>
            showRawDataDialog(context, title: label ?? '原始数据', data: data),
      );

  Widget _empty(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(text, style: TextStyle(color: ZInk.muted(context))),
      );
}

String _fieldLabel(String key) =>
    const {
      'title': '标题',
      'status': '状态',
      'phase': '阶段',
      'mode': '模式',
      'model': '模型',
      'provider': '供应商',
      'prompt': '提示词',
      'description': '描述',
      'enabled': '已启用',
      'createdAt': '创建时间',
      'updatedAt': '更新时间',
      'lastActivityAt': '最近活动',
      'workspacePath': '工作区',
      'runCount': '运行次数',
      'nextRunAt': '下次运行',
      'lastRunAt': '上次运行',
      'history': '历史',
      'runs': '运行记录',
      'executions': '执行记录',
      'plans': '计划',
      'steps': '步骤',
      'todos': '待办',
      'items': '项目',
      'files': '文件',
      'additions': '新增行',
      'deletions': '删除行',
      'inputTokens': '输入 Tokens',
      'outputTokens': '输出 Tokens',
      'maxTokens': '最大 Tokens',
      'usedTokens': '已用 Tokens',
    }[key] ??
    key;

String _formatValue(Object? value) {
  if (value == null) return '无';
  if (value is bool) return value ? '是' : '否';
  if (value is num && value > 1000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt())
        .toLocal()
        .toString()
        .substring(0, 19);
  }
  final text = '$value';
  return const {
        'running': '运行中',
        'completed': '已完成',
        'completedSuccess': '已完成',
        'completedInterrupted': '已中断',
        'failed': '失败',
        'error': '错误',
        'cancelled': '已取消',
        'pending': '待处理',
        'in_progress': '进行中',
        'active': '活跃',
        'disabled': '已停用',
      }[text] ??
      text;
}

Color? _statusColor(Object? value) {
  final text = '$value';
  if (text == 'running' || text == 'in_progress' || text == 'active') {
    return ZColors.running;
  }
  if (text.contains('completed') || text == 'success') return ZColors.success;
  if (text == 'failed' || text == 'error') return ZColors.danger;
  if (text == 'cancelled' || text == 'pending') return ZColors.warning;
  return null;
}
