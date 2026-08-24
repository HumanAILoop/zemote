import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/automation_client.dart';

void main() {
  AutomationEntry entry(Map<String, dynamic> raw) => AutomationEntry(raw);

  test('parses automation fields', () {
    final e = entry({
      'automationId': 'a1',
      'title': '定时巡检',
      'prompt': '检查一下',
      'cronExpr': '*/5 * * * *',
      'model': 'builtin:zai-coding-plan/GLM-5.2',
      'provider': 'glm',
      'mode': 'yolo',
      'thoughtLevel': 'max',
      'recurring': true,
      'scheduleRule': {'unit': 'minute', 'interval': 5, 'hour': 11, 'minute': 17},
      'enabled': true,
      'lifecycleStatus': 'active',
      'runCount': 3,
      'lastRunAt': 1000,
      'nextRunAt': 2000,
      'createdAt': 500,
      'updatedAt': 900,
    });
    expect(e.automationId, 'a1');
    expect(e.title, '定时巡检');
    expect(e.cronExpr, '*/5 * * * *');
    expect(e.enabled, isTrue);
    expect(e.recurring, isTrue);
    expect(e.runCount, 3);
    expect(e.nextRunAt, 2000);
  });

  test('scheduleLabel for minute interval', () {
    final e = entry({
      'scheduleRule': {'unit': 'minute', 'interval': 5, 'hour': 11, 'minute': 17},
      'cronExpr': '*/5 * * * *',
    });
    expect(e.scheduleLabel(), '每 5 分钟');
  });

  test('scheduleLabel for hour interval', () {
    final e = entry({
      'scheduleRule': {'unit': 'hour', 'interval': 2, 'hour': 9, 'minute': 0},
      'cronExpr': '0 */2 * * *',
    });
    expect(e.scheduleLabel(), '每 2 小时');
  });

  test('scheduleLabel for daily', () {
    final e = entry({
      'scheduleRule': {'unit': 'day', 'interval': 1, 'hour': 9, 'minute': 5},
      'cronExpr': '5 9 * * *',
    });
    expect(e.scheduleLabel(), '每天 09:05');
  });

  test('scheduleLabel falls back to cronExpr', () {
    final e = entry({'cronExpr': '0 8 * * 1'});
    expect(e.scheduleLabel(), '0 8 * * 1');
  });

  test('defaults when fields missing', () {
    final e = entry({});
    expect(e.automationId, '');
    expect(e.enabled, isFalse);
    expect(e.runCount, 0);
    expect(e.nextRunAt, isNull);
  });
}
