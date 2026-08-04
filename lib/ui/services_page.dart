import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../protocol/zemote_client.dart';

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
            Tab(text: 'MCP / Skills'),
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
          const _McpSkillsHint(),
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
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
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
              OutlinedButton(
                  onPressed: _load, child: const Text('重试')),
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
              child: SelectableText(
                _data == null
                    ? '（空）'
                    : const JsonEncoder.withIndent('  ').convert(_data),
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white54),
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
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white38)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(item),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10.5),
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

class _McpSkillsHint extends StatelessWidget {
  const _McpSkillsHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_outlined,
                size: 40, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'MCP 服务器与 Skills 由桌面端配置驱动。\n可在「设置 → Channel RPC 调试器」中选择\nmcp-sync / skills channel 查看与操作。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }
}
