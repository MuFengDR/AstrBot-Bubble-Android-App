import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/config/ui_preferences.dart';
import '../../../core/services/backup_service.dart';
import '../../controllers/terminal_controller.dart';

/// 一键备份与迁移页面
/// Backup and migration page
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  List<BackupEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  String _stage = '';
  double _progress = 0;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    // 自动备份在后台生成时，列表里要能自己冒出来
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_busy && mounted) _reload();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final entries = await BackupService.listBackups();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _updateProgress(String stage, double progress) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      _progress = progress.clamp(0.0, 1.0);
    });
  }

  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stage = '准备备份…';
      _progress = 0;
    });
    try {
      final entry = await BackupService.createBackup(
        onProgress: _updateProgress,
      );
      await BackupService.prune();
      await _reload();
      _snack('备份完成：${entry.name}（${entry.sizeLabel}）');
    } catch (e) {
      _snack('备份失败：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = '';
          _progress = 0;
        });
      }
    }
  }

  Future<void> _restore(BackupEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这份备份？'),
        content: Text(
          '将用 ${entry.name} 覆盖当前的 AstrBot 数据、NapCat 配置和应用设置。\n\n'
          '开始前会自动备份一次当前状态，恢复过程不要退出应用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _stage = '准备恢复…';
      _progress = 0;
    });
    try {
      await BackupService.restore(
        entry.file,
        onProgress: _updateProgress,
      );
      if (mounted) {
        final controller = Get.isRegistered<HomeController>()
            ? Get.find<HomeController>()
            : null;
        if (controller != null && controller.isAstrBotRunning.value) {
          await controller.stopAstrBot();
        }
      }
      await _reload();
      _snack('恢复完成，重新启动 AstrBot 后生效');
    } catch (e) {
      _snack('恢复失败：$e', error: true);
      // 失败时也刷新一次：恢复前会自动打一份当前状态的快照，列表里要能看见
      await _reload();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = '';
          _progress = 0;
        });
      }
    }
  }

  Future<void> _export(BackupEntry entry) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出备份',
        fileName: entry.name,
        bytes: await entry.file.readAsBytes(),
      );
      if (path == null) return;
      await BackupService.exportTo(entry, path);
      _snack('已导出到 $path');
    } catch (e) {
      _snack('导出失败：$e', error: true);
    }
  }

  Future<void> _import() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: false);
      final path = result?.files.single.path;
      if (path == null) return;
      final entry = await BackupService.importFrom(path);
      await _reload();
      _snack('已导入 ${entry.name}');
    } catch (e) {
      _snack('导入失败：$e', error: true);
    }
  }

  Future<void> _delete(BackupEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('确定删除 ${entry.name}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await BackupService.delete(entry);
      await _reload();
    } catch (e) {
      _snack('删除失败：$e', error: true);
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String get _lastAutoBackupLabel {
    final autos =
        _entries.where((entry) => entry.name.contains('-auto')).toList();
    if (autos.isEmpty) return '还没有自动备份，下次检查时会生成第一份';
    final last = autos.first.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次自动备份 ${last.year}-${two(last.month)}-${two(last.day)} '
        '${two(last.hour)}:${two(last.minute)}';
  }

  /// 列表底部的统计：共几份、占多大
  String get _entriesSummary {
    final total = _entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
    final mb = total / 1024 / 1024;
    final size = mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(2)} GB'
        : '${mb.toStringAsFixed(1)} MB';
    return '共 ${_entries.length} 份备份 · 占用 $size';
  }

  Widget _buildAutoBackupCard(ThemeData theme) {
    final enabled = UiPreferences.autoBackupEnabled;
    const divider = Divider(height: 1, indent: 16, endIndent: 16);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              UiPreferences.saveAutoBackupEnabled(!enabled);
              setState(() {});
            },
            child: _buildOptionRow(
              theme: theme,
              title: '自动备份',
              subtitle: enabled ? _lastAutoBackupLabel : '已关闭，只有手动备份',
              trailing: Switch(
                value: enabled,
                // 缩小点击区，让开关的可视边缘和下面的下拉箭头落在同一条竖线上
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (value) {
                  UiPreferences.saveAutoBackupEnabled(value);
                  setState(() {});
                },
              ),
            ),
          ),
          if (enabled) ...[
            divider,
            _buildOptionRow(
              theme: theme,
              title: '间隔',
              trailing: _buildDropdown<int>(
                value: UiPreferences.autoBackupIntervalHours,
                items: const [12, 24, 72, 168],
                label: _intervalLabelStatic,
                onChanged: (value) {
                  UiPreferences.saveAutoBackupIntervalHours(value);
                  setState(() {});
                },
              ),
            ),
            divider,
            _buildOptionRow(
              theme: theme,
              title: '保留',
              subtitle: '超过份数的旧自动备份会自动删掉，手动备份不动',
              trailing: _buildDropdown<int>(
                value: UiPreferences.autoBackupKeep,
                items: const [3, 5, 10],
                label: (count) => '$count 份',
                onChanged: (value) {
                  UiPreferences.saveAutoBackupKeep(value);
                  setState(() {});
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 一行「标题（+说明） + 右侧控件」，左右内边距固定 16，保证多行右侧对齐
  Widget _buildOptionRow({
    required ThemeData theme,
    required String title,
    String? subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }

  /// 固定宽度的下拉，内容右对齐，这样不同行之间的箭头能对齐
  Widget _buildDropdown<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    final current = items.contains(value) ? value : items.first;
    return SizedBox(
      width: 84,
      child: DropdownButton<T>(
        value: current,
        isExpanded: true,
        isDense: true,
        alignment: Alignment.centerRight,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        items: items
            .map((item) => DropdownMenuItem<T>(
                  value: item,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(label(item)),
                  ),
                ))
            .toList(),
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }

  static String _intervalLabelStatic(int hours) =>
      hours % 24 == 0 ? '${hours ~/ 24} 天' : '$hours 小时';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份与迁移'),
        actions: [
          IconButton(
            tooltip: '导入备份文件',
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: Column(
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '备份包含 AstrBot 数据、插件、NapCat 配置和应用设置，不含 64MB 的 Ubuntu 系统本体。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _createBackup,
                        icon: const Icon(Icons.backup_outlined),
                        label: const Text('立即备份'),
                      ),
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: _progress),
                      const SizedBox(height: 6),
                      Text(
                        _stage,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: _buildAutoBackupCard(theme),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? Center(
                        child: Text(
                          '还没有备份',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              leading: const Icon(Icons.archive_outlined),
                              title: Text(entry.name),
                              subtitle: Text(
                                '${entry.timeLabel} · ${entry.sizeLabel}',
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'restore':
                                      _restore(entry);
                                      break;
                                    case 'export':
                                      _export(entry);
                                      break;
                                    case 'delete':
                                      _delete(entry);
                                      break;
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'restore',
                                    child: Text('恢复到当前环境'),
                                  ),
                                  PopupMenuItem(
                                    value: 'export',
                                    child: Text('导出到文件'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          if (_entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                _entriesSummary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
