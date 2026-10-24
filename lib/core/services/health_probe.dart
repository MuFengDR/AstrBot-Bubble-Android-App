import 'dart:async';
import 'dart:io';

import '../config/service_ports.dart';

/// 单个端口的探测结果
/// Result of probing one local port
class PortProbeResult {
  final int port;
  final bool open;
  final int latencyMs;

  const PortProbeResult({
    required this.port,
    required this.open,
    required this.latencyMs,
  });

  @override
  String toString() => 'port=$port open=$open ${latencyMs}ms';
}

/// 一次健康快照
/// A snapshot of local service health
class HealthSnapshot {
  final DateTime at;
  final bool dashboardOpen;
  final bool oneBotOpen;
  final bool napCatOpen;
  final int dashboardLatencyMs;

  const HealthSnapshot({
    required this.at,
    required this.dashboardOpen,
    required this.oneBotOpen,
    required this.napCatOpen,
    required this.dashboardLatencyMs,
  });

  /// 只要面板端口活着就认为 AstrBot 本体还在跑
  /// AstrBot is considered alive when its dashboard port accepts connections
  bool get astrBotAlive => dashboardOpen;

  bool get napCatAlive => napCatOpen;

  bool get fullyHealthy => dashboardOpen;

  String get summary {
    final parts = <String>[];
    parts.add(dashboardOpen
        ? 'AstrBot 正常（${dashboardLatencyMs}ms）'
        : 'AstrBot 未响应');
    if (napCatOpen) parts.add('NapCat 正常');
    return parts.join(' · ');
  }
}

/// 本地端口健康探测
/// Local port health probing
class HealthProbe {
  HealthProbe._();

  /// 探测超时，短一点避免拖慢守护循环
  static const Duration defaultTimeout = Duration(milliseconds: 900);

  /// 判断端口是否有进程监听
  /// Whether anything is listening on the port
  static Future<PortProbeResult> probePort(
    int port, {
    Duration timeout = defaultTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: timeout,
      );
      return PortProbeResult(
        port: port,
        open: true,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      return PortProbeResult(
        port: port,
        open: false,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      socket?.destroy();
    }
  }

  static Future<bool> isPortOpen(
    int port, {
    Duration timeout = defaultTimeout,
  }) async {
    final result = await probePort(port, timeout: timeout);
    return result.open;
  }

  /// 并行探测三个关键端口
  /// Probe the three key ports in parallel
  ///
  /// 后台 isolate 没有初始化 settings，端口可以由调用方显式传入。
  static Future<HealthSnapshot> snapshot({
    int? dashboardPort,
    int? oneBotPort,
    int? napCatPort,
  }) async {
    final resolvedDashboard = dashboardPort ?? _dashboardPort;
    final resolvedOneBot = oneBotPort ?? _oneBotPort;
    final resolvedNapCat = napCatPort ?? _napCatPort;
    final results = await Future.wait<PortProbeResult>([
      probePort(resolvedDashboard),
      probePort(resolvedOneBot),
      probePort(resolvedNapCat),
    ]);
    return HealthSnapshot(
      at: DateTime.now(),
      dashboardOpen: results[0].open,
      oneBotOpen: results[1].open,
      napCatOpen: results[2].open,
      dashboardLatencyMs: results[0].latencyMs,
    );
  }

  static int get _dashboardPort {
    try {
      return ServicePorts.dashboardPort;
    } catch (_) {
      return ServicePorts.defaultDashboardPort;
    }
  }

  static int get _oneBotPort {
    try {
      return ServicePorts.oneBotWsPort;
    } catch (_) {
      return ServicePorts.defaultOneBotWsPort;
    }
  }

  static int get _napCatPort {
    try {
      return ServicePorts.napCatWebUiPort;
    } catch (_) {
      return ServicePorts.defaultNapCatWebUiPort;
    }
  }

  /// 端口占用检测（启动前使用）
  /// Whether the port is already taken
  static Future<bool> isPortInUse(int port) => isPortOpen(port);

  /// AstrBot 主进程是否在跑
  /// Whether the AstrBot python process exists
  ///
  /// 端口还没起来的时候也能判断它是不是正在初始化：装完环境第一次启动要
  /// 装依赖、建库，这段时间进程在、端口不开，不能当成掉线去重启。
  static Future<bool> astrBotProcessRunning() async {
    try {
      final proc = Directory('/proc');
      if (!await proc.exists()) return false;
      await for (final entity in proc.list(followLinks: false)) {
        final name = entity.path.split('/').last;
        if (int.tryParse(name) == null) continue;
        try {
          final cmdline = await File('${entity.path}/cmdline').readAsString();
          if (cmdline.contains('AstrBot') && cmdline.contains('main.py')) {
            return true;
          }
        } catch (_) {
          // 别的 uid 的进程、刚退出的进程读不到，跳过
        }
      }
    } catch (_) {
      // /proc 不可读时按「没在跑」处理，交给端口判断
    }
    return false;
  }
}
