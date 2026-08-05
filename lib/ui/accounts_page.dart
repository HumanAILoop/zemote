import 'package:flutter/material.dart';

import '../protocol/relay_client.dart';
import '../state/account_store.dart';
import '../state/app_session.dart';
import 'log_page.dart';
import 'main_shell.dart';
import 'qr_scan_page.dart';
import 'theme.dart';

/// Home page: multi-account management. Add devices by QR scan or URL,
/// connect/switch between them.
class AccountsPage extends StatefulWidget {
  final AccountStore store;
  final AppSession session;

  const AccountsPage({super.key, required this.store, required this.session});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  @override
  void initState() {
    super.initState();
    if (!widget.store.loaded) {
      widget.store.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴远程控制 URL'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            hintText: 'https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    final account = await widget.store.addUrl(url);
    if (account.params == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL 无法解析，但仍已保存，可稍后编辑')),
      );
    }
  }

  Future<void> _addByScan() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (url == null || url.isEmpty) return;
    await widget.store.addUrl(url);
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('扫码添加'),
              subtitle: const Text('扫描桌面端远程控制二维码'),
              onTap: () {
                Navigator.pop(context);
                _addByScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('粘贴链接添加'),
              subtitle: const Text('输入 https://zcode.z.ai/remote/v4?... 链接'),
              onTap: () {
                Navigator.pop(context);
                _addByUrl();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Account account) async {
    final controller = TextEditingController(text: account.label);
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label != null) await widget.store.rename(account.id, label);
  }

  Future<void> _delete(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除设备？'),
        content: Text('将移除「${account.label}」的连接信息'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (widget.session.isConnected(account.id)) {
        await widget.session.disconnect(account.id);
      }
      await widget.store.remove(account.id);
    }
  }

  /// Open the active device's shell. Already-connected devices switch
  /// instantly without reconnecting.
  Future<void> _open(Account account) async {
    await widget.store.touch(account.id);
    try {
      await widget.session.connect(account);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MainShell(
            session: widget.session,
            store: widget.store,
            onAddDevice: _showAddSheet,
            onDisconnect: () {
              widget.session.disconnect(account.id);
              Navigator.of(context).pop();
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('连接失败: $e')));
    }
  }

  String _stateText(RelayState state) {
    switch (state) {
      case RelayState.connecting:
        return '连接中转服务…';
      case RelayState.authenticating:
        return '认证设备…';
      case RelayState.waiting:
        return '等待桌面端配对…';
      case RelayState.paired:
        return '已配对';
      case RelayState.reconnecting:
        return '重连中…';
      case RelayState.error:
        return '连接失败';
      case RelayState.kicked:
        return '已被踢下线';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.store, widget.session]),
      builder: (context, _) {
        final accounts = widget.store.accounts;
        final session = widget.session;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Zemote 远程控制'),
            actions: [
              IconButton(
                icon: const Icon(Icons.terminal),
                tooltip: '协议日志',
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogPage())),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: session.connectingAny ? null : _showAddSheet,
            icon: const Icon(Icons.add),
            label: const Text('添加设备'),
          ),
          body: accounts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(Icons.desktop_windows_outlined,
                              size: 34,
                              color:
                                  Theme.of(context).colorScheme.primary),
                        ),
                        const SizedBox(height: 20),
                        const Text('还没有设备',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text(
                          '点击右下角「添加设备」，扫码或粘贴链接\n连接你的桌面 ZCode',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: ZInk.faint(context), height: 1.6),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: accounts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isCurrent = session.current?.id == account.id;
                    final client = session.clientOf(account.id);
                    final connecting = session.connecting(account.id);
                    final error = session.errorOf(account.id);
                    final host = account.params?.source.host ?? '';
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? const Color(0xFF22C55E)
                                    .withValues(alpha: 0.15)
                                : Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            isCurrent
                                ? Icons.desktop_windows
                                : Icons.desktop_windows_outlined,
                            size: 20,
                            color: isCurrent
                                ? const Color(0xFF22C55E)
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(account.label),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              host,
                              style: TextStyle(
                                  fontSize: 11, color: ZInk.faint(context)),
                            ),
                            if (client != null)
                              ValueListenableBuilder<RelayState>(
                                valueListenable:
                                    client.relay.stateListenable,
                                builder: (context, state, _) {
                                  if (connecting &&
                                      state != RelayState.paired &&
                                      state != RelayState.error) {
                                    return _PairSteps(state: state);
                                  }
                                  final text = _stateText(state);
                                  if (text.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Text(
                                    text,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: state == RelayState.paired
                                          ? Colors.green
                                          : state == RelayState.error ||
                                                  state == RelayState.kicked
                                              ? Colors.red
                                              : Colors.orange,
                                    ),
                                  );
                                },
                              )
                            else if (error != null)
                              Text(
                                error,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.red),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            else if (connecting)
                              const Text('正在连接…',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.orange))
                            else
                              Text('未连接',
                                  style: TextStyle(
                                      fontSize: 11, color: ZInk.faint(context))),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (connecting)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            else if (client != null)
                              IconButton(
                                icon: Icon(isCurrent
                                    ? Icons.link_off
                                    : Icons.play_arrow),
                                tooltip: isCurrent ? '断开' : '打开',
                                onPressed: () => isCurrent
                                    ? widget.session.disconnect(account.id)
                                    : _open(account),
                              )
                            else
                              IconButton(
                                icon: const Icon(Icons.play_arrow),
                                tooltip: '连接',
                                onPressed: () => _open(account),
                              ),
                            PopupMenuButton<String>(
                              onSelected: (action) {
                                if (action == 'rename') _rename(account);
                                if (action == 'delete') _delete(account);
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'rename', child: Text('重命名')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('删除')),
                              ],
                            ),
                          ],
                        ),
                        onTap: connecting
                            ? null
                            : () => _open(account),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

/// 4-step pairing progress (mirrors the web bootstrap steps).
class _PairSteps extends StatelessWidget {
  final RelayState state;

  const _PairSteps({required this.state});

  static const _steps = ['连接中转', '设备认证', '等待配对', '完成'];

  @override
  Widget build(BuildContext context) {
    final current = switch (state) {
      RelayState.connecting => 0,
      RelayState.authenticating => 1,
      RelayState.waiting => 2,
      _ => 3,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Container(
                width: 10,
                height: 1,
                color: i <= current ? Colors.green : ZInk.ghost(context),
              ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < current
                    ? Colors.green
                    : i == current
                        ? Colors.orange
                        : ZInk.ghost(context),
              ),
            ),
            const SizedBox(width: 3),
            Text(
              _steps[i],
              style: TextStyle(
                fontSize: 9,
                color: i <= current ? ZInk.soft(context) : ZInk.ghost(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
