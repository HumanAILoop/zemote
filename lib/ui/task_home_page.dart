import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'automations_page.dart';
import 'channel_explorer_page.dart';
import 'chat_page.dart';
import 'log_page.dart';
import 'main_shell.dart';
import 'rpc_explorer_page.dart';
import 'task_detail_page.dart';
import 'theme.dart';
import 'ui_settings.dart';

List<Map<String, dynamic>> mergeWorkspaceSessionTasks({
  required List<dynamic> channelTasks,
  required List<SessionEntry> sessions,
  required Set<String> archivedIds,
  required Map<String, dynamic> workspace,
}) {
  final bySessionId = <String, Map<String, dynamic>>{
    for (final entry in sessions)
      if (!archivedIds.contains(entry.sessionId))
        entry.sessionId: {
          'taskId': entry.sessionId,
          if (entry.title.isNotEmpty) 'title': entry.title,
          'displayStatus': switch (entry.phase) {
            'running' || 'prewarming' => 'running',
            'completedSuccess' || 'completedInterrupted' => 'completed',
            'error' => 'error',
            'draft' => 'draft',
            _ => entry.phase,
          },
          'lastAssistantPreview': entry.lastAssistantPreview,
          if (entry.lastActivityAt > 0) 'updatedAt': entry.lastActivityAt,
          if (entry.createdAt > 0) 'createdAt': entry.createdAt,
          'hasBackgroundWork': entry.hasBackgroundWork,
          'workspacePath': workspace['workspacePath'],
          if (workspace['workspaceIdentity'] != null)
            'workspaceIdentity': workspace['workspaceIdentity'],
        },
  };
  final merged = <String, Map<String, dynamic>>{};
  for (final task in channelTasks) {
    if (task is! Map || task['taskId'] == null) continue;
    final id = '${task['taskId']}';
    if (archivedIds.contains(id)) continue;
    final session = bySessionId.remove(id);
    merged[id] = {
      ...task.cast<String, dynamic>(),
      if (session != null) ...session,
    };
  }
  merged.addAll(bySessionId);
  return merged.values.toList()
    ..sort((a, b) => ((b['updatedAt'] as num?) ?? 0)
        .compareTo((a['updatedAt'] as num?) ?? 0));
}

/// Task home of one workspace: search, tabs (任务/置顶/已归档), swipe
/// actions, live updates from `workspace-list-updated`.
class TaskHomePage extends StatefulWidget {
  final Map<String, dynamic> workspace;
  final BridgeSession session;
  final ZemoteClient client;
  final List<dynamic> workspaces;
  final VoidCallback onSwitchWorkspace;

  const TaskHomePage({
    super.key,
    required this.workspace,
    required this.session,
    required this.client,
    required this.workspaces,
    required this.onSwitchWorkspace,
  });

  @override
  State<TaskHomePage> createState() => _TaskHomePageState();
}

class _TaskHomePageState extends State<TaskHomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();

  List<dynamic> _tasks = const [];
  List<dynamic> _channelTasks = const [];
  List<dynamic> _pinned = const [];
  List<dynamic> _archived = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  StreamSubscription? _updatedSub;
  ConversationTransport? _convTransport;
  SessionsIndexSubscription? _sessionsSub;

  /// Locally removed/archived task ids (with timestamp). The sessions-index
  /// push lags behind, so merged lists must not resurrect them.
  final Map<String, int> _recentlyRemoved = {};

  /// taskIds the workspace-list marks as archived — the sessions-index
  /// merge must not leak them into the active list.
  final Set<String> _archivedIds = {};

  bool _isRecentlyRemoved(String taskId) {
    final at = _recentlyRemoved[taskId];
    if (at == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - at > 60000) {
      _recentlyRemoved.remove(taskId);
      return false;
    }
    return true;
  }

  void _markRemoved(String taskId) {
    _recentlyRemoved[taskId] = DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, dynamic> get _scope => {
        'workspacePath': widget.workspace['workspacePath'],
        if (widget.workspace['workspaceIdentity'] != null)
          'workspaceIdentity': widget.workspace['workspaceIdentity'],
      };

  String get _workspaceKey => workspaceKeyOf(widget.workspace) ?? '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _convTransport = widget.session.conversation(_scope, onLog: log);
    _subscribeSessionsIndex();
    _updatedSub = widget.client.workspaceListUpdated.listen((result) {
      if (!mounted || result is! Map) return;
      final tasks = result['tasks'];
      if (tasks is! List) return;
      setState(() {
        final byId = <String, Map<String, dynamic>>{};
        for (final t in _channelTasks) {
          if (t is Map && t['taskId'] != null) {
            byId['${t['taskId']}'] = (t).cast<String, dynamic>();
          }
        }
        for (final t in tasks) {
          if (t is! Map || t['taskId'] == null) continue;
          final id = '${t['taskId']}';
          final map = (t).cast<String, dynamic>();
          final taskWorkspace =
              map['workspaceIdentity'] ?? map['workspacePath'];
          final currentWorkspace = widget.workspace['workspaceIdentity'] ??
              widget.workspace['workspacePath'];
          // Global updates may include other workspaces. Accept new ids only
          // when the payload explicitly identifies this workspace.
          if (!byId.containsKey(id) && taskWorkspace != currentWorkspace) {
            continue;
          }
          // Partition by the workspace-list flags: archived tasks belong
          // to the archived tab, never the active list.
          if (map['archived'] == true || map['deleted'] == true) {
            _archivedIds.add(id);
            byId.remove(id);
            continue;
          }
          _archivedIds.remove(id);
          byId[id] = {...?byId[id], ...map};
        }
        _channelTasks = byId.values
            .where((t) => !_isRecentlyRemoved('${t['taskId']}'))
            .toList();
        _rebuildTasks();
      });
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _updatedSub?.cancel();
    _sessionsSub?.dispose();
    super.dispose();
  }

  /// Live sessions-index: enriches tasks with preview text / phase, or
  /// serves as the task list when the channel list is empty.
  Future<void> _subscribeSessionsIndex() async {
    try {
      final sub = await _convTransport!.subscribeSessionsIndex();
      if (!mounted) {
        await sub.dispose();
        return;
      }
      _sessionsSub = sub;
      sub.state.addListener(_mergeSessions);
      _mergeSessions();
    } catch (e) {
      log('[home] sessions-index subscribe failed: $e');
    }
  }

  void _mergeSessions() {
    final sub = _sessionsSub;
    if (sub == null || !mounted) return;
    if (!sub.state.ready) return;
    log('[home] sessions-index ready count=${sub.state.list.length}');
    setState(() {
      _rebuildTasks();
      _loading = false;
      _error = null;
    });
    log('[home] visible tasks count=${_tasks.length}');
  }

  void _rebuildTasks() {
    final sessions = _sessionsSub?.state.list ?? const <SessionEntry>[];
    _tasks = mergeWorkspaceSessionTasks(
      channelTasks: _channelTasks.where((task) {
        if (task is! Map || task['taskId'] == null) return false;
        return !_isRecentlyRemoved('${task['taskId']}');
      }).toList(),
      sessions: sessions.where((entry) {
        return !_isRecentlyRemoved(entry.sessionId) &&
            !_archivedIds.contains(entry.sessionId);
      }).toList(),
      archivedIds: _archivedIds,
      workspace: widget.workspace,
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.session.channels
            .call(Channels.zcodeTask, 'listTasks', [_scope],
                timeout: const Duration(seconds: 12))
            .catchError((Object _) => const []),
        widget.session.channels
            .call(Channels.zcodeTask, 'listPinnedTasks', [_scope],
                timeout: const Duration(seconds: 12))
            .catchError((Object _) => const []),
        widget.session.channels
            .call(Channels.zcodeTask, 'listArchivedTasks', [_scope],
                timeout: const Duration(seconds: 12))
            .catchError((Object _) => const []),
      ]);
      if (!mounted) return;
      log('[home] channel lists tasks=${results[0] is List ? (results[0] as List).length : 0} '
          'pinned=${results[1] is List ? (results[1] as List).length : 0} '
          'archived=${results[2] is List ? (results[2] as List).length : 0}');
      setState(() {
        _channelTasks = results[0] is List ? results[0] : const [];
        _pinned = results[1] is List ? results[1] : const [];
        _archived = results[2] is List ? results[2] : const [];
        _archivedIds
          ..clear()
          ..addAll([
            for (final t in _archived)
              if (t is Map && t['taskId'] != null) '${t['taskId']}',
          ]);
        _loading = false;
        _rebuildTasks();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _taskTitle(dynamic task) {
    if (task is Map) {
      final t = task['title'];
      if (t is String && t.trim().isNotEmpty) return t;
      final id = task['taskId'] ?? task['id'];
      if (id != null) return '$id';
    }
    return '$task';
  }

  String _taskStatus(dynamic task) =>
      task is Map ? '${task['displayStatus'] ?? task['status'] ?? ''}' : '';

  Map<String, dynamic> _taskScope(Map<String, dynamic> task) => {
        'taskId': task['taskId'],
        'workspacePath':
            task['workspacePath'] ?? widget.workspace['workspacePath'],
        if (task['workspaceIdentity'] != null)
          'workspaceIdentity': task['workspaceIdentity']
        else if (widget.workspace['workspaceIdentity'] != null)
          'workspaceIdentity': widget.workspace['workspaceIdentity'],
      };

  void _markRead(Map<String, dynamic> task) {
    final unreadAt = task['unreadAt'];
    widget.session.channels.call(Channels.zcodeTask, 'setTaskUnread', [
      {
        ..._taskScope(task),
        'unread': false,
        if (unreadAt is num) 'expectedUnreadAt': unreadAt,
      },
    ]).catchError((Object e) => log('[task] markRead failed: $e'));
  }

  Future<void> _openTask(Map<String, dynamic> task) async {
    final taskId = task['taskId'] ?? task['id'];
    if (taskId == null) return;
    _markRead(task);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          session: widget.session,
          scope: _scope,
          workspaceKey: _workspaceKey,
          sessionId: '$taskId',
          title: _taskTitle(task),
        ),
      ),
    );
    if (!mounted) return;
    await _load();
    _mergeSessions();
  }

  Future<void> _action(
      Future<dynamic> Function() run, String errorPrefix) async {
    try {
      await run();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$errorPrefix: $e')));
      }
    }
  }

  Future<void> _setPinned(Map<String, dynamic> task, bool pinned) => _action(
        () =>
            widget.session.channels.call(Channels.zcodeTask, 'setTaskPinned', [
          {..._taskScope(task), 'pinned': pinned}
        ]),
        pinned ? '置顶失败' : '取消置顶失败',
      );

  Future<void> _archive(Map<String, dynamic> task) async {
    final taskId = '${task['taskId']}';
    try {
      await widget.session.channels
          .call(Channels.zcodeTask, 'archiveTask', [_taskScope(task)]);
      _markRemoved(taskId);
      setState(() {
        _tasks = _tasks
            .where((t) => t is! Map || '${t['taskId']}' != taskId)
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('归档失败: $e')));
      }
    }
  }

  Future<void> _unarchive(Map<String, dynamic> task) async {
    final taskId = '${task['taskId']}';
    try {
      await widget.session.channels
          .call(Channels.zcodeTask, 'unarchiveTask', [_taskScope(task)]);
      _recentlyRemoved.remove(taskId);
      setState(() {
        _archived = _archived
            .where((t) => t is! Map || '${t['taskId']}' != taskId)
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('取消归档失败: $e')));
      }
    }
  }

  Future<void> _rename(Map<String, dynamic> task) async {
    final controller =
        TextEditingController(text: task['title'] as String? ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名任务'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    await _action(
      () => widget.session.channels.call(Channels.zcodeTask, 'renameTask', [
        {..._taskScope(task), 'title': title}
      ]),
      '重命名失败',
    );
  }

  Future<void> _delete(Map<String, dynamic> task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除任务？'),
        content: Text('将删除「${_taskTitle(task)}」，此操作不可恢复'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ZColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final taskId = '${task['taskId']}';
    try {
      await widget.session.channels
          .call(Channels.zcodeTask, 'deleteTask', [_taskScope(task)]);
      // Optimistic removal + resurrection guard (sessions-index lags).
      _markRemoved(taskId);
      setState(() {
        _tasks = _tasks
            .where((t) => t is! Map || '${t['taskId']}' != taskId)
            .toList();
        _pinned = _pinned
            .where((t) => t is! Map || '${t['taskId']}' != taskId)
            .toList();
        _archived = _archived
            .where((t) => t is! Map || '${t['taskId']}' != taskId)
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  void _showActions(Map<String, dynamic> task, {required bool archived}) {
    final pinned =
        _pinned.any((t) => t is Map && '${t['taskId']}' == '${task['taskId']}');
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!archived) ...[
              ListTile(
                leading:
                    Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(pinned ? '取消置顶' : '置顶'),
                onTap: () {
                  Navigator.pop(context);
                  _setPinned(task, !pinned);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(context);
                  _rename(task);
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('归档'),
                onTap: () {
                  Navigator.pop(context);
                  _archive(task);
                },
              ),
            ] else
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('取消归档'),
                onTap: () {
                  Navigator.pop(context);
                  _unarchive(task);
                },
              ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('查看原始快照'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TaskDetailPage(
                      task: task,
                      scope: _scope,
                      session: widget.session,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: ZColors.danger),
              title: const Text('删除', style: TextStyle(color: ZColors.danger)),
              onTap: () {
                Navigator.pop(context);
                _delete(task);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newChat() async {
    if (_workspaceKey.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          session: widget.session,
          scope: _scope,
          workspaceKey: _workspaceKey,
          title: '新任务',
        ),
      ),
    );
    if (!mounted) return;
    await _load();
    _mergeSessions();
  }

  /// quickPick-style command palette (mirrors the web quickPick).
  void _showCommandPalette() {
    final theme = ThemeControllerProvider.of(context);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_comment_outlined, size: 20),
              title: const Text('新建任务'),
              onTap: () {
                Navigator.pop(context);
                _newChat();
              },
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined, size: 20),
              title: const Text('切换主题'),
              onTap: () {
                Navigator.pop(context);
                final next = switch (theme?.mode) {
                  ThemeMode.dark => ThemeMode.light,
                  ThemeMode.light => ThemeMode.dark,
                  _ => ThemeMode.dark,
                };
                theme?.setMode(next);
              },
            ),
            ListTile(
              leading: const Icon(Icons.terminal, size: 20),
              title: const Text('协议日志'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const LogPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined, size: 20),
              title: const Text('RPC 调试器'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => RpcExplorerPage(client: widget.client)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined, size: 20),
              title: const Text('Channel RPC 调试器'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ChannelExplorerPage(session: widget.session)));
              },
            ),
          ],
        ),
      ),
    );
  }

  List<dynamic> _filtered(List<dynamic> tasks) {
    if (_query.isEmpty) return tasks;
    final q = _query.toLowerCase();
    return tasks.where((t) => _taskTitle(t).toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.workspaces.length > 1
                      ? widget.onSwitchWorkspace
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            workspaceTitle(widget.workspace),
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.workspaces.length > 1)
                          Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.keyboard_arrow_down,
                                color: ZInk.faint(context), size: 20),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.bolt_outlined),
                tooltip: '命令面板',
                onPressed: _showCommandPalette,
              ),
              IconButton(
                icon: const Icon(Icons.add_comment_outlined),
                tooltip: '新建任务',
                onPressed: _newChat,
              ),
              IconButton(
                icon: const Icon(Icons.schedule_outlined),
                tooltip: '定时任务',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AutomationsPage(
                      session: widget.session,
                      scope: _scope,
                      workspaceKey: _workspaceKey,
                    ),
                  ),
                ),
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: tr(context, 'home.search'),
              prefixIcon:
                  Icon(Icons.search, size: 20, color: ZInk.ghost(context)),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '${tr(context, 'home.tab.tasks')} ${_tasks.length}'),
            Tab(text: '${tr(context, 'home.tab.pinned')} ${_pinned.length}'),
            Tab(
                text:
                    '${tr(context, 'home.tab.archived')} ${_archived.length}'),
          ],
        ),
        Expanded(
          child: _loading
              ? const _TaskListSkeleton()
              : _error != null
                  ? Center(child: Text('加载失败: $_error'))
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _TaskList(
                          tasks: _filtered(_tasks),
                          emptyText: tr(context, 'home.empty.tasks'),
                          onRefresh: _load,
                          onOpen: _openTask,
                          onActions: (t) => _showActions(t, archived: false),
                          titleOf: _taskTitle,
                          statusOf: _taskStatus,
                          onPin: (t) => _setPinned(t, true),
                          onArchive: _archive,
                        ),
                        _TaskList(
                          tasks: _filtered(_pinned),
                          emptyText: tr(context, 'home.empty.pinned'),
                          onRefresh: _load,
                          onOpen: _openTask,
                          onActions: (t) => _showActions(t, archived: false),
                          titleOf: _taskTitle,
                          statusOf: _taskStatus,
                          onPin: (t) => _setPinned(t, false),
                          onArchive: _archive,
                        ),
                        _TaskList(
                          tasks: _filtered(_archived),
                          emptyText: tr(context, 'home.empty.archived'),
                          onRefresh: _load,
                          onOpen: _openTask,
                          onActions: (t) => _showActions(t, archived: true),
                          titleOf: _taskTitle,
                          statusOf: _taskStatus,
                          onPin: _unarchive,
                          startIcon: const Icon(Icons.unarchive_outlined,
                              color: ZColors.warning),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _TaskListSkeleton extends StatelessWidget {
  const _TaskListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 180 - (index % 3) * 40.0,
                height: 13,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 120,
                height: 9,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  final List<dynamic> tasks;
  final String emptyText;
  final Future<void> Function() onRefresh;
  final void Function(Map<String, dynamic>) onOpen;
  final void Function(Map<String, dynamic>) onActions;
  final String Function(dynamic) titleOf;
  final String Function(dynamic) statusOf;
  final void Function(Map<String, dynamic>)? onPin;
  final void Function(Map<String, dynamic>)? onArchive;
  final Widget? startIcon;

  const _TaskList({
    required this.tasks,
    required this.emptyText,
    required this.onRefresh,
    required this.onOpen,
    required this.onActions,
    required this.titleOf,
    required this.statusOf,
    this.onPin,
    this.onArchive,
    this.startIcon,
  });

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Center(
              child:
                  Text(emptyText, style: TextStyle(color: ZInk.faint(context))),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: tasks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final raw = tasks[index];
          if (raw is! Map) return const SizedBox.shrink();
          final task = raw.cast<String, dynamic>();
          final status = statusOf(task);
          final unread = task['unreadAt'] != null;
          final preview = task['lastAssistantPreview'] as String?;
          final color = statusColor(status, context);

          Widget tile = Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onOpen(task),
              onLongPress: () => onActions(task),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titleOf(task),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  unread ? FontWeight.w600 : FontWeight.w400,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task['pinned'] == true)
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(Icons.push_pin,
                                  size: 11, color: ZColors.primary),
                            ),
                          if (preview != null && preview.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                preview,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: ZInk.muted(context),
                                    height: 1.35),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (status.isNotEmpty) status,
                              if (task['model'] != null) '${task['model']}',
                              relativeTime(
                                  (task['updatedAt'] as num?)?.toInt()),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: TextStyle(
                                fontSize: 11, color: ZInk.faint(context)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: ZColors.warning, shape: BoxShape.circle),
                      ),
                    // Web/桌面端长按不好触发，提供显式入口
                    IconButton(
                      icon: Icon(Icons.more_vert,
                          size: 18, color: ZInk.faint(context)),
                      tooltip: '更多操作',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onActions(task),
                    ),
                  ],
                ),
              ),
            ),
          );

          if (onPin != null || onArchive != null) {
            tile = Dismissible(
              key: ValueKey('${task['taskId'] ?? 'row-$index'}'),
              direction: onArchive != null
                  ? DismissDirection.horizontal
                  : DismissDirection.startToEnd,
              confirmDismiss: (direction) async {
                // Never actually dismiss the tile; run the action and let
                // the list update itself (returning true without a fresh
                // data load leaves a hole / crashes on duplicate keys).
                if (direction == DismissDirection.startToEnd) {
                  onPin?.call(task);
                } else {
                  onArchive?.call(task);
                }
                return false;
              },
              background: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 20),
                decoration: BoxDecoration(
                  color: ZColors.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: startIcon ??
                    const Icon(Icons.push_pin_outlined, color: ZColors.primary),
              ),
              secondaryBackground: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: ZColors.warning.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child:
                    const Icon(Icons.archive_outlined, color: ZColors.warning),
              ),
              child: tile,
            );
          }
          return tile;
        },
      ),
    );
  }
}
