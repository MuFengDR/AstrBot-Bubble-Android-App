import 'package:flutter_test/flutter_test.dart';

import 'package:astrbot_android/core/diagnostics/diagnostic_service.dart';

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
}
