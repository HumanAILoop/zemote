import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'diff_view.dart';
import 'markdown_view.dart';
import 'theme.dart';

/// Chat view for one task (session), backed by Conversation V4 subscription.
/// Draft mode (no [sessionId]): the first message issues `createSession`.
class ChatPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String workspaceKey;
  final String? sessionId;
  final String title;

  const ChatPage({
    super.key,
    required this.session,
    required this.scope,
    required this.workspaceKey,
    this.sessionId,
    required this.title,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  _PendingFile(this.fileName, this.mime, this.bytes);
}

/// Removes only the number of confirmed echoes matching each user message.
/// Failed echoes remain visible so the user can retry them.
List<Map<String, dynamic>> removeEchoedTexts(
    List<Map<String, dynamic>> echoes, List<Map<String, dynamic>> rows) {
  final confirmed = <String, int>{};
  for (final row in rows) {
    if (row['kind'] != 'userInput') continue;
    final text = '${row['text'] ?? ''}'.trim();
    confirmed[text] = (confirmed[text] ?? 0) + 1;
  }
  final remaining = <String, int>{...confirmed};
  return echoes.where((echo) {
    if (echo['status'] == 'failed') return true;
    final text = '${echo['text'] ?? ''}'.trim();
    final count = remaining[text] ?? 0;
    if (count == 0) return true;
    remaining[text] = count - 1;
    return false;
  }).toList();
}

class _ChatPageState extends State<ChatPage> {
  late final ConversationTransport _transport;
  ConversationSubscription? _subscription;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sessionId;
  String? _error;
  bool _sending = false;
  final List<Map<String, dynamic>> _echoes = [];

  void _dedupeEchoes() {
    final state = _state;
    if (state == null || _echoes.isEmpty) return;
    final kept = removeEchoedTexts(_echoes, state.rows);
    if (kept.length != _echoes.length && mounted) {
      setState(() {
        _echoes
          ..clear()
          ..addAll(kept);
      });
    }
  }

  bool _loadingOlder = false;
  bool _showSlash = false;
  String? _progress;
  final List<_PendingFile> _pendingFiles = [];
  double? _uploadProgress;
  WorkspacePrep? _prep;
  List<SkillEntry> _skills = [];
  bool _skillsLoading = false;

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;

  ConversationState? get _state => _subscription?.state;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _transport = widget.session.conversation(widget.scope);
    _scrollController.addListener(_onScroll);
    if (_sessionId != null) {
      _subscribe();
    }
    _loadPrep();
    _inputController.addListener(() {
      final text = _inputController.text;
      final show = (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _stickToBottom = _scrollController.position.pixels >= max - 40;
  }

  Future<void> _loadPrep() async {
    try {
      final prep = await _transport.prepareWorkspace();
      if (mounted) setState(() => _prep = prep);
    } catch (_) {}
    setState(() => _skillsLoading = true);
    try {
      final skills = await _transport.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
  }

  @override
  void dispose() {
    _subscription?.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sub = await _transport
          .subscribe(sessionId)
          .timeout(const Duration(seconds: 60));
      if (!mounted) {
        await sub.dispose();
        return;
      }
      setState(() {
        _subscription = sub;
        _error = null;
      });
      sub.state.addListener(_scrollToBottom);
      sub.state.addListener(_dedupeEchoes);
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The official client shows the full history immediately, so
      // auto-load the missing older rows once on open.
      if (sub.state.canLoadOlder) {
        await _loadOlder();
      }
      // Initial snapshots and auto-loaded history can change the list height
      // over multiple frames. Force the first open to the newest message;
      // later streaming updates still use the conditional follow behavior.
      _jumpToLatest();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      // Snap to the newest message on open; afterwards only follow while the
      // user is already near the bottom (so reading history isn't yanked).
      if (_stickToBottom || _scrollController.position.pixels > max - 400) {
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _jumpToLatest() {
    _stickToBottom = true;
    void jump() {
      if (!mounted || !_stickToBottom || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
    Future<void>.delayed(const Duration(milliseconds: 100), jump);
    Future<void>.delayed(const Duration(milliseconds: 300), jump);
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    try {
      final res = await run();
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        _toast('$errorPrefix: ${res['reasonCode'] ?? res['status']}');
      }
    } catch (e) {
      _toast('$errorPrefix: $e');
    }
  }

  /// Opens an auxiliary (side) chat attached to the current session
  /// (`createSelectionSideSession`) in a fresh ChatPage.
  Future<void> _openSideChat() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sideId = await _transport.createSelectionSideSession(sessionId);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatPage(
            session: widget.session,
            scope: widget.scope,
            workspaceKey: widget.workspaceKey,
            sessionId: sideId,
            title: '辅助对话',
          ),
        ),
      );
    } catch (e) {
      _toast('打开辅助对话失败: $e');
    }
  }

  // ------------------------------------------------------------ sending

  String _guessMime(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'md' || 'log' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickFiles() async {
    try {
      final result =
          await FilePicker.pickFiles(withData: true, allowMultiple: true);
      if (result == null) return;
      setState(() {
        for (final file in result.files) {
          final bytes = file.bytes;
          if (bytes == null) continue;
          _pendingFiles
              .add(_PendingFile(file.name, _guessMime(file.name), bytes));
        }
      });
    } catch (e) {
      _toast('选择文件失败: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _uploadFiles(
      List<_PendingFile> files, String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      uploaded.add(await _transport.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (progress) {
          if (mounted) {
            setState(() => _uploadProgress = (i + progress) / files.length);
          }
        },
      ));
    }
    return uploaded;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('压缩失败', () => _transport.compact(_requireSession()));
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('暂停目标失败', () => _transport.pauseGoal(_requireSession()));
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('恢复目标失败', () => _transport.resumeGoal(_requireSession()));
      return;
    }

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it.
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
    }

    final echo = <String, dynamic>{
      'text': text,
      'isGoal': text.startsWith('/goal '),
      'status': 'sending',
      'ts': DateTime.now().millisecondsSinceEpoch,
      'files': List<_PendingFile>.from(_pendingFiles),
      'attachments': null,
    };
    setState(() {
      _echoes.add(echo);
      _sending = true;
      _uploadProgress = null;
      _showSlash = false;
      _progress = null;
    });
    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms)
        setState(() => _progress = '正在创建会话（首次可能需要预热）…');
        final sw = Stopwatch()..start();
        // Plain text first message is sent WITH createSession (firstInput,
        // mirrors the official composer). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final echoFiles = echo['files'] as List<_PendingFile>;
        final canUseFirstInput = text.isNotEmpty &&
            echoFiles.isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        try {
          sessionId = await _transport.createSession(
            widget.workspaceKey,
            firstText: canUseFirstInput ? text : null,
            config: _buildDraftConfig(),
            timeout: const Duration(seconds: 90),
          );
          if (!mounted) return;
        } catch (e) {
          log('[chat] createSession failed after '
              '${sw.elapsedMilliseconds}ms: $e');
          rethrow;
        }
        log('[chat] createSession ok in ${sw.elapsedMilliseconds}ms');
        _sessionId = sessionId;
        // 2) subscribe in the background — must NOT block sending
        setState(() => _progress = null);
        if (canUseFirstInput) {
          // Message already sent with the session; just display history.
          echo['status'] = 'sent';
          _inputController.clear();
          setState(() => _pendingFiles.clear());
          _subscribe();
          return;
        }
        // Attachments / goal commands: the follow-up command needs an active
        // subscription, so wait for it before proceeding.
        await _subscribe();
      }
      if (text.startsWith('/goal ')) {
        final res = await _transport.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (_ackRejected(res)) {
          echo['status'] = 'failed';
          echo['error'] = _ackReason(res);
          _toast('发送失败: ${_ackReason(res)}');
          return;
        }
        echo['status'] = 'sent';
        _inputController.clear();
        return;
      }
      List<Map<String, dynamic>>? attachments;
      final echoFiles = echo['files'] as List<_PendingFile>;
      if (echoFiles.isNotEmpty) {
        setState(() => _progress = '正在上传附件…');
        attachments = await _uploadFiles(echoFiles, sessionId);
        echo['attachments'] = attachments;
        setState(() => _progress = null);
      }
      final res = await _transport.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (_ackRejected(res)) {
        echo['status'] = 'failed';
        echo['error'] = _ackReason(res);
        _toast('发送失败: ${_ackReason(res)}');
        return;
      }
      echo['status'] = 'sent';
      _inputController.clear();
      setState(() => _pendingFiles.clear());
    } catch (e) {
      echo['status'] = 'failed';
      echo['error'] = '$e';
      _toast('发送失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _uploadProgress = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _retryEcho(Map<String, dynamic> echo) async {
    if (_sending) return;
    setState(() {
      echo['status'] = 'sending';
      echo['error'] = null;
      _sending = true;
    });
    try {
      final sessionId = _sessionId;
      if (sessionId == null) throw StateError('尚无会话');
      final files =
          (echo['files'] as List?)?.whereType<_PendingFile>().toList() ??
              const <_PendingFile>[];
      List<Map<String, dynamic>>? attachments = (echo['attachments'] as List?)
          ?.whereType<Map>()
          .map(
            (item) => item.cast<String, dynamic>(),
          )
          .toList();
      if (files.isNotEmpty && attachments == null) {
        attachments = await _uploadFiles(files, sessionId);
        echo['attachments'] = attachments;
      }
      final text = '${echo['text'] ?? ''}';
      final res = echo['isGoal'] == true
          ? await _transport.sendGoalCommand(
              sessionId,
              text.substring('/goal '.length).trim(),
            )
          : await _transport.sendText(
              sessionId,
              text,
              attachments: attachments,
            );
      if (_ackRejected(res)) {
        throw StateError(_ackReason(res));
      }
      if (mounted) setState(() => echo['status'] = 'sent');
    } catch (e) {
      if (mounted) {
        setState(() {
          echo['status'] = 'failed';
          echo['error'] = '$e';
        });
        _toast('重试失败: $e');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _ackRejected(dynamic res) =>
      res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate';

  String _ackReason(dynamic res) {
    if (res is! Map) return '$res';
    return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError('尚无会话');
    return sessionId;
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    if (_draftConfig.isEmpty) return null;
    final config = <String, dynamic>{};
    final modelValue = _draftConfig['model'];
    if (modelValue != null && modelValue.isNotEmpty) {
      final idx = modelValue.lastIndexOf('/');
      if (idx > 0) {
        config['provider'] = modelValue.substring(0, idx);
        config['model'] = modelValue.substring(idx + 1);
      }
    }
    if (_draftConfig['thought'] != null) {
      config['thought'] = _draftConfig['thought'];
    }
    if (_draftConfig['mode'] != null) {
      config['mode'] = _draftConfig['mode'];
    }
    return config.isEmpty ? null : config;
  }

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有排队中的消息'),
        content: const Text('立即发送将清空排队消息并插队执行'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: const Text('排队发送'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await _transport.rowsRange(
        sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      List? rows;
      int? firstRowId;
      bool? hasMore;
      if (res is Map) {
        final rowsObj = res['rows'];
        if (rowsObj is Map) {
          rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
          firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
          hasMore = rowsObj['hasMore'] as bool?;
        } else if (rowsObj is List) {
          rows = rowsObj;
        }
        rows ??= res['items'] as List? ?? res['window'] as List?;
        firstRowId ??= (res['firstRowId'] as num?)?.toInt();
        hasMore ??= res['hasMore'] as bool?;
      } else if (res is List) {
        rows = res;
      }
      if (rows != null && rows.isNotEmpty) {
        final older = rows
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
          ..sort((a, b) =>
              ((a['rowId'] as num?) ?? 0).compareTo((b['rowId'] as num?) ?? 0));
        state.prependOlderRows(older, firstRowId);
        if (hasMore == false) state.historyExhausted = true;
        // Prepending shifts the content above; keep the newest message in
        // view when the user is pinned to the bottom.
        if (_stickToBottom) _scrollToBottom();
      } else if (state.rows.isNotEmpty) {
        if (hasMore == false) state.historyExhausted = true;
        _toast('没有更早的消息了');
      }
    } catch (e) {
      _toast('加载失败: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  // ------------------------------------------------------------ sheets

  void _showModelSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelModeSheet(
        state: _state,
        transport: _transport,
        prep: _prep,
        sessionId: _sessionId,
        draftConfig: _draftConfig,
        onDraftChange: (key, value) {
          setState(() => _draftConfig[key] = value);
        },
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<_SlashItem> get _slashItems {
    final items = <_SlashItem>[];
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(_SlashItem(
        name: c.name,
        description: c.description,
        insert: '/${c.name} ',
        isSkill: false,
      ));
    }
    for (final s in _skills) {
      items.add(_SlashItem(
        name: s.name,
        description: s.description ??
            (s.argumentHint != null ? '${s.argumentHint}' : ''),
        insert: '\$${s.name} ',
        isSkill: true,
      ));
    }
    return items;
  }

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  void _openSkillsPicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SkillsPickerSheet(
        skills: _skills,
        loading: _skillsLoading,
        onSelect: (skill) {
          _inputController.text = '\$${skill.name} ';
          _inputController.selection =
              TextSelection.collapsed(offset: _inputController.text.length);
          Navigator.of(context).pop();
          setState(() => _showSlash = false);
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  void _showUsageSheet() {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => _UsageSheet(
        state: state,
        session: widget.session,
        scope: widget.scope,
        sessionId: sessionId,
      ),
    );
  }

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await _transport.plans(sessionId);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '计划', data: plans),
      );
    } catch (e) {
      _toast('获取计划失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            if (state != null)
              AnimatedBuilder(
                animation: state,
                builder: (context, _) => Text(
                  [
                    if (state.phase.isNotEmpty) state.phase,
                    state.currentModel,
                    if (state.currentThought.isNotEmpty) state.currentThought,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                ),
              ),
          ],
        ),
        actions: [
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => state.isRunning
                  ? IconButton(
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: ZColors.danger),
                      tooltip: '停止',
                      onPressed: () =>
                          _run('停止失败', () => _transport.stop(_sessionId!)),
                    )
                  : const SizedBox.shrink(),
            ),
          if (_sessionId != null)
            IconButton(
              icon: const Icon(Icons.quickreply_outlined, size: 20),
              tooltip: '辅助对话',
              onPressed: _openSideChat,
            ),
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: '模型 / 模式',
            onPressed: _showModelSheet,
          ),
          if (state != null)
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'compact':
                    _run('压缩失败', () => _transport.compact(_sessionId!));
                  case 'usage':
                    _showUsageSheet();
                  case 'plans':
                    _showPlansSheet();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'compact', child: Text('压缩上下文 (compact)')),
                PopupMenuItem(value: 'usage', child: Text('用量统计')),
                PopupMenuItem(value: 'plans', child: Text('计划')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title:
                    Text('订阅失败: $_error', style: const TextStyle(fontSize: 12)),
                trailing:
                    TextButton(onPressed: _subscribe, child: const Text('重试')),
              ),
            ),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => _ContextUsageBar(state: state),
            ),
          Expanded(
            child: state == null
                ? Center(
                    child: _sessionId == null
                        ? Text('输入消息开始新会话',
                            style: TextStyle(color: ZInk.faint(context)))
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedBuilder(
                        animation: state,
                        builder: (context, _) {
                          final groups = _groupRows(state.rows);
                          final itemCount = groups.length +
                              _echoes.length +
                              (state.canLoadOlder ? 1 : 0);
                          if (groups.isEmpty &&
                              _echoes.isEmpty &&
                              !state.canLoadOlder) {
                            return Center(
                                child: Text('暂无消息',
                                    style:
                                        TextStyle(color: ZInk.faint(context))));
                          }
                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (state.canLoadOlder && index == 0) {
                                return Center(
                                  child: TextButton.icon(
                                    onPressed:
                                        _loadingOlder ? null : _loadOlder,
                                    icon: _loadingOlder
                                        ? const SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.5),
                                          )
                                        : const Icon(Icons.history, size: 14),
                                    label: const Text('加载更早消息',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                );
                              }
                              final contentIndex =
                                  index - (state.canLoadOlder ? 1 : 0);
                              if (contentIndex >= groups.length) {
                                final echo =
                                    _echoes[contentIndex - groups.length];
                                return _UserBubble(
                                  row: {
                                    'kind': 'userInput',
                                    'text': echo['text'],
                                    'attachments': echo['attachments'],
                                  },
                                  transport: _transport,
                                  sessionId: _sessionId ?? '',
                                  badge: '${echo['status'] ?? 'sending'}',
                                  onRetry: echo['status'] == 'failed'
                                      ? () => _retryEcho(echo)
                                      : null,
                                );
                              }
                              final group = groups[contentIndex];
                              return _TurnGroupWidget(
                                rows: group,
                                transport: _transport,
                                sessionId: _sessionId ?? '',
                                onAction: _run,
                                state: state,
                              );
                            },
                          );
                        },
                      ),
          ),
          _ReconnectBanner(bridge: _transport.session),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GoalBanner(state: state),
                  _BackgroundWorksBar(state: state),
                  _QueueBar(state: state, transport: _transport),
                  _PendingInteractions(state: state, transport: _transport),
                ],
              ),
            ),
          if (_showSlash)
            _SlashCommandBar(
              query: _inputController.text,
              items: _slashItems,
              onSelect: (item) {
                if (item.name == 'compact') {
                  _inputController.text = '/compact';
                  _send();
                } else {
                  _inputController.text = item.insert;
                  _inputController.selection = TextSelection.collapsed(
                      offset: _inputController.text.length);
                  setState(() => _showSlash = false);
                }
              },
            ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Text(_progress!,
                      style:
                          TextStyle(fontSize: 11, color: ZInk.muted(context))),
                ],
              ),
            ),
          if (_pendingFiles.isNotEmpty)
            _PendingFilesBar(
              files: _pendingFiles,
              uploadProgress: _uploadProgress,
              onRemove: (i) => setState(() => _pendingFiles.removeAt(i)),
            ),
          _InputBar(
            controller: _inputController,
            sending: _sending,
            onSend: _send,
            onAttach: _pickFiles,
            onSkills: _openSkillsPicker,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- rows

/// Shows while the bridge is degraded (relay drop / recovery in progress)
/// so the user knows a send may be paused waiting to reconnect.
class _ReconnectBanner extends StatelessWidget {
  final BridgeSession bridge;

  const _ReconnectBanner({required this.bridge});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: bridge.degraded,
      builder: (context, degraded, _) {
        if (degraded == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: ZColors.warning.withValues(alpha: 0.15),
          child: Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('连接已断开，正在自动重连…',
                    style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One ordered piece of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  bool streaming,
});

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

AssistantTurnParts assistantTurnParts(List<Map<String, dynamic>> rows) {
  final parts = <AssistantPart>[];
  Map<String, dynamic>? header;
  StringBuffer? buf;
  Map<String, dynamic>? template;
  var anyStream = false;
  var sawStreaming = false;

  void flushText() {
    if (template != null) {
      final text = buf!.toString().trim();
      if (text.isNotEmpty) {
        parts.add(
            (kind: 'text', text: text, row: template, streaming: anyStream));
      }
      buf = null;
      template = null;
      anyStream = false;
    }
  }

  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'assistantText') {
      template ??= row;
      buf ??= StringBuffer();
      final t = row['text'] as String? ?? '';
      if (buf!.isNotEmpty) buf!.write('\n\n');
      buf!.write(t);
      if (row['state'] == 'streaming') {
        anyStream = true;
        sawStreaming = true;
      }
    } else if (kind == 'turnHeader') {
      header = row;
    } else {
      flushText();
      parts.add((kind: 'row', text: null, row: row, streaming: false));
    }
  }
  flushText();
  return (parts: parts, header: header, streaming: sawStreaming);
}

/// Groups rows into turns (mirrors the web timeline): a user message starts
/// a new group; assistant text/reasoning/tool rows that follow belong to
/// the same turn and render as ONE message instead of many bubbles.
///
/// A new group starts only on a user message (or the first assistant row
/// after one). Consecutive assistant rows are merged into a single group
/// EVEN IF the server bumps `turnId` mid-response, so one answer never
/// splits into several bubbles each carrying its own feedback buttons.
List<List<Map<String, dynamic>>> _groupRows(List<Map<String, dynamic>> rows) {
  final groups = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>>? current;
  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'timelineMarker') {
      current = null;
      groups.add([row]);
      continue;
    }
    final isUser = kind == 'userInput';
    final startsGroup =
        isUser || current == null || current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

class _TurnGroupWidget extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  const _TurnGroupWidget({
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    if (first['kind'] == 'userInput') {
      // user message + anything attached to the same turn
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RowWidget(
            row: first,
            transport: transport,
            sessionId: sessionId,
            onAction: onAction,
            state: state,
          ),
          for (final row in rows.skip(1))
            _RowWidget(
              row: row,
              transport: transport,
              sessionId: sessionId,
              onAction: onAction,
              state: state,
            ),
        ],
      );
    }
    // assistant turn: render parts in original order (reasoning → text →
    // tool → text …); feedback buttons appear only on the LAST text segment.
    final parts = assistantTurnParts(rows);
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    final children = <Widget>[];
    for (var i = 0; i < parts.parts.length; i++) {
      final p = parts.parts[i];
      if (p.kind == 'text') {
        children.add(_RowWidget(
          row: {
            ...?p.row,
            'kind': 'assistantText',
            'text': p.text,
            if (p.streaming) 'state': 'streaming',
          },
          showFeedback: i == lastTextIdx,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      } else {
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      }
    }
    final header = parts.header;
    if (header != null) children.add(_TurnHeader(row: header));
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _RowWidget extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool showFeedback;

  const _RowWidget({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.showFeedback = true,
  });

  Map<String, dynamic> get _target => {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == 'userInput')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑并重发'),
                onTap: () {
                  Navigator.pop(context);
                  _editQuery(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.replay, size: 20),
              title: const Text('重试本轮 (retryTurn)'),
              onTap: () {
                Navigator.pop(context);
                onAction('重试失败', () => transport.retryTurn(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: const Text('分叉对话 (fork)'),
              onTap: () {
                Navigator.pop(context);
                onAction(
                    '分叉失败', () => transport.forkAssistant(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: const Text('回滚文件到此 (rewind)'),
              onTap: () {
                Navigator.pop(context);
                _confirmRewind(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.difference_outlined, size: 20),
              title: const Text('查看文件变更'),
              onTap: () {
                Navigator.pop(context);
                _showFileChanges(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editQuery(BuildContext context) async {
    final controller =
        TextEditingController(text: row['text'] as String? ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('重发')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    await onAction(
        '编辑失败', () => transport.editUserQuery(sessionId, _target, text));
  }

  Future<void> _confirmRewind(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回滚文件？'),
        content: const Text('将把此消息之后产生的文件变更回滚，对话保留'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onAction('回滚失败', () => transport.applyFileRewind(sessionId, _target));
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      final changes = await transport.fileChanges(
        sessionId,
        target: _target,
      );
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _JsonSheet(title: '文件变更', data: changes),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' =>
        _UserBubble(row: row, transport: transport, sessionId: sessionId),
      'assistantText' => _AssistantBubble(
          row: row,
          transport: transport,
          sessionId: sessionId,
          state: state,
          showFeedback: showFeedback),
      'reasoning' => _ReasoningTile(
          text: row['text'] as String? ?? '',
          streaming: row['state'] == 'streaming'),
      'toolCall' => _ToolCallTile(row: row),
      'turnHeader' => _TurnHeader(row: row),
      'subagent' => _SubagentTile(row: row),
      'timelineMarker' => _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

class _UserBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final String? badge;
  final VoidCallback? onRetry;

  const _UserBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    this.badge,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final attachments = row['attachments'];
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 56, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: ZColors.primary.withValues(alpha: 0.22),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (attachments is List)
              for (final a in attachments)
                if (a is Map)
                  _AttachmentView(
                    attachment: a.cast<String, dynamic>(),
                    transport: transport,
                    sessionId: sessionId,
                  ),
            if (text.isNotEmpty)
              SelectableText(text,
                  style: TextStyle(
                      fontSize: 14, height: 1.5, color: ZInk.solid(context))),
            if (badge != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(badge!,
                      style:
                          TextStyle(fontSize: 10, color: ZInk.faint(context))),
                  if (onRetry != null)
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.only(left: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('重试', style: TextStyle(fontSize: 10)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ConversationTransport transport;
  final String sessionId;

  const _AttachmentView({
    required this.attachment,
    required this.transport,
    required this.sessionId,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  Future<void> _load() async {
    final ref = widget.attachment['ref'] as String?;
    if (ref == null) return;
    try {
      final res =
          await widget.transport.attachmentRead(widget.sessionId, ref: ref);
      if (mounted) setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = '${widget.attachment['fileName'] ?? '附件'}';
    if (!_isImage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(fileName,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Text('[图片加载失败] $fileName',
          style: TextStyle(fontSize: 11, color: ZInk.faint(context)));
    }
    if (_imageBytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _imageBytes!,
          width: 220,
          cacheWidth: 440,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;

  const _AssistantBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    transport.setAssistantFeedback(
      sessionId,
      {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      },
      value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZemoteMarkdown(text),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else ...[
                  _FeedbackButton(
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon,
          size: 15, color: active ? ZColors.primary : ZInk.ghost(context)),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ReasoningTile extends StatelessWidget {
  final String text;
  final bool streaming;

  const _ReasoningTile({required this.text, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: ZInk.reasoningPanel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.reasoningBorder(context)),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: ZColors.running,
        collapsedIconColor: ZInk.muted(context),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Icon(Icons.psychology_outlined,
                size: 14, color: streaming ? ZColors.running : ZColors.primary),
            const SizedBox(width: 6),
            Text(
              streaming ? '思考中…' : '思考过程',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZInk.solid(context)),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ZemoteMarkdown(text, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ToolCallTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ToolCallTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final toolName = row['toolName'] as String? ?? 'tool';
    final status = row['status'] as String? ?? '';
    final inputText = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);

    final (icon, color) = switch (status) {
      'running' || 'inputStreaming' || 'pendingApproval' => (
          Icons.hourglass_top,
          ZColors.running
        ),
      'success' => (Icons.check, ZColors.success),
      'error' => (Icons.error_outline, ZColors.danger),
      'cancelled' => (Icons.block, ZColors.warning),
      _ => (Icons.build_outlined, ZInk.faint(context)),
    };

    final images = display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: ZInk.panel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            initiallyExpanded: status == 'running' ||
                status == 'inputStreaming' ||
                status == 'pendingApproval',
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            iconColor: color,
            collapsedIconColor: ZInk.muted(context),
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(icon, size: 15, color: color),
            title: Text(toolName,
                style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: ZInk.solid(context))),
            subtitle: Text(status,
                style: TextStyle(fontSize: 10.5, color: ZInk.muted(context))),
            children: [
              if (inputText.isNotEmpty) _kv(context, '输入', inputText),
              if (outputText.isNotEmpty) _kv(context, '输出', outputText),
              if (error is Map)
                _kv(context, '错误',
                    '${error['code'] ?? ''} ${error['message'] ?? ''}'),
            ],
          ),
          if (progress is Map) _ProgressRow(progress: progress),
          if (diff != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: DiffView(diff: diff),
            ),
          for (final image in images)
            if (image is Map && image['base64'] is String)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(image['base64'] as String),
                    cacheWidth: (MediaQuery.sizeOf(context).width * 2).round(),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    // Pretty-print JSON input when possible (official shows structured view)
    var display = value;
    try {
      final decoded = jsonDecode(value);
      display = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 10.5, color: ZInk.faint(context))),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ZInk.codeBlockBg(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              display.length > 4000
                  ? '${display.substring(0, 4000)}…'
                  : display,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: ZInk.solid(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map progress;

  const _ProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final preview = progress['previewLine'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                if (preview.isNotEmpty) preview,
                '${(bytes / 1024).toStringAsFixed(1)} KB',
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TurnHeader extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TurnHeader({required this.row});

  String _fmtDuration(int? ms) {
    if (ms == null) return '';
    if (ms < 1000) return '${ms}ms';
    final s = ms / 1000;
    if (s < 60) return '${s.toStringAsFixed(1)}s';
    final m = s ~/ 60;
    return '${m}m${(s % 60).round()}s';
  }

  @override
  Widget build(BuildContext context) {
    final state = row['state'] as String? ?? '';
    final fileChanges = row['fileChanges'];
    final duration = _fmtDuration((row['activeMs'] as num?)?.toInt());

    String stats = '';
    if (fileChanges is Map) {
      final adds = fileChanges['additions'];
      final dels = fileChanges['deletions'];
      final files = fileChanges['files'];
      final parts = <String>[
        if (adds is num && adds > 0) '+$adds',
        if (dels is num && dels > 0) '-$dels',
        if (files is num && files > 0) '$files 文件',
      ];
      stats = parts.join(' ');
    }

    final label = switch (state) {
      'running' => '本轮执行中',
      'completedSuccess' => [
          '本轮完成',
          if (duration.isNotEmpty) duration,
          if (stats.isNotEmpty) stats,
        ].join(' · '),
      'completedInterrupted' => '已中断',
      'failed' => '本轮失败',
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    final color = switch (state) {
      'running' => ZColors.running,
      'failed' => ZColors.danger,
      'completedInterrupted' => ZColors.warning,
      _ => ZInk.faint(context),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style:
                  TextStyle(fontSize: 11, color: color.withValues(alpha: 0.9)),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _TimelineMarkerWidget extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TimelineMarkerWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final marker = row['marker'];
    if (marker is! Map) return const SizedBox.shrink();
    final type = '${marker['type'] ?? ''}';

    final (icon, text, color) = switch (type) {
      'compact' => (
          Icons.compress,
          '压缩上下文 · ${marker['status'] ?? ''}'
              '${marker['tokensBefore'] != null ? ' · ${marker['tokensBefore']}→${marker['tokensAfter'] ?? '?'} tokens' : ''}',
          ZColors.primary
        ),
      'forkNotice' => (Icons.fork_right, '从会话分叉而来', ZInk.faint(context)),
      'forkCreated' => (Icons.fork_right, '已创建分叉会话', ZInk.faint(context)),
      'modelChange' => (
          Icons.swap_horiz,
          '模型切换 ${marker['fromModel'] ?? ''} → ${marker['toModel'] ?? ''}',
          ZColors.warning
        ),
      'goalSet' => (
          Icons.flag_outlined,
          '设定目标: ${marker['objective'] ?? ''}',
          ZColors.success
        ),
      'goalVerify' => (
          Icons.fact_check_outlined,
          '目标验证 第${marker['iteration'] ?? '?'}轮 · ${marker['outcome'] ?? ''}',
          ZColors.success
        ),
      'retryNotice' => (
          Icons.refresh,
          '自动重试 第${marker['attempt'] ?? '?'}次 (${marker['reasonCode'] ?? ''})',
          ZColors.warning
        ),
      'checkpointRestored' => (Icons.restore, '已恢复检查点', ZInk.faint(context)),
      _ => (Icons.info_outline, type, ZInk.faint(context)),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                style: TextStyle(fontSize: 11, color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SubagentTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_toy_outlined,
              size: 15, color: Colors.deepPurpleAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('子代理 · ${row['subagentType'] ?? ''}',
                    style: const TextStyle(fontSize: 12)),
                Text('${row['status'] ?? ''}  ${row['summaryText'] ?? ''}',
                    style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- bars

class _ContextUsageBar extends StatelessWidget {
  final ConversationState state;

  const _ContextUsageBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final usage = state.usage;
    final window = usage?['contextWindow'];
    if (window is! Map) return const SizedBox.shrink();
    final used = (window['usedTokens'] as num?)?.toInt();
    final max = (window['maxTokens'] as num?)?.toInt();
    if (used == null || max == null || max <= 0) {
      return const SizedBox.shrink();
    }
    final ratio = (used / max).clamp(0.0, 1.0);
    final color = ratio > 0.8 ? ZColors.warning : ZColors.primary;
    String fmt(int v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: ZInk.tile(context),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${fmt(used)}/${fmt(max)}',
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _GoalBanner extends StatelessWidget {
  final ConversationState state;

  const _GoalBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final status = '${goal['status'] ?? ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.success.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.flag_outlined, size: 14, color: ZColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(status,
                style: const TextStyle(fontSize: 11, color: ZColors.success)),
        ],
      ),
    );
  }
}

class _BackgroundWorksBar extends StatelessWidget {
  final ConversationState state;

  const _BackgroundWorksBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final works = state.backgroundWorks
        .where((w) => w['status'] == 'running' && w['endedAt'] == null)
        .toList();
    if (works.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '后台任务 ${works.length} 个运行中: '
              '${works.map((w) => w['title'] ?? w['kind']).join('、')}',
              style: TextStyle(fontSize: 11.5, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueBar extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _QueueBar({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.queue_outlined,
                  size: 14, color: ZColors.primary),
              const SizedBox(width: 6),
              Text('排队消息 ${items.length}',
                  style: const TextStyle(fontSize: 12, color: ZColors.primary)),
              const Spacer(),
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  transport.setAutoDrain(sessionId, next);
                },
                child: Text(
                  state.autoDrain ? '自动发送: 开' : '自动发送: 关',
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item['text'] ?? ''}',
                      style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: '立即发送',
                    onTap: () {
                      final id = '${item['queueItemId']}';
                      state.optimisticRemoveQueueItem(id);
                      transport.sendQueuedNow(sessionId, id);
                    },
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onTap: () => _edit(context, sessionId, item),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: '删除',
                    onTap: () async {
                      final id = '${item['queueItemId']}';
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除排队消息？'),
                          content: Text('将删除「${item['text'] ?? ''}」',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('取消')),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: ZColors.danger),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      state.optimisticRemoveQueueItem(id);
                      transport.deleteQueueItem(sessionId, id);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, String sessionId, Map<String, dynamic> item) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑排队消息'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (text == null || text.isEmpty) return;
    // Optimistic text update; server queue patch confirms.
    final q = state.queue;
    if (q != null && q['items'] is List) {
      final items = [
        for (final i in q['items'] as List)
          if (i is Map && '${i['queueItemId']}' == '${item['queueItemId']}')
            {...i, 'text': text}
          else
            i,
      ];
      state.optimisticPatch({
        'queue': {...q, 'items': items},
      });
    }
    await transport.editQueueItem(sessionId, '${item['queueItemId']}', text);
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: ZInk.muted(context)),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PendingFilesBar extends StatelessWidget {
  final List<_PendingFile> files;
  final double? uploadProgress;
  final void Function(int index) onRemove;

  const _PendingFilesBar({
    required this.files,
    required this.uploadProgress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploadProgress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: uploadProgress),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < files.length; i++)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 14),
                  label: Text(files[i].fileName,
                      style: const TextStyle(fontSize: 11)),
                  onDeleted: () => onRemove(i),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- interactions

class _PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _PendingInteractions({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Column(
      children: [
        for (final interaction in interactions)
          _InteractionCard(
            interaction: interaction,
            onResolve: ({optionId, freeText, action, content}) =>
                transport.resolveInteraction(
              sessionId,
              interaction['interactionId'] as String? ?? '',
              optionId: optionId,
              freeText: freeText,
              action: action,
              content: content,
            ),
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  const _InteractionCard({required this.interaction, required this.onResolve});

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _freeTextController.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
          optionId: optionId,
          freeText: freeText,
          action: action,
          content: content);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;

    final title =
        kind == 'permission' ? '权限请求 · ${payload['toolName'] ?? ''}' : '等待你的输入';

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.privacy_tip_outlined,
                  size: 14, color: ZColors.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          if (kind == 'userInput' &&
              (payload['prompt'] as String? ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['prompt']}',
                  style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
            ),
          if (kind == 'permission' && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['summary']}',
                  style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
            ),
          const SizedBox(height: 8),
          if (options is List && options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  if (option is Map)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                      ),
                      onPressed: _busy
                          ? null
                          : () => kind == 'permission'
                              ? _resolve(optionId: '${option['optionId']}')
                              : _resolve(action: 'accept', content: {}),
                      child: Text(
                        _optionLabel(option),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _QuestionsView(
              questions: questions.cast<Map>(),
              busy: _busy,
              onResolve: (answers) => _resolve(
                action: 'accept',
                content: {'answers': answers},
              ),
            ),
          if (freeText)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '输入回复…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _busy
                      ? null
                      : () =>
                          _resolve(freeText: _freeTextController.text.trim()),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _optionLabel(Map option) {
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) return label;
    final kind = option['kind'] as String?;
    return switch (kind) {
      'allowOnce' => '允许一次',
      'allowAlways' => '总是允许',
      'deny' => '拒绝',
      'custom' => '自定义',
      _ => '${option['optionId'] ?? '选择'}',
    };
  }
}

/// Renders a form-style `userInput` interaction (the `questions` payload):
/// the current question (by `currentQuestionIndex`) with its options.
class _QuestionsView extends StatefulWidget {
  final List<Map> questions;
  final bool busy;
  final void Function(Map<String, List<String>> answers) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.onResolve,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  final _answers = <String, List<String>>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _QuestionItem(
            index: i,
            question: widget.questions[i],
            busy: widget.busy,
            selected:
                _answers['${widget.questions[i]['question']}'] ?? const [],
            onChanged: (selected) => setState(() {
              final key = '${widget.questions[i]['question']}';
              if (selected.isEmpty) {
                _answers.remove(key);
              } else {
                _answers[key] = selected;
              }
            }),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.busy || _answers.isEmpty
                ? null
                : () => widget.onResolve(Map.of(_answers)),
            child: const Text('提交答案', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

class _QuestionItem extends StatefulWidget {
  final int index;
  final Map question;
  final bool busy;
  final List<String> selected;
  final void Function(List<String> selected) onChanged;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<_QuestionItem> createState() => _QuestionItemState();
}

class _QuestionItemState extends State<_QuestionItem> {
  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    final label = q['label'] ?? q['question'] ?? q['value'] ?? '';
    final options = q['options'];
    final multi = q['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.index + 1}. $label',
              style: const TextStyle(fontSize: 12, height: 1.4)),
          if (q['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${q['description']}',
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    if (o is Map)
                      FilterChip(
                        label: Text('${o['label'] ?? o['value'] ?? ''}',
                            style: const TextStyle(fontSize: 12)),
                        selected: widget.selected.contains('${o['value']}'),
                        onSelected: widget.busy
                            ? null
                            : (on) {
                                setState(() {
                                  final selected =
                                      List<String>.from(widget.selected);
                                  if (multi) {
                                    if (on) {
                                      selected.add('${o['value']}');
                                    } else {
                                      selected.remove('${o['value']}');
                                    }
                                  } else {
                                    selected
                                      ..clear()
                                      ..add('${o['value']}');
                                  }
                                  widget.onChanged(selected);
                                });
                              },
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sheets

class _ModelModeSheet extends StatelessWidget {
  final ConversationState? state;
  final ConversationTransport transport;
  final WorkspacePrep? prep;
  final String? sessionId;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.state,
    required this.transport,
    this.prep,
    this.sessionId,
    this.draftConfig,
    this.onDraftChange,
  });

  bool get _isDraft => sessionId == null || sessionId!.isEmpty;

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  /// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
  (String, String) _splitModelValue(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    final sid = sessionId ?? '';
    final config = state?.config ?? const {};
    final modelOption = prep?.option('model');
    final modeOption = prep?.option('mode');
    final thoughtOption = prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
            ? (draftConfig?['model'] ?? '${modelOption?.currentValue ?? ''}')
            : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (draftConfig?['thought'] ?? '${thoughtOption?.currentValue ?? ''}')
        : (state?.currentThought.isNotEmpty == true
            ? state!.currentThought
            : '${thoughtOption?.currentValue ?? ''}');
    final currentModeValue = _isDraft
        ? (draftConfig?['mode'] ?? 'build')
        : state?.currentMode ?? 'build';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_isDraft ? '新会话 · 模型与模式' : '模型与模式',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (modelOption != null && modelOption.options.isNotEmpty) ...[
              Text(modelOption.name, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final v in modelOption.options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModelValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModelValue == v.value
                        ? ZColors.primary
                        : ZInk.ghost(context),
                  ),
                  title: Text(v.name, style: const TextStyle(fontSize: 13)),
                  subtitle: v.modelProviderName != null
                      ? Text(v.modelProviderName!,
                          style: TextStyle(
                              fontSize: 11, color: ZInk.faint(context)))
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('model', v.value);
                    } else {
                      final (provider, model) = _splitModelValue(v.value);
                      // thought must be valid for the target model:
                      // keep current if supported, else fall back to the
                      // thought option's currentValue (Turbo: enabled/off)
                      final currentThought = state?.currentThought ?? '';
                      final thoughtOpt = prep?.option('thought_level');
                      final thought = currentThought.isNotEmpty &&
                              (thoughtOpt?.options
                                      .any((o) => o.value == currentThought) ??
                                  false)
                          ? currentThought
                          : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
                      _apply(
                        context,
                        () => transport.switchModelConfig(
                          sid,
                          provider: provider,
                          model: model,
                          thought: thought,
                        ),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'provider': provider,
                            'model': model,
                            'thought': thought,
                          },
                        }),
                      );
                    }
                  },
                ),
              const SizedBox(height: 12),
            ] else
              Text('当前模型: ${state?.currentModel ?? ''}',
                  style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
            if (thoughtOption != null && thoughtOption.options.isNotEmpty) ...[
              Text(thoughtOption.name, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in thoughtOption.options)
                    ChoiceChip(
                      label: Text(v.name),
                      selected: currentThoughtValue == v.value ||
                          state?.currentThought == v.value,
                      onSelected: (_) {
                        if (_isDraft) {
                          onDraftChange?.call('thought', v.value);
                        } else {
                          final modelValue = currentModelValue;
                          final (provider, model) = modelValue.isNotEmpty
                              ? _splitModelValue(modelValue)
                              : (
                                  '${config['provider'] ?? ''}',
                                  '${config['model'] ?? ''}'
                                );
                          _apply(
                            context,
                            () => transport.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: () => state?.optimisticPatch({
                              'config': {
                                ...?state!.config,
                                'thought': v.value,
                              },
                            }),
                          );
                        }
                      },
                    ),
                ],
              ),
            ] else if ((state?.thoughtLevels ?? const []).isNotEmpty) ...[
              const Text('思考等级', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final level in state!.thoughtLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: state?.currentThought == level,
                      onSelected: (_) => _apply(
                        context,
                        () => transport.switchModelConfig(
                          sid,
                          provider: '${config['provider'] ?? ''}',
                          model: '${config['model'] ?? ''}',
                          thought: level,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const Text('协作模式', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            if (modeOption != null && modeOption.options.isNotEmpty)
              for (final v in modeOption.options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModeValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModeValue == v.value
                        ? ZColors.primary
                        : ZInk.ghost(context),
                  ),
                  title: Text(v.name, style: const TextStyle(fontSize: 13)),
                  subtitle: v.description != null
                      ? Text(v.description!,
                          style: TextStyle(
                              fontSize: 11, color: ZInk.faint(context)))
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', v.value);
                    } else {
                      _apply(
                        context,
                        () => transport.switchCollaborationMode(sid, v.value),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'mode': v.value,
                          },
                        }),
                      );
                    }
                  },
                )
            else
              Wrap(
                spacing: 8,
                children: [
                  for (final m in const ['build', 'edit', 'plan', 'yolo'])
                    ChoiceChip(
                      label: Text(m),
                      selected: currentModeValue == m,
                      onSelected: (_) {
                        if (_isDraft) {
                          onDraftChange?.call('mode', m);
                        } else {
                          _apply(
                            context,
                            () => transport.switchCollaborationMode(sid, m),
                          );
                        }
                      },
                    ),
                ],
              ),
            if (!_isDraft) ...[
              const SizedBox(height: 16),
              const Text('后续消息', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in const ['queue', 'guide'])
                    ChoiceChip(
                      label: Text(f == 'queue' ? '排队' : '引导'),
                      selected: followup == f,
                      onSelected: (_) => _apply(
                        context,
                        () => transport.setFollowupMode(sid, f),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'followupMode': f,
                          },
                        }),
                      ),
                    ),
                ],
              ),
            ],
            if (_otherOptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('其他配置', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final o in _otherOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child:
                            Text(o.name, style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(width: 8),
                      Text('${o.currentValue}',
                          style: TextStyle(
                              fontSize: 12, color: ZInk.muted(context))),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) async {
    try {
      final res = await run();
      if (context.mounted) {
        if (res is Map &&
            res['status'] != null &&
            res['status'] != 'accepted') {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('被拒绝: ${res['reasonCode'] ?? res['status']}')));
        } else {
          onAccepted?.call();
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('失败: $e')));
      }
    }
  }
}

class _UsageSheet extends StatelessWidget {
  final ConversationState state;
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String sessionId;

  const _UsageSheet({
    required this.state,
    required this.session,
    required this.scope,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final usage = state.usage ?? const {};
    final cumulative = usage['cumulative'];
    final contextWindow = usage['contextWindow'];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用量统计',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (contextWindow is Map) ...[
              _UsageRow('上下文',
                  '${contextWindow['usedTokens'] ?? '-'} / ${contextWindow['maxTokens'] ?? '-'} tokens'),
            ],
            if (cumulative is Map) ...[
              _UsageRow('累计输入', '${cumulative['inputTokens'] ?? 0}'),
              _UsageRow('累计输出', '${cumulative['outputTokens'] ?? 0}'),
              _UsageRow('缓存读取', '${cumulative['cacheReadTokens'] ?? 0}'),
              _UsageRow('缓存写入', '${cumulative['cacheWriteTokens'] ?? 0}'),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.query_stats, size: 16),
                label: const Text('查询任务级用量 (getTaskTokenUsage)'),
                onPressed: () async {
                  try {
                    final res = await session.channels.call(
                      Channels.zcodeTask,
                      'getTaskTokenUsage',
                      [
                        {...scope, 'taskId': sessionId},
                      ],
                    );
                    if (context.mounted) {
                      showModalBottomSheet(
                        context: context,
                        builder: (context) =>
                            _JsonSheet(title: '任务用量', data: res),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('查询失败: $e')));
                    }
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;

  const _UsageRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
          Text(value,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _JsonSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _JsonSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  data == null ? '（无数据）' : encoder.convert(data),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class _SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const _SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<_SlashItem> items;
  final void Function(_SlashItem item) onSelect;

  const _SlashCommandBar({
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    final filtered = q.isEmpty
        ? items
        : items
            .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
            .toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('没有匹配的命令',
            style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact' ? Icons.compress : Icons.bolt),
                size: 16,
                color: command.isSkill ? ZColors.warning : ZColors.primary,
              ),
              title: Text(
                  command.isSkill ? '\$${command.name}' : '/${command.name}',
                  style:
                      const TextStyle(fontSize: 13, fontFamily: 'monospace')),
              subtitle: Text(
                command.description,
                style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(command),
            ),
        ],
      ),
    );
  }
}

class _SkillsPickerSheet extends StatelessWidget {
  final List<SkillEntry> skills;
  final bool loading;
  final void Function(SkillEntry skill) onSelect;
  final Future<void> Function() onRefresh;

  const _SkillsPickerSheet({
    required this.skills,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final list = skills.where((s) => s.enabled).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('选择 Skills',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon:
                      Icon(Icons.refresh, size: 18, color: ZInk.muted(context)),
                  tooltip: '刷新',
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('没有可用的 Skills',
                    style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in list)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.auto_awesome_outlined,
                            size: 18, color: ZColors.warning),
                        title: Text('\$${s.name}',
                            style: const TextStyle(
                                fontSize: 14, fontFamily: 'monospace')),
                        subtitle: s.description != null
                            ? Text(s.description!,
                                style: TextStyle(
                                    fontSize: 12, color: ZInk.faint(context)),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis)
                            : null,
                        onTap: () => onSelect(s),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.onSkills,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon:
                  Icon(Icons.attach_file, size: 20, color: ZInk.muted(context)),
              tooltip: '添加附件',
              onPressed: widget.sending ? null : widget.onAttach,
            ),
            IconButton(
              icon: Icon(Icons.auto_awesome_outlined,
                  size: 20, color: ZInk.muted(context)),
              tooltip: '选择 Skills',
              onPressed: widget.sending ? null : widget.onSkills,
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '向 ZCode 发送消息…',
                ),
                textInputAction: TextInputAction.newline,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              decoration: const BoxDecoration(
                color: ZColors.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: widget.sending ? null : widget.onSend,
                icon: widget.sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.arrow_upward,
                        color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
