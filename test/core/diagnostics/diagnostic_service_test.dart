import 'package:flutter_test/flutter_test.dart';

import 'package:astrbot_android/core/diagnostics/diagnostic_service.dart';
import 'package:astrbot_android/ui/controllers/terminal_controller.dart';

void main() {
  group('firstNonEmptyDiagnosticValue', () {
    test('falls back to the root wake prefix when a legacy value is empty', () {
      final value = firstNonEmptyDiagnosticValue([
        '',
        const <String>[],
        const <String>['/'],
      ]);

      expect(value, const <String>['/']);
    });

    test('keeps the first configured value', () {
      final value = firstNonEmptyDiagnosticValue([
        const <String>['/'],
        const <String>['!'],
      ]);

      expect(value, const <String>['/']);
    });
  });

  test('report detail is exported without replacing the compact UI detail', () {
    final item = DiagnosticItem(
      'AstrBot 配置检查',
      status: DiagnosticStatus.passed,
      detail: '默认配置：模型 2/2',
      reportDetail: '\tdefault：\n\t\t模型：2/2',
    );
    final report = DiagnosticReport(
      items: [item],
      startedAt: DateTime(2026, 8, 1),
      modelTestRequested: true,
      modelTestSkipped: false,
    );

    expect(item.detail, '默认配置：模型 2/2');
    expect(
      report.toText(),
      contains('[正常] AstrBot 配置检查：\n\tdefault：\n\t\t模型：2/2'),
    );
    expect(report.toText(), isNot(contains('默认配置：模型 2/2')));
  });

  test('maps every config routed to a running adapter and deduplicates ids',
      () {
    final ids = diagnosticConfigIdsForAdapter('纳西妲', {
      '泡泡:*:*': 'default',
      '纳西妲:*:*': 'cfg-nahida',
      '纳西妲:GroupMessage:*': 'cfg-group',
      '纳西妲:FriendMessage:*': 'cfg-nahida',
    });

    expect(ids, ['cfg-nahida', 'cfg-group']);
  });

  test('falls back to default when an adapter has no config route', () {
    expect(
      diagnosticConfigIdsForAdapter('未配置路由', {'泡泡:*:*': 'cfg-bubble'}),
      ['default'],
    );
  });

  test('includes a compact summary before multiline report details', () {
    final report = DiagnosticReport(
      items: [
        DiagnosticItem(
          'NapCat 连接检查',
          status: DiagnosticStatus.passed,
          detail: '连接正常（1 个运行账号）',
          reportSummary: '连接正常',
          reportDetail: '\twebsocket适配器：\n\t\t纳西妲 123321 6199 已绑定BOT',
        ),
      ],
      startedAt: DateTime(2026, 8, 1),
      modelTestRequested: true,
      modelTestSkipped: false,
    );

    expect(
      report.toText(),
      contains(
        '[正常] NapCat 连接检查：连接正常\n'
        '\twebsocket适配器：\n'
        '\t\t纳西妲 123321 6199 已绑定BOT',
      ),
    );
  });

  test('ignores stopped accounts when evaluating active connections', () {
    expect(
      diagnosticProcessIsHealthy(
        astrBotRunning: true,
        runningAccountCount: 1,
      ),
      isTrue,
    );
    expect(
      diagnosticConnectionsAreHealthy(
        astrBotRunning: true,
        runningBindings: const [BotBindingConfigState.configured],
      ),
      isTrue,
    );
  });

  test('fails when any running account is not correctly bound', () {
    expect(
      diagnosticConnectionsAreHealthy(
        astrBotRunning: true,
        runningBindings: const [
          BotBindingConfigState.configured,
          BotBindingConfigState.mismatch,
        ],
      ),
      isFalse,
    );
  });

  test('uses distinct report labels for binding failures', () {
    expect(
      diagnosticBindingStateLabel(BotBindingConfigState.disabled),
      '已禁用BOT',
    );
    expect(
      diagnosticBindingStateLabel(BotBindingConfigState.mismatch),
      'BOT绑定异常',
    );
    expect(
      diagnosticBindingStateLabel(BotBindingConfigState.unconfigured),
      '未绑定BOT',
    );
  });
}
