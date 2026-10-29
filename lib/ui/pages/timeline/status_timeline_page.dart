import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/status_timeline.dart';
import '../../widgets/glass_panel.dart';

/// 运行状态时间线页面
/// Runtime status timeline page
class StatusTimelinePage extends StatefulWidget {
  const StatusTimelinePage({super.key});

  @override
  State<StatusTimelinePage> createState() => _StatusTimelinePageState();
}

class _StatusTimelinePageState extends State<StatusTimelinePage> {
  Timer? _refreshTimer;
  bool _onlyAbnormal = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // 后台 isolate 也在往同一个文件里写，直接定时重读最省事
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await StatusTimeline.instance.reload();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Color _levelColor(BuildContext context, TimelineLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      TimelineLevel.error => scheme.error,
      TimelineLevel.warning => Colors.orange,
      TimelineLevel.success => Colors.green,
      TimelineLevel.info => scheme.primary,
    };
  }

  IconData _levelIcon(TimelineLevel level) => switch (level) {
        TimelineLevel.error => Icons.error_outline,
        TimelineLevel.warning => Icons.warning_amber_outlined,
        TimelineLevel.success => Icons.check_circle_outline,
        TimelineLevel.info => Icons.circle_outlined,
      };

  Future<void> _copyAll() async {
    final text = StatusTimeline.instance.exportAsText();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空时间线'),
        content: const Text('会删除本地保存的全部运行记录，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await StatusTimeline.instance.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = StatusTimeline.instance.groupedByDay(
      onlyAbnormal: _onlyAbnormal,
    );
    final days = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(
        title: const Text('状态时间线'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('只看异常'),
                  selected: _onlyAbnormal,
                  onSelected: (value) => setState(() => _onlyAbnormal = value),
                ),
                const Spacer(),
                Text(
                  '${StatusTimeline.instance.events.length} 条',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : days.isEmpty
                    ? Center(
                        child: Text(
                          _onlyAbnormal ? '没有异常记录' : '还没有运行记录',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        itemCount: days.length,
                        itemBuilder: (context, index) {
                          final day = days[index];
                          final events = grouped[day]!.reversed.toList();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 12, 0, 6),
                                child: Text(
                                  day,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              GlassPanel(
                                opacity: 0.55,
                                blur: 16,
                                child: Column(
                                  children: [
                                    for (var i = 0; i < events.length; i++)
                                      _buildEventTile(context, events[i],
                                          isLast: i == events.length - 1),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTile(
    BuildContext context,
    TimelineEvent event, {
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    final color = _levelColor(context, event.level);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 10, 12, isLast ? 12 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Icon(_levelIcon(event.level), size: 16, color: color),
              if (!isLast)
                Container(
                  width: 1,
                  height: 26,
                  margin: const EdgeInsets.only(top: 2),
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.message,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${event.timeLabel} · ${event.source}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
