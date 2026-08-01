import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:settings/settings.dart';

import '../../core/diagnostics/diagnostic_service.dart';
import '../controllers/terminal_controller.dart';

SettingNode get _diagnosticModelPreference =>
    DiagnosticService.preferenceKey.setting;

Future<void> showDiagnosticDialog(
  BuildContext context,
  HomeController controller,
) async {
  final preference = _diagnosticModelPreference.get()?.toString();
  if (preference == DiagnosticService.modelPreferenceSkip ||
      preference == DiagnosticService.modelPreferenceAgree) {
    await _runDialog(
      context,
      controller,
      preference == DiagnosticService.modelPreferenceAgree,
    );
    return;
  }

  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      var remember = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('开始自诊断'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('将检查运行环境、后台权限、AstrBot、NapCat 和模型配置。模型测试会消耗少量 Token，单个模型最多等待 120 秒。'),
              const SizedBox(height: 12),
              ...const [
                '运行环境检查',
                'AstrBot 和 NapCat 运行状态',
                'NapCat 连接检查',
                'AstrBot 配置检查',
                '模型连通性测试',
              ].map(
                (text) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $text'),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: remember,
                onChanged: (value) =>
                    setState(() => remember = value ?? false),
                title: const Text('下次不再提示'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (remember) {
                  _diagnosticModelPreference
                      .set(DiagnosticService.modelPreferenceSkip);
                }
                Navigator.pop(context, 'skip');
              },
              child: const Text('跳过模型测试'),
            ),
            FilledButton(
              onPressed: () {
                if (remember) {
                  _diagnosticModelPreference
                      .set(DiagnosticService.modelPreferenceAgree);
                }
                Navigator.pop(context, 'agree');
              },
              child: const Text('同意并继续'),
            ),
          ],
        ),
      );
    },
  );
  if (choice == null || choice == 'cancel' || !context.mounted) return;
  await _runDialog(context, controller, choice == 'agree');
}

Future<void> _runDialog(
  BuildContext context,
  HomeController controller,
  bool testModel,
) async {
  final items = DiagnosticService.itemTitles.map(DiagnosticItem.new).toList();
  final service = DiagnosticService(
    controller,
    onChanged: (item) {
      final index = items.indexWhere((entry) => entry.title == item.title);
      if (index >= 0) items[index] = item;
    },
  );
  final reportFuture = service.run(testModel: testModel);
  var cancelled = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StreamBuilder<void>(
      stream: Stream<void>.periodic(const Duration(milliseconds: 100)),
      builder: (context, _) => FutureBuilder<DiagnosticReport>(
        future: reportFuture,
        builder: (context, snapshot) {
          final completed = snapshot.hasData;
          final report = snapshot.data;
          return AlertDialog(
            title: Text(completed ? '诊断完成' : '正在诊断'),
            content: SizedBox(
              width: 500,
              child: ListView(
                shrinkWrap: true,
                children: items
                    .map(
                      (item) => ListTile(
                        dense: true,
                        leading: _statusIcon(item.status),
                        title: Text(
                          item.title,
                          style: TextStyle(
                            color: item.status == DiagnosticStatus.pending
                                ? Colors.grey
                                : null,
                          ),
                        ),
                        subtitle:
                            item.detail.isEmpty ? null : Text(item.detail),
                      ),
                    )
                    .toList(),
              ),
            ),
            actions: completed && report != null
                ? [
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: report.toText()),
                      ),
                      child: const Text('复制报告'),
                    ),
                    TextButton(
                      onPressed: () => _exportReport(dialogContext, report),
                      child: const Text('导出报告'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () {
                        cancelled = true;
                        service.cancel();
                        Navigator.pop(dialogContext);
                      },
                      child: const Text('取消'),
                    ),
                  ],
          );
        },
      ),
    ),
  );
  if (cancelled) return;
}

Future<void> _exportReport(
  BuildContext context,
  DiagnosticReport report,
) async {
  var permission = await Permission.manageExternalStorage.status;
  if (!permission.isGranted) {
    permission = await Permission.manageExternalStorage.request();
  }
  if (!permission.isGranted) return;

  final directory = Directory('/storage/emulated/0/Download/AstrBotBubble');
  await directory.create(recursive: true);
  final stamp = report.startedAt
      .toLocal()
      .toIso8601String()
      .replaceAll(RegExp('[^0-9]'), '')
      .substring(0, 14);
  await File('${directory.path}/AstrBotBubble-diagnostic-$stamp.txt')
      .writeAsString(report.toText());
  if (context.mounted) {
    Get.snackbar(
      '导出成功',
      '报告已保存到 Download/AstrBotBubble',
      snackPosition: SnackPosition.BOTTOM,
    );
  }
}

Widget _statusIcon(DiagnosticStatus status) => switch (status) {
      DiagnosticStatus.pending =>
        const Icon(Icons.circle, color: Colors.grey, size: 12),
      DiagnosticStatus.running => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      DiagnosticStatus.passed =>
        const Icon(Icons.check_circle, color: Colors.green),
      DiagnosticStatus.warning =>
        const Icon(Icons.warning, color: Colors.amber),
      DiagnosticStatus.failed => const Icon(Icons.error, color: Colors.red),
    };
