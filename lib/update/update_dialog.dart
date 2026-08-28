import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../ui/theme.dart';
import 'update_checker.dart';

/// Android-side install support (see `MainActivity.kt`).
const apkChannel = MethodChannel('zemote/update');

/// Prompts the user with the release info. On Android, tapping 更新
/// downloads the APK (with progress) and hands it to the system installer.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info),
  );
}

enum _Phase { prompt, downloading, done }

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;

  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.prompt;
  double _progress = 0;
  String? _error;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _update() async {
    if (!_isAndroid) {
      _openRelease();
      return;
    }
    final supportedAbis =
        await apkChannel.invokeMethod<List<dynamic>>('getSupportedAbis') ??
            const [];
    final asset = selectUpdateAsset(
      widget.info.assets,
      supportedAbis.map((abi) => '$abi').toList(),
    );
    if (asset == null) {
      if (mounted) setState(() => _error = '没有适配当前 CPU 的安装包');
      _openRelease();
      return;
    }
    if (asset.md5Url == null) {
      if (mounted) setState(() => _error = '该安装包缺少 MD5 校验值，请手动下载安装');
      _openRelease();
      return;
    }
    final canInstall =
        await apkChannel.invokeMethod<bool>('canInstall') ?? false;
    if (!canInstall) {
      final go = await _askEnableInstall();
      if (go != true || !mounted) return;
    }
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      final dir = await apkChannel.invokeMethod<String>('getApkDir');
      final checksumResponse = await http
          .get(Uri.parse(asset.md5Url!))
          .timeout(const Duration(seconds: 15));
      if (checksumResponse.statusCode != 200) {
        throw HttpException('校验文件 HTTP ${checksumResponse.statusCode}');
      }
      final expected = parseMd5Hex(checksumResponse.body);
      if (expected == null) throw const FormatException('MD5 校验文件无效');
      final file =
          File('$dir/zemote-${widget.info.latestVersion}-${asset.abi}.apk');
      var valid = await _matchesMd5(file, expected);
      if (!valid) {
        await _download(asset.apkUrl, file.path, (p) {
          if (mounted) setState(() => _progress = p);
        });
        valid = await _matchesMd5(file, expected);
      }
      if (!valid) {
        if (await file.exists()) await file.delete();
        if (mounted) {
          setState(() {
            _phase = _Phase.prompt;
            _error = 'MD5 校验失败，已删除安装包并取消安装';
          });
        }
        return;
      }
      if (!mounted) return;
      final ok = await apkChannel.invokeMethod<bool>('installApk', {
            'path': file.path,
            'deleteAfterInstall': true,
          }) ??
          false;
      setState(() {
        _phase = ok ? _Phase.done : _Phase.prompt;
        _error = ok ? null : '启动系统安装器失败';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.prompt;
          _error = '$e';
        });
      }
    }
  }

  Future<bool> _matchesMd5(File file, String expected) async {
    if (!await file.exists()) return false;
    final actual = (await md5.bind(file.openRead()).first).toString();
    return actual == expected;
  }

  Future<bool?> _askEnableInstall() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要安装权限'),
        content: const Text('Android 8+ 要求先允许「安装未知应用」。'
            '将打开系统设置，请为 Zemote 开启后回来继续。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              apkChannel.invokeMethod('openInstallSettings');
              Navigator.of(context).pop(true);
            },
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }

  Future<void> _download(
    String url,
    String path,
    void Function(double progress) onProgress,
  ) async {
    final client = http.Client();
    try {
      final target = File(path);
      var start = target.existsSync() ? target.lengthSync() : 0;
      http.StreamedResponse res;
      for (var attempt = 0;; attempt++) {
        final request = http.Request('GET', Uri.parse(url));
        if (start > 0) request.headers['Range'] = 'bytes=$start-';
        res = await client.send(request);
        if (res.statusCode != 416 || start == 0 || attempt > 0) break;
        await res.stream.drain<void>();
        await target.delete();
        start = 0;
      }
      final resumed = res.statusCode == 206;
      if (res.statusCode != 200 && !resumed) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      if (start > 0 && !resumed) {
        start = 0;
        target.deleteSync();
      }
      final total = resumed
          ? int.tryParse(RegExp(r'/([0-9]+)\s*$')
                  .firstMatch(res.headers['content-range'] ?? '')
                  ?.group(1) ??
              '')
          : res.contentLength;
      var received = start;
      final sink =
          target.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res.stream) {
          received += chunk.length;
          sink.add(chunk);
          if (total != null && total > 0) onProgress(received / total);
        }
        onProgress(1);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  void _openRelease() {
    Clipboard.setData(ClipboardData(text: widget.info.releaseUrl));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已复制下载链接：${widget.info.releaseUrl}（请打开 GitHub 下载）')));
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final notes = (info.body ?? '').trim();
    return AlertDialog(
      title: Text(
          '发现${info.isPrerelease ? ' Beta ' : ' '}新版本 v${info.latestVersion}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_phase == _Phase.prompt) ...[
              if (notes.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      notes,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                )
              else
                Text(
                  info.isPrerelease ? '这是预发布版本，可能包含实验性功能。' : '有新的 Zemote 版本可用。',
                  style: const TextStyle(fontSize: 13),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text('$_error',
                    style:
                        const TextStyle(fontSize: 12, color: ZColors.danger)),
              ],
            ] else if (_phase == _Phase.downloading) ...[
              Text('正在下载 APK … ${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                ),
              ),
            ] else
              const Text('安装包已下载，请在弹出的系统安装器中确认安装。',
                  style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_phase == _Phase.done ? '关闭' : '稍后'),
        ),
        if (_phase == _Phase.prompt)
          FilledButton(
            onPressed: _update,
            child: Text(_isAndroid ? '立即更新' : '查看发布'),
          ),
      ],
    );
  }
}
