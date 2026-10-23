import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'health_probe.dart';
import 'power_policy.dart';
import 'status_timeline.dart';

/// 自愈动作的升级阶梯
/// Escalation ladder for self healing
enum HealStage {
  /// 只重启 AstrBot 进程
  restartAstrBot,

  /// 重建 proot 环境与 AstrBot
  restartEnvironment,

  /// 重启前台服务，最后兜底
  restartService,
}

/// 主 isolate 与后台 isolate 之间的指令名
/// Command names exchanged between the UI isolate and the service isolate
class KeepAliveCommand {
  static const String heal = 'astr_heal';
  static const String timelineChanged = 'astr_timeline_changed';
  static const String gracefulStop = 'astr_graceful_stop';

  /// 后台实例探到掉线，只通知主 isolate 立刻探一次
  static const String probeDown = 'astr_probe_down';

  /// 前台服务 isolate 读取守护参数的存储键
  static const String guardConfigKey = 'astr_guard_config';
  static const String configPathKey = 'astr_config_path';
}

/// 守护参数快照
/// Snapshot of guard parameters
///
/// 后台 isolate 读不到 settings 包里的配置，启动前台服务前把参数序列化过去。
class GuardConfig {
  final int dashboardPort;
  final int probeIntervalSeconds;
  final int failureThreshold;
  final bool autoHealEnabled;

  /// 探活是否开启（间隔设成 0 时整块关掉，连定时器都不再探）
  final bool probeEnabled;

  const GuardConfig({
    required this.dashboardPort,
    required this.probeIntervalSeconds,
    required this.failureThreshold,
    required this.autoHealEnabled,
    this.probeEnabled = true,
  });

  factory GuardConfig.fromPowerPolicy(int dashboardPort) {
    return GuardConfig(
      dashboardPort: dashboardPort,
      probeIntervalSeconds: PowerPolicy.probeIntervalSeconds,
      failureThreshold: PowerPolicy.failureThreshold,
      autoHealEnabled: PowerPolicy.autoHealEnabled,
      probeEnabled: PowerPolicy.probeEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'dashboard_port': dashboardPort,
        'probe_interval': probeIntervalSeconds,
        'failure_threshold': failureThreshold,
        'auto_heal': autoHealEnabled,
        'probe_enabled': probeEnabled,
      };

  static GuardConfig? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return GuardConfig(
        dashboardPort: (decoded['dashboard_port'] as num?)?.toInt() ?? 6185,
        probeIntervalSeconds:
            (decoded['probe_interval'] as num?)?.toInt() ?? 20,
        failureThreshold: (decoded['failure_threshold'] as num?)?.toInt() ?? 3,
        autoHealEnabled: decoded['auto_heal'] == true,
        probeEnabled: decoded['probe_enabled'] != false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 运行守护：探活 + 分级自愈
/// Runtime guard: liveness probing plus staged self healing
class KeepAliveGuard {
  KeepAliveGuard({
    required this.isBackground,
    GuardConfig? config,
    this.probeOnly = false,
  }) : _config = config ??
            GuardConfig.fromPowerPolicy(6185);

  /// 是否运行在前台服务的 isolate 里
  final bool isBackground;

  /// 只探活：不写时间线、不升级自愈动作。
  ///
  /// 前台服务 isolate 用这个模式——它探到掉线就通知主 isolate，
  /// 由主 isolate 唯一地决定级别并执行动作。两个 isolate 各跑一套
  /// 完整逻辑时会出现同一秒两条探活失败记录、以及刚重建完环境又
  /// 从第一级重启一遍的叠加问题。
  final bool probeOnly;

  /// 探到掉线时通知主 isolate（probeOnly 模式）
  void Function()? onProbeDown;

  /// 是否值得自愈：AstrBot 还没安装时没必要反复重启进程和重建环境
  bool Function()? canHeal;

  GuardConfig _config;

  /// 由主 isolate 注入的具体动作，后台 isolate 里为空
  Future<void> Function()? onRestartAstrBot;
  Future<void> Function()? onRestartEnvironment;
  Future<void> Function()? onRestartService;

  Timer? _timer;
  int _failures = 0;
  int _level = 0;
  bool _wasDown = false;
  bool _busy = false;
  DateTime? _lastHealAt;
  DateTime? _lastSuccessAt;

  /// 连续失败了多少轮完整自愈，用来做退避
  int _healRounds = 0;
  DateTime? _nextHealAt;

  /// 「环境未安装所以没自愈」这条说明只记一次
  bool _installSkipLogged = false;

  /// 「还没就绪过，只重启不动环境」这条说明只记一次
  bool _setupSkipLogged = false;

  /// 「探活已关闭」这条说明只记一次
  bool _probeDisabledLogged = false;

  int get consecutiveFailures => _failures;
  int get currentLevel => _level;
  bool get busy => _busy;
  GuardConfig get config => _config;

  void updateConfig(GuardConfig config) {
    _config = config;
    if (_timer != null) start();
  }

  /// 相邻两级自愈之间的最小间隔，避免疯狂重启
  static const Duration escalateDelay = Duration(seconds: 45);

  /// 冷启动宽限：应用刚起来这段时间里 AstrBot 可能还在初始化，
  /// 探活失败不代表真掉线，别急着动手。
  static const Duration startupGrace = Duration(seconds: 120);

  DateTime _createdAt = DateTime.now();

  /// 本次会话里是否成功就绪过。
  ///
  /// 从没就绪过（首次安装、正在初始化）时不做第二、三级动作：
  /// 那时候重启进程和重建环境只会把用户正在做的首次配置打断。
  bool _everReady = false;

  DateTime? _lastProbeAt;

  void start({bool useTimer = true}) {
    _timer?.cancel();
    _timer = null;
    if (useTimer) {
      // 固定 5 秒醒来一次，节流判断放在 tick 里；这样切换省电档位不用重启定时器
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        tick();
      });
    }
    // 启动后先探一次，尽快把状态写进时间线
    unawaited(tick(force: true));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 主 isolate 每次都读最新设置，切档后立刻生效；
  /// 后台 isolate 用启动时序列化进来的快照。
  GuardConfig get _effective => isBackground
      ? _config
      : GuardConfig.fromPowerPolicy(_config.dashboardPort);

  /// 一次探活
  ///
  /// [force] 为 true 时忽略探活间隔（启动时、被后台实例唤醒时用）。
  Future<void> tick({bool force = false}) async {
    if (_busy) return;
    final config = _effective;
    // 探活间隔设成 0：用户主动关掉了探活与自愈，这里不再动
    if (!config.probeEnabled) {
      if (!_probeDisabledLogged) {
        _probeDisabledLogged = true;
        await StatusTimeline.instance.record(
          'guard',
          'probe_disabled',
          '探活已关闭（间隔设为 0），不再自动检测与恢复',
          level: TimelineLevel.info,
        );
      }
      return;
    }
    _probeDisabledLogged = false;
    final now = DateTime.now();
    final interval = Duration(seconds: config.probeIntervalSeconds);
    final last = _lastProbeAt;
    // 前台服务的唤醒是固定 10 秒一次，节流统一在这里做；
    // 主 isolate 由自己的定时器驱动，同样按用户设定的间隔过滤
    if (!force && last != null && now.difference(last) < interval) {
      return;
    }
    _lastProbeAt = now;
    _busy = true;
    try {
      final result = await HealthProbe.probePort(config.dashboardPort);
      final alive = result.open;

      if (alive) {
        if (_wasDown && !probeOnly) {
          final downFor = _lastSuccessAt == null
              ? ''
              : '，中断约 ${DateTime.now().difference(_lastSuccessAt!).inSeconds} 秒';
          await StatusTimeline.instance.record(
            'guard',
            'recovered',
            'AstrBot 已恢复响应（${result.latencyMs}ms）$downFor',
            level: TimelineLevel.success,
            dedupe: false,
          );
        }
        _wasDown = false;
        _failures = 0;
        _level = 0;
        _healRounds = 0;
        _nextHealAt = null;
        _installSkipLogged = false;
        _everReady = true;
        _lastSuccessAt = DateTime.now();
        return;
      }

      _failures++;
      if (probeOnly) {
        // 后台只负责发现掉线，记录和动作交给主 isolate
        _wasDown = true;
        onProbeDown?.call();
        return;
      }
      if (!_wasDown) {
        _wasDown = true;
        await StatusTimeline.instance.record(
          'guard',
          'probe_failed',
          'AstrBot 面板端口 ${config.dashboardPort} 无响应'
              '（第 $_failures 次探活失败）',
          level: TimelineLevel.warning,
          dedupe: false,
        );
      }

      if (_failures < config.failureThreshold) return;

      // 上一轮自愈无效时先歇一会儿，避免每分钟重启一次把电耗光
      final nextHeal = _nextHealAt;
      if (nextHeal != null && DateTime.now().isBefore(nextHeal)) return;

      if (!config.autoHealEnabled) {
        if (_failures == config.failureThreshold) {
          await StatusTimeline.instance.record(
            'guard',
            'heal_skipped',
            '检测到 AstrBot 掉线，但自动自愈已关闭',
            level: TimelineLevel.warning,
          );
        }
        return;
      }
      await _escalate();
    } catch (e) {
      if (!probeOnly) {
        await StatusTimeline.instance.record(
          'guard',
          'probe_error',
          '探活异常：$e',
          level: TimelineLevel.error,
        );
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _escalate() async {
    final now = DateTime.now();
    // 每 45 秒最多上升一级，给上一级动作留出生效时间
    if (_lastHealAt != null && now.difference(_lastHealAt!) < escalateDelay) {
      return;
    }

    // 冷启动刚起来的这两分钟，AstrBot 多半还在自检/装依赖，先按兵不动
    if (now.difference(_createdAt) < startupGrace) {
      if (!_installSkipLogged) {
        _installSkipLogged = true;
        await StatusTimeline.instance.record(
          'guard',
          'heal_deferred_startup',
          '刚启动不足 ${startupGrace.inSeconds} 秒，先等 AstrBot 自己起来',
          level: TimelineLevel.info,
        );
      }
      return;
    }

    // AstrBot 还没安装时自愈无从下手：反复重启进程、重建环境只是白耗电
    final gate = canHeal;
    if (gate != null && !gate()) {
      if (!_installSkipLogged) {
        _installSkipLogged = true;
        await StatusTimeline.instance.record(
          'guard',
          'heal_skipped_install',
          '当前不满足自愈条件（未安装 / 已手动停止 / 首次配置中），已跳过',
          level: TimelineLevel.info,
        );
      }
      return;
    }
    _installSkipLogged = false;

    _lastHealAt = now;

    var next = _level + 1;
    // 本次会话从没就绪过（首次安装、正在初始化）：停在第一级。
    // 这时候重建环境、重启后台服务只会把用户正在做的首次配置打断。
    if (!_everReady && next > 1) {
      if (!_setupSkipLogged) {
        _setupSkipLogged = true;
        await StatusTimeline.instance.record(
          'guard',
          'heal_limited_setup',
          'AstrBot 还没有就绪过，先只重启进程，不重建环境',
          level: TimelineLevel.info,
        );
      }
      next = 1;
    }
    if (next == 1) {
      _level = 1;
      await StatusTimeline.instance.record(
        'guard',
        'heal_level1',
        '连续 $_failures 次探活失败，正在重启 AstrBot 进程',
        level: TimelineLevel.warning,
        dedupe: false,
      );
      await _dispatch(HealStage.restartAstrBot);
      return;
    }
    if (next == 2) {
      _level = 2;
      await StatusTimeline.instance.record(
        'guard',
        'heal_level2',
        '重启进程后仍无响应，正在重建运行环境',
        level: TimelineLevel.error,
        dedupe: false,
      );
      await _dispatch(HealStage.restartEnvironment);
      return;
    }

    await StatusTimeline.instance.record(
      'guard',
      'heal_level3',
      '多轮自愈仍失败，重启后台服务；请打开应用查看终端输出',
      level: TimelineLevel.error,
      dedupe: false,
    );
    await _dispatch(HealStage.restartService);
    // 交给下一轮探活重新判断，避免死循环
    _level = 0;
    _failures = 0;

    // 指数退避：2 分钟起，最长 30 分钟，成功恢复后清零
    _healRounds++;
    final step = (_healRounds - 1).clamp(0, 4).toInt();
    final seconds = 120 * (1 << step);
    final wait = Duration(seconds: seconds > 1800 ? 1800 : seconds);
    _nextHealAt = DateTime.now().add(wait);
    await StatusTimeline.instance.record(
      'guard',
      'heal_backoff',
      '连续 $_healRounds 轮自愈无效，${wait.inMinutes} 分钟后再试',
      level: TimelineLevel.warning,
    );
  }

  /// 主 isolate 收到后台实例的自愈请求。
  ///
  /// 与内部 [_escalate] 共用冷却时间、退避窗口和安装门禁，保证一次掉线
  /// 只动一次手，而不是两个 isolate 各重启一遍。
  Future<void> handleExternalHeal(HealStage stage) async {
    if (isBackground || probeOnly) return;
    if (_busy) return;
    final now = DateTime.now();
    final nextHeal = _nextHealAt;
    if (nextHeal != null && now.isBefore(nextHeal)) return;
    if (_lastHealAt != null && now.difference(_lastHealAt!) < escalateDelay) {
      return;
    }
    final gate = canHeal;
    if (gate != null && !gate()) return;

    _lastHealAt = now;
    await StatusTimeline.instance.record(
      'guard',
      'heal_external_${stage.name}',
      '后台探活发现掉线，执行自愈：${_stageLabel(stage)}',
      level: stage == HealStage.restartAstrBot
          ? TimelineLevel.warning
          : TimelineLevel.error,
      dedupe: false,
    );
    await _dispatch(stage);
  }

  String _stageLabel(HealStage stage) {
    switch (stage) {
      case HealStage.restartAstrBot:
        return '重启 AstrBot 进程';
      case HealStage.restartEnvironment:
        return '重建运行环境';
      case HealStage.restartService:
        return '重启后台服务';
    }
  }

  Future<void> _dispatch(HealStage stage) async {
    if (isBackground) {
      // 后台 isolate 不能直接操作控制器，交给主 isolate 执行
      FlutterForegroundTask.sendDataToMain({
        'cmd': KeepAliveCommand.heal,
        'stage': stage.name,
      });
      return;
    }
    try {
      switch (stage) {
        case HealStage.restartAstrBot:
          await onRestartAstrBot?.call();
          break;
        case HealStage.restartEnvironment:
          await onRestartEnvironment?.call();
          break;
        case HealStage.restartService:
          await onRestartService?.call();
          break;
      }
    } catch (e) {
      await StatusTimeline.instance.record(
        'guard',
        'heal_failed',
        '自愈动作失败（${stage.name}）：$e',
        level: TimelineLevel.error,
      );
    }
  }
}
