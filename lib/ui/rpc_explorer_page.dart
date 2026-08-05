import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/zemote_client.dart';
import 'theme.dart';

/// Raw relay payload explorer: send arbitrary `zcode_type` payloads and
/// inspect the matching response (by requestId).
class RpcExplorerPage extends StatefulWidget {
  final ZemoteClient client;

  const RpcExplorerPage({super.key, required this.client});

  @override
  State<RpcExplorerPage> createState() => _RpcExplorerPageState();
}

class _RpcExplorerPageState extends State<RpcExplorerPage> {
  final _payloadController = TextEditingController(
    text: '{\n  "zcode_type": "workspace-list-request"\n}',
  );
  String _output = '';
  bool _busy = false;

  @override
  void dispose() {
    _payloadController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    Map<String, dynamic> payload;
    try {
      payload = (jsonDecode(_payloadController.text) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      if (!mounted) return;
      setState(() => _output = 'JSON 解析失败: $e');
      return;
    }
    payload['requestId'] ??=
        'explorer-${DateTime.now().millisecondsSinceEpoch}';
    final requestId = payload['requestId'] as String;
    setState(() {
      _busy = true;
      _output = '已发送，requestId=$requestId\n等待响应…';
    });
    try {
      final res = await widget.client.request(
        payload,
        (p) => p['requestId'] == requestId,
        timeout: const Duration(seconds: 20),
      );
      if (!mounted) return;
      setState(() {
        _output = const JsonEncoder.withIndent('  ').convert(res);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _output = '无响应或失败: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RPC 调试器（relay payload）')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _payloadController,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'payload JSON（自动补 requestId）',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send),
              label: const Text('发送'),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: ZInk.ghost(context)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
