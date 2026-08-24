import 'channel_client.dart';
import 'zemote_client.dart';

/// A scheduled/automation task on the desktop (`zcode-agent.listAllAutomations`).
class AutomationEntry {
  final String automationId;
  final String title;
  final String prompt;
  final String cronExpr;
  final String model;
  final String provider;
  final String mode;
  final String thoughtLevel;
  final bool recurring;
  final Map<String, dynamic>? scheduleRule;
  final bool enabled;
  final String lifecycleStatus;
  final int runCount;
  final int lastRunAt;
  final int? nextRunAt;
  final int createdAt;
  final int updatedAt;
  final Map<String, dynamic> raw;

  AutomationEntry(this.raw)
      : automationId = '${raw['automationId'] ?? ''}',
        title = '${raw['title'] ?? ''}',
        prompt = '${raw['prompt'] ?? ''}',
        cronExpr = '${raw['cronExpr'] ?? ''}',
        model = '${raw['model'] ?? ''}',
        provider = '${raw['provider'] ?? ''}',
        mode = '${raw['mode'] ?? ''}',
        thoughtLevel = '${raw['thoughtLevel'] ?? ''}',
        recurring = raw['recurring'] == true,
        scheduleRule =
            (raw['scheduleRule'] as Map?)?.cast<String, dynamic>(),
        enabled = raw['enabled'] == true,
        lifecycleStatus = '${raw['lifecycleStatus'] ?? ''}',
        runCount = (raw['runCount'] as num?)?.toInt() ?? 0,
        lastRunAt = (raw['lastRunAt'] as num?)?.toInt() ?? 0,
        nextRunAt = (raw['nextRunAt'] as num?)?.toInt(),
        createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt = (raw['updatedAt'] as num?)?.toInt() ?? 0;

  /// Human-readable schedule, e.g. `每 5 分钟` / `每天 11:17` / `一次性`.
  String scheduleLabel() {
    final rule = scheduleRule;
    if (rule == null) return cronExpr.isEmpty ? '—' : cronExpr;
    final unit = '${rule['unit'] ?? ''}';
    final interval = (rule['interval'] as num?)?.toInt() ?? 1;
    switch (unit) {
      case 'minute':
        return '每 $interval 分钟';
      case 'hour':
        return '每 $interval 小时';
      case 'day':
        final h = (rule['hour'] as num?)?.toInt() ?? 0;
        final m = (rule['minute'] as num?)?.toInt() ?? 0;
        return '每天 ${_two(h)}:${_two(m)}';
      case 'week':
        final dow = rule['weekday'] ?? rule['dayOfWeek'];
        return '每周 ${_weekdayLabel(dow)}';
      default:
        return cronExpr.isEmpty ? '—' : cronExpr;
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _weekdayLabel(Object? dow) {
    const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    if (dow is num && dow >= 0 && dow < 7) return names[dow.toInt()];
    return '';
  }
}

/// Client for the scheduled/automation RPC on the `zcode-agent` channel.
class AutomationClient {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;

  const AutomationClient({required this.bridge, required this.scope});

  ChannelClient get _channels => bridge.channels;

  Map<String, dynamic> get _scopeMap => {
        'workspacePath': scope['workspacePath'],
        if (scope['workspaceIdentity'] != null)
          'workspaceIdentity': scope['workspaceIdentity'],
      };

  /// All automations (active + completed) for this workspace.
  Future<List<AutomationEntry>> list() async {
    final res = await _channels.call(
        'zcode-agent', 'listAllAutomations', [_scopeMap],
        timeout: const Duration(seconds: 30));
    if (res is! List) return const [];
    return [
      for (final item in res.whereType<Map>())
        AutomationEntry(item.cast<String, dynamic>()),
    ];
  }

  /// Creates an automation. [scheduleRule] like
  /// `{unit: 'minute'|'hour'|'day', interval, hour, minute}`.
  /// Returns the created automation.
  Future<AutomationEntry> create({
    required String title,
    required String prompt,
    required String cronExpr,
    required String model,
    required String provider,
    required String mode,
    required String thoughtLevel,
    required bool recurring,
    required Map<String, dynamic> scheduleRule,
    bool enabled = true,
  }) async {
    final res = await _channels.call('zcode-agent', 'createAutomation', [
      {
        ..._scopeMap,
        'title': title,
        'prompt': prompt,
        'cronExpr': cronExpr,
        'model': model,
        'provider': provider,
        'mode': mode,
        'thoughtLevel': thoughtLevel,
        'recurring': recurring,
        'scheduleRule': scheduleRule,
        'enabled': enabled,
      },
    ], timeout: const Duration(seconds: 20));
    return AutomationEntry(
        res is Map ? res.cast<String, dynamic>() : <String, dynamic>{});
  }

  /// Enables or disables an automation.
  Future<dynamic> setEnabled(String automationId, bool enabled) {
    return _channels.call('zcode-agent', 'setAutomationEnabled', [
      {..._scopeMap, 'automationId': automationId, 'enabled': enabled},
    ], timeout: const Duration(seconds: 15));
  }

  /// Deletes an automation.
  Future<dynamic> delete(String automationId) {
    return _channels.call('zcode-agent', 'deleteAutomation', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }

  /// Runs an automation immediately (queues a run).
  Future<dynamic> runNow(String automationId) {
    return _channels.call('zcode-agent', 'runAutomationNow', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }

  /// Restarts a completed/errored automation.
  Future<dynamic> restart(String automationId) {
    return _channels.call('zcode-agent', 'restartAutomation', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }
}
