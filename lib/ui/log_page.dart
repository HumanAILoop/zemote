import 'package:flutter/material.dart';

import '../state/log_store.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    LogStore.instance.addListener(_scrollToBottom);
  }

  @override
  void dispose() {
    LogStore.instance.removeListener(_scrollToBottom);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('协议日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => LogStore.instance.clear(),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: LogStore.instance,
        builder: (context, _) {
          final entries = LogStore.instance.entries;
          if (entries.isEmpty) {
            return const Center(child: Text('暂无日志'));
          }
          return ListView.builder(
            controller: _scrollController,
            itemCount: entries.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                entries[index],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
            ),
          );
        },
      ),
    );
  }
}
