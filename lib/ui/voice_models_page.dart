import 'package:flutter/material.dart';

import '../voice/voice_model_store.dart';
import '../voice/voice_models.dart';

class VoiceModelsPage extends StatefulWidget {
  const VoiceModelsPage({super.key});

  @override
  State<VoiceModelsPage> createState() => _VoiceModelsPageState();
}

class _VoiceModelsPageState extends State<VoiceModelsPage> {
  final _store = VoiceModelStore();
  final _downloaded = <String, bool>{};
  String? _enabled;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final model in voiceModels) {
      _downloaded[model.id] = await _store.isDownloaded(model);
    }
    _enabled = await _store.enabledModelId();
    if (mounted) setState(() {});
  }

  Future<void> _download(VoiceModelInfo model) async {
    setState(() => _busy = model.id);
    try {
      await _store.download(model);
      _downloaded[model.id] = true;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _enable(VoiceModelInfo model) async {
    await _store.setEnabled(model);
    if (mounted) setState(() => _enabled = model.id);
  }

  Future<void> _delete(VoiceModelInfo model) async {
    await _store.delete(model);
    _downloaded[model.id] = false;
    if (_enabled == model.id) _enabled = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('离线语音输入')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                    '语音仅在本机处理。下载并启用一个模型后，聊天输入框会出现麦克风按钮；识别结果会先填入输入框，不会自动发送。',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 10),
            for (final model in voiceModels) _tile(model),
          ],
        ),
      );

  Widget _tile(VoiceModelInfo model) {
    final downloaded = _downloaded[model.id] == true;
    final enabled = _enabled == model.id;
    final busy = _busy == model.id;
    final progress = _store.progress[model.id] ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            ListTile(
              leading:
                  Icon(enabled ? Icons.check_circle : Icons.record_voice_over),
              title: Text(model.name),
              subtitle: Text('${model.languages} · ${model.description}'),
              trailing: busy
                  ? Text('${(progress * 100).round()}%',
                      style: const TextStyle(fontSize: 11))
                  : PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'download') _download(model);
                        if (action == 'enable') _enable(model);
                        if (action == 'delete') _delete(model);
                      },
                      itemBuilder: (_) => [
                        if (!downloaded)
                          const PopupMenuItem(
                              value: 'download', child: Text('下载模型')),
                        if (downloaded && !enabled)
                          const PopupMenuItem(
                              value: 'enable', child: Text('启用模型')),
                        if (downloaded)
                          const PopupMenuItem(
                              value: 'delete', child: Text('删除模型')),
                      ],
                    ),
            ),
            if (busy)
              LinearProgressIndicator(value: progress == 0 ? null : progress),
          ],
        ),
      ),
    );
  }
}
