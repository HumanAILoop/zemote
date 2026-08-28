import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zemote_client.dart';

import 'theme.dart';
import 'structured_data_view.dart';

/// Read-only overview of managed services (plugins / cron automations).
/// MCP & Skills are desktop-config-driven; use the Channel RPC explorer
/// for those (a hint card is shown).
class ServicesPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const ServicesPage({
    super.key,
    required this.session,
    required this.scope,
  });

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '插件'),
            Tab(text: '定时任务'),
            Tab(text: 'Skills / 命令'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ServiceList(
            loader: () => widget.session.channels.call(
              Channels.zcodeAgent,
              'listPlugins',
              [widget.scope],
            ),
            titleOf: (item) =>
                '${item['name'] ?? item['id'] ?? item['pluginId'] ?? ''}',
            subtitleOf: (item) => [
              '${item['version'] ?? ''}',
              '${item['status'] ?? (item['enabled'] == true ? 'enabled' : '')}',
            ].where((s) => s.isNotEmpty && s != 'null').join(' · '),
          ),
          _ServiceList(
            loader: () => widget.session.channels
                .call(Channels.zcodeAgent, 'listAllAutomations', []),
            titleOf: (item) =>
                '${item['title'] ?? item['name'] ?? item['automationId'] ?? ''}',
            subtitleOf: (item) => [
              '${item['schedule'] ?? item['cron'] ?? ''}',
              if (item['enabled'] != null)
                item['enabled'] == true ? '已启用' : '已停用',
            ].where((s) => s.isNotEmpty && s != 'null').join(' · '),
          ),
          _SkillsCommandsPage(session: widget.session, scope: widget.scope),
        ],
      ),
    );
  }
}

class _ServiceList extends StatefulWidget {
  final Future<dynamic> Function() loader;
  final String Function(Map<String, dynamic>) titleOf;
  final String Function(Map<String, dynamic>) subtitleOf;

  const _ServiceList({
    required this.loader,
    required this.titleOf,
    required this.subtitleOf,
  });

  @override
  State<_ServiceList> createState() => _ServiceListState();
}

class _ServiceListState extends State<_ServiceList>
    with AutomaticKeepAliveClientMixin {
  Object? _data;
  String? _error;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

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
      final res = await widget.loader();
      if (mounted) {
        setState(() {
          _data = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _items {
    final data = _data;
    List? list;
    if (data is List) {
      list = data;
    } else if (data is Map) {
      for (final key in const [
        'items',
        'plugins',
        'automations',
        'installedPlugins',
        'availablePlugins',
      ]) {
        if (data[key] is List) {
          list = data[key] as List;
          break;
        }
      }
    }
    if (list == null) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $_error',
                  style: TextStyle(color: Colors.red.shade200),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final items = _items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            Center(
              child: _data == null
                  ? Text('暂无数据', style: TextStyle(color: ZInk.muted(context)))
                  : Column(
                      children: [
                        StructuredDataView(data: _data),
                        TextButton(
                          onPressed: () => showRawDataDialog(context,
                              title: '服务数据 · 原始数据', data: _data),
                          child: const Text('查看原始数据'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          return Card(
            child: ExpansionTile(
              title: Text(widget.titleOf(item),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(widget.subtitleOf(item),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      StructuredDataView(data: item),
                      TextButton(
                        onPressed: () => showRawDataDialog(context,
                            title: '服务详情 · 原始数据', data: item),
                        child: const Text('查看原始数据'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SkillsCommandsPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;

  const _SkillsCommandsPage({required this.session, required this.scope});

  @override
  State<_SkillsCommandsPage> createState() => _SkillsCommandsPageState();
}

class _SkillsCommandsPageState extends State<_SkillsCommandsPage> {
  List<Map<String, dynamic>> _skills = const [];
  List<Map<String, dynamic>> _commands = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      widget.session.channels.call(
          Channels.skills, 'list', [widget.scope]).catchError((_) => const []),
      widget.session.channels.call(Channels.commands, 'list',
          [widget.scope]).catchError((_) => const []),
    ]);
    if (!mounted) return;
    setState(() {
      _skills = _items(results[0], 'skills');
      _commands = _items(results[1], 'commands');
      _loading = false;
    });
  }

  List<Map<String, dynamic>> _items(Object? value, String key) {
    final list = value is List
        ? value
        : value is Map
            ? value[key]
            : null;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Skills',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_skills.isEmpty) const ListTile(title: Text('暂无 Skills')),
          for (final skill in _skills)
            Card(
              child: ListTile(
                leading: Icon(skill['enabled'] == false
                    ? Icons.toggle_off
                    : Icons.auto_awesome),
                title: Text('${skill['name'] ?? skill['id'] ?? '未命名 Skill'}'),
                subtitle: Text('${skill['description'] ?? ''}'),
                onTap: () => showStructuredDataSheet(context,
                    title: 'Skill 详情', data: skill),
              ),
            ),
          const SizedBox(height: 16),
          const Text('自定义命令',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_commands.isEmpty) const ListTile(title: Text('暂无自定义命令')),
          for (final command in _commands)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title:
                    Text('/${command['name'] ?? command['id'] ?? 'command'}'),
                subtitle: Text(
                    '${command['description'] ?? command['prompt'] ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                onTap: () => showStructuredDataSheet(context,
                    title: '命令详情', data: command),
              ),
            ),
        ],
      ),
    );
  }
}
