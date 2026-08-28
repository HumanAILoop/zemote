import 'package:flutter/material.dart';

import '../protocol/automation_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import 'theme.dart';
import 'structured_data_view.dart';

/// Scheduled-task (automation) management for a workspace.
class AutomationsPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String workspaceKey;

  const AutomationsPage({
    super.key,
    required this.session,
    required this.scope,
    required this.workspaceKey,
  });

  @override
  State<AutomationsPage> createState() => _AutomationsPageState();
}

class _AutomationsPageState extends State<AutomationsPage> {
  late final AutomationClient _client;
  List<AutomationEntry> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = AutomationClient(bridge: widget.session, scope: widget.scope);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _client.list();
      if (!mounted) return;
      setState(() {
        _items = list;
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

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _run(Future<dynamic> Function() op, String errPrefix,
      {String? ok}) async {
    try {
      await op();
      if (ok != null) _toast(ok);
      await _load();
    } catch (e) {
      _toast('$errPrefix: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('定时任务'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建定时任务',
            onPressed: _showCreateSheet,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(error: _error!, onRetry: _load)
              : _items.isEmpty
                  ? _EmptyState(onCreate: _showCreateSheet)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, i) => _AutomationTile(
                          entry: _items[i],
                          onToggle: (enabled) => _run(
                            () => _client.setEnabled(
                                _items[i].automationId, enabled),
                            '设置失败',
                          ),
                          onRunNow: () => _run(
                            () => _client.runNow(_items[i].automationId),
                            '执行失败',
                            ok: '已加入执行队列',
                          ),
                          onRestart: () => _run(
                            () => _client.restart(_items[i].automationId),
                            '重启失败',
                          ),
                          onDelete: () => _confirmDelete(_items[i]),
                        ),
                      ),
                    ),
    );
  }

  Future<void> _confirmDelete(AutomationEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除定时任务'),
        content: Text('确定删除「${e.title}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      _run(() => _client.delete(e.automationId), '删除失败', ok: '已删除');
    }
  }

  Future<void> _showCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateAutomationSheet(
        session: widget.session,
        scope: widget.scope,
      ),
    );
    if (created == true) {
      _toast('已创建定时任务');
      _load();
    }
  }
}

class _AutomationTile extends StatelessWidget {
  final AutomationEntry entry;
  final void Function(bool enabled) onToggle;
  final VoidCallback onRunNow;
  final VoidCallback onRestart;
  final VoidCallback onDelete;

  const _AutomationTile({
    required this.entry,
    required this.onToggle,
    required this.onRunNow,
    required this.onRestart,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZInk.tileBorder(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showDetails(context, e),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  e.recurring ? Icons.repeat : Icons.schedule_outlined,
                  size: 16,
                  color: e.enabled ? ZColors.primary : ZInk.faint(context),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.title.isEmpty ? '未命名任务' : e.title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: e.enabled,
                  onChanged: onToggle,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  e.scheduleLabel(),
                  style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
                ),
                const SizedBox(width: 10),
                _StatusChip(entry: e),
                const Spacer(),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert,
                      size: 18, color: ZInk.muted(context)),
                  onSelected: (v) {
                    if (v == 'runNow') onRunNow();
                    if (v == 'restart') onRestart();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'runNow', child: Text('立即执行')),
                    PopupMenuItem(value: 'restart', child: Text('重启')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
            if (e.runCount > 0 || e.lastRunAt > 0 || e.nextRunAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  [
                    if (e.runCount > 0) '已运行 ${e.runCount} 次',
                    if (e.nextRunAt != null && e.enabled)
                      '下次 ${relativeTime(e.nextRunAt)}',
                    if (e.lastRunAt > 0) '上次 ${relativeTime(e.lastRunAt)}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showDetails(BuildContext context, AutomationEntry entry) {
    final history = entry.raw['history'] ??
        entry.raw['runs'] ??
        entry.raw['executions'] ??
        entry.raw['runHistory'];
    showStructuredDataSheet(
      context,
      title: entry.title.isEmpty ? '自动化详情' : entry.title,
      data: {
        'status': entry.lifecycleStatus,
        'enabled': entry.enabled,
        'schedule': entry.scheduleLabel(),
        'prompt': entry.prompt,
        'provider': entry.provider,
        'model': entry.model,
        'mode': entry.mode,
        'thoughtLevel': entry.thoughtLevel,
        'runCount': entry.runCount,
        if (entry.lastRunAt > 0) 'lastRunAt': entry.lastRunAt,
        if (entry.nextRunAt != null) 'nextRunAt': entry.nextRunAt,
        if (history != null) 'history': history,
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  final AutomationEntry entry;

  const _StatusChip({required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final (label, color) = e.enabled
        ? ('已启用', ZColors.success)
        : (e.lifecycleStatus == 'completed'
            ? ('已完成', ZInk.faint(context))
            : ('已停用', ZInk.faint(context)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_outlined, size: 48, color: ZInk.ghost(context)),
          const SizedBox(height: 12),
          Text('还没有定时任务',
              style: TextStyle(fontSize: 14, color: ZInk.muted(context))),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('新建定时任务'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败: $error',
              style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ create sheet

class _CreateAutomationSheet extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const _CreateAutomationSheet({required this.session, required this.scope});

  @override
  State<_CreateAutomationSheet> createState() => _CreateAutomationSheetState();
}

class _CreateAutomationSheetState extends State<_CreateAutomationSheet> {
  final _titleController = TextEditingController();
  final _promptController = TextEditingController();
  String _unit = 'minute'; // minute | hour | day
  int _interval = 30;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  bool _creating = false;
  String? _error;
  WorkspacePrep? _prep;

  @override
  void initState() {
    super.initState();
    _loadPrep();
  }

  Future<void> _loadPrep() async {
    try {
      final prep =
          await widget.session.conversation(widget.scope).prepareWorkspace();
      if (mounted) setState(() => _prep = prep);
    } catch (_) {}
  }

  @override
  void dispose() {
    _titleController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _scheduleRule() {
    switch (_unit) {
      case 'minute':
        return {'unit': 'minute', 'interval': _interval};
      case 'hour':
        return {'unit': 'hour', 'interval': _interval};
      case 'day':
      default:
        return {
          'unit': 'day',
          'interval': 1,
          'hour': _time.hour,
          'minute': _time.minute,
        };
    }
  }

  String _cronExpr() {
    switch (_unit) {
      case 'minute':
        return '*/$_interval * * * *';
      case 'hour':
        return '0 */$_interval * * *';
      case 'day':
      default:
        return '${_time.minute} ${_time.hour} * * *';
    }
  }

  Future<void> _create() async {
    final title = _titleController.text.trim();
    final prompt = _promptController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请填写任务标题');
      return;
    }
    if (prompt.isEmpty) {
      setState(() => _error = '请填写任务内容');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final client =
          AutomationClient(bridge: widget.session, scope: widget.scope);
      final prep = _prep;
      final modelOpt = prep?.option('model');
      final thoughtOpt = prep?.option('thought_level');
      final modelValue =
          '${modelOpt?.currentValue ?? 'builtin:zai-coding-plan/GLM-5.2'}';
      final idx = modelValue.lastIndexOf('/');
      final client_ = await client.create(
        title: title,
        prompt: prompt,
        cronExpr: _cronExpr(),
        model: idx > 0 ? modelValue.substring(idx + 1) : modelValue,
        provider: idx > 0 ? modelValue.substring(0, idx) : 'glm',
        mode: 'build',
        thoughtLevel: '${thoughtOpt?.currentValue ?? 'max'}',
        recurring: true,
        scheduleRule: _scheduleRule(),
        enabled: true,
      );
      if (!mounted) return;
      if (client_.automationId.isEmpty) {
        setState(() {
          _creating = false;
          _error = '创建失败：服务端未返回 automationId';
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('新建定时任务',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '任务标题',
                hintText: '例如：每晚巡检构建状态',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '任务内容（发给 AI 的指令）',
                hintText: '例如：检查构建是否失败，失败则给出原因…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text('执行频率', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final u in const ['minute', 'hour', 'day'])
                  ChoiceChip(
                    label: Text(switch (u) {
                      'minute' => '每 N 分钟',
                      'hour' => '每 N 小时',
                      _ => '每天固定时间',
                    }),
                    selected: _unit == u,
                    onSelected: (_) => setState(() => _unit = u),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_unit != 'day')
              Row(
                children: [
                  const Text('每', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: TextFormField(
                      initialValue: '$_interval',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(isDense: true),
                      onChanged: (v) =>
                          _interval = int.tryParse(v) ?? _interval,
                    ),
                  ),
                  Text(_unit == 'minute' ? ' 分钟' : ' 小时',
                      style: const TextStyle(fontSize: 13)),
                ],
              )
            else
              Row(
                children: [
                  const Text('每天', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      final picked = await showTimePicker(
                          context: context, initialTime: _time);
                      if (picked != null) setState(() => _time = picked);
                    },
                    child: Text(_time.format(context)),
                  ),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(fontSize: 12, color: ZColors.danger)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _creating ? null : _create,
                child: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('创建'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
