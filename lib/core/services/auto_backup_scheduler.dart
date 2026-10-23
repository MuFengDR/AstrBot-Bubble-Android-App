import 'dart:async';

import 'package:global_repository/global_repository.dart';

import '../config/ui_preferences.dart';
import 'backup_service.dart';
import 'status_timeline.dart';

/// 自动备份调度器
///
/// 每 [checkIntervalBeforeStart] 起检查一次：距上次备份超过用户设定的间隔，
/// 就打一份带 `-auto` 标记的归档，并只保留最近 N 份自动备份。
/// 手动备份不参与这个保留策略，永远不会被自动清掉。
class AutoBackupScheduler {
  AutoBackupScheduler._();

  static final AutoBackupScheduler instance = AutoBackupScheduler._();

  /// 启动后先等一会儿再检查，避开 App 刚起来时的环境初始化高峰
  static const Duration _firstDelay = Duration(seconds: 120);

  /// 检查周期（只是"看看到点没"，真正触发按用户设定的小时数）
  static const Duration _checkInterval = Duration(minutes: 15);

  /// 失败后的冷却，避免一直失败一直重试
  static const Duration _failureCooldown = Duration(minutes: 30);

  Timer? _firstTimer;
  Timer? _timer;
  bool _running = false;
  bool _working = false;
  DateTime? _lastFailureAt;

  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    _firstTimer?.cancel();
    _timer?.cancel();
    _firstTimer = Timer(_firstDelay, () => unawaited(check()));
    _timer = Timer.periodic(_checkInterval, (_) => unawaited(check()));
  }

  void stop() {
    _firstTimer?.cancel();
    _firstTimer = null;
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  /// 按设定判断是否需要备份，需要就执行一次
  Future<void> check() async {
    if (_working) return;
    if (!UiPreferences.autoBackupEnabled) return;
    if (!BackupService.hasContent) return;
    if (BackupService.isBusy) return;

    final now = DateTime.now();
    final failedAt = _lastFailureAt;
    if (failedAt != null && now.difference(failedAt) < _failureCooldown) {
      return;
    }

    final interval = Duration(hours: UiPreferences.autoBackupIntervalHours);
    // 以磁盘上最新一份自动备份为准（用户手动删了也能重新算），
    // 一份都没有时 last 为 null，开启后先备一份。
    final existing = await BackupService.listBackups();
    final autoOnes =
        existing.where((entry) => entry.name.contains('-auto')).toList();
    final last = autoOnes.isEmpty ? null : autoOnes.first.createdAt;
    if (last != null && now.difference(last) < interval) return;

    _working = true;
    try {
      final entry = await BackupService.createBackup(auto: true);
      final removed = await BackupService.pruneAuto(
        keep: UiPreferences.autoBackupKeep,
      );
      if (removed > 0) {
        Log.i('已清理 $removed 份过期自动备份', tag: 'AutoBackup');
      }
      Log.i(
        '自动备份完成 ${entry.name}（${entry.sizeLabel}），保留 '
        '${UiPreferences.autoBackupKeep} 份',
        tag: 'AutoBackup',
      );
      _lastFailureAt = null;
    } catch (e) {
      _lastFailureAt = DateTime.now();
      Log.e('自动备份失败: $e', tag: 'AutoBackup');
      unawaited(StatusTimeline.instance.record(
        'backup',
        'auto_backup_failed',
        '自动备份失败：$e',
        level: TimelineLevel.error,
        dedupe: false,
      ));
    } finally {
      _working = false;
    }
  }
}
