import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/health_probe.dart';
import '../../core/services/status_timeline.dart';
import '../controllers/terminal_controller.dart';
import 'glass_panel.dart';

/// 主页的运行状态卡片：健康灯 + 最近事件 + 快速入口
/// Home page runtime card: health dot, latest events and quick actions
class RuntimeStatusCard extends StatefulWidget {
  final HomeController controller;
  final VoidCallback onOpenTimeline;

  const RuntimeStatusCard({
    super.key,
    required this.controller,
    required this.onOpenTimeline,
  });

  @override
  State<RuntimeStatusCard> createState() => _RuntimeStatusCardState();
}

class _RuntimeStatusCardState extends State<RuntimeStatusCard> {
  HealthSnapshot? _snapshot;
  bool _probing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(StatusTimeline.instance.ensureLoaded());
    _probe();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _probe());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    try {
      final snapshot = await HealthProbe.snapshot();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
      await StatusTimeline.instance.reload();
      if (mounted) setState(() {});
    } finally {
      _probing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;
    final alive = snapshot?.astrBotAlive ?? false;
    final installed = widget.controller.isAstrBotInstalled;
    final events = StatusTimeline.instance.recent(3);

    final Color dotColor;
    final String headline;
    if (snapshot == null) {
      dotColor = theme.colorScheme.outline;
      headline = '正在检查…';
    } else if (alive) {
      dotColor = Colors.green;
      headline = 'AstrBot 正常 · ${snapshot.dashboardLatencyMs}ms';
    } else if (!installed) {
      dotColor = theme.colorScheme.outline;
      headline = '环境未安装';
    } else {
      dotColor = theme.colorScheme.error;
      headline = 'AstrBot 未响应';
    }

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      opacity: widget.controller.cardGlassOpacity.value,
      blur: widget.controller.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.45),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '立即检查',
                visualDensity: VisualDensity.compact,
                onPressed: _probing ? null : _probe,
                icon: _probing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (snapshot != null && snapshot.napCatOpen)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 20),
              child: Text(
                'NapCat WebUI 在线',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (events.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final event in events.take(2))
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.timeLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        event.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: event.level == TimelineLevel.error
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: widget.onOpenTimeline,
                icon: const Icon(Icons.timeline, size: 16),
                label: const Text('状态时间线'),
              ),
              const Spacer(),
              Text(
                '${StatusTimeline.instance.events.length} 条记录',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
