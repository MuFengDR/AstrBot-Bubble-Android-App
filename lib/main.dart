import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:settings/settings.dart';
import 'dart:async';

import 'generated/l10n.dart';
import 'core/services/auto_backup_scheduler.dart';
import 'core/services/foreground_service.dart';
import 'core/services/keep_alive_guard.dart';
import 'core/services/message_bridge.dart';
import 'core/services/power_policy.dart';
import 'core/services/status_timeline.dart';
import 'ui/controllers/terminal_controller.dart';
import 'ui/routes/app_routes.dart';

// Notice: behavior will submit Device

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 检查并请求通知权限
  var status = await Permission.notification.status;
  if (status.isDenied || status.isPermanentlyDenied) {
    await Permission.notification.request();
  }

  // 先初始化配置存储：前台服务要读省电策略，必须在 init 之前就绪
  // Init the setting store first — the foreground service reads PowerPolicy.
  final packageInfo = await PackageInfo.fromPlatform();
  RuntimeEnvir.initEnvirWithPackageName(packageInfo.packageName);
  await initSettingStore(RuntimeEnvir.configPath);

  // 初始化并启动前台服务
  ForegroundServiceManager.init();
  await ForegroundServiceManager.startService();

  // 隐藏系统 UI
  // Hide system UI
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [
    SystemUiOverlay.top,
    // SystemUiOverlay.bottom,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // Android 状态栏图标为白色
    statusBarBrightness: Brightness.dark, // iOS 状态栏图标为白色
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  runApp(const AstrBot());
}

class AstrBot extends StatefulWidget {
  const AstrBot({super.key});

  @override
  State<AstrBot> createState() => _AstrBotState();
}

class _AstrBotState extends State<AstrBot> with WidgetsBindingObserver {
  Timer? _serviceMonitorTimer;
  KeepAliveGuard? _guard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 启动服务状态监听器，定期检查服务是否运行
    _startServiceMonitor();
    _startRuntimeGuard();
  }

  /// 启动服务状态监听器
  void _startServiceMonitor() {
    // 原来每 10 秒问一次「服务在不在」，现在保活由 KeepAliveGuard 负责；
    // 这里只兜底前台服务本身被系统收掉的情况。
    _serviceMonitorTimer =
        Timer.periodic(const Duration(seconds: 30), (timer) async {
      final isRunning = await ForegroundServiceManager.isRunningService();
      final userClickedStop = ForegroundServiceManager.userClickedStopButton;

      // 只有在服务未运行且用户没有点击停止按钮的情况下才重启
      // 这样即使用户从通知栏划掉通知，服务也会被重建
      if (!isRunning && !userClickedStop) {
        Log.w('主应用检测到服务未运行，尝试重启...', tag: 'AstrBot');
        try {
          await ForegroundServiceManager.startService();
          Log.i('服务重启成功', tag: 'AstrBot');
          await StatusTimeline.instance.record(
            'service',
            'service_restarted',
            '后台服务未运行，已自动拉起',
            level: TimelineLevel.warning,
          );
        } catch (e) {
          Log.e('服务重启失败: $e', tag: 'AstrBot');
        }
      }
    });
  }

  /// 启动运行守护：探活 6185，掉线后分级自愈
  void _startRuntimeGuard() {
    unawaited(StatusTimeline.instance.ensureLoaded().then((_) {
      unawaited(StatusTimeline.instance.record(
        'app',
        'app_start',
        '应用已启动',
      ));
    }));

    FlutterForegroundTask.addTaskDataCallback(_onServiceMessage);

    _guard = KeepAliveGuard(isBackground: false)
      ..onRestartAstrBot = _healRestartAstrBot
      ..onRestartEnvironment = _healRestartEnvironment
      ..onRestartService = _healRestartService
      // 环境还没装好时不必反复重启，等用户装完再守
      ..canHeal = (() => _findController()?.isAstrBotInstalled ?? false)
      ..start();

    // 通知桥是可选功能，延迟启动，别拖慢首屏
    if (PowerPolicy.notifyBridgeEnabled) {
      Future.delayed(const Duration(seconds: 8), () {
        unawaited(MessageBridge.instance.start());
      });
    }

    // 自动备份：启动 2 分钟后首次检查，之后每 15 分钟看一次是否到点
    AutoBackupScheduler.instance.start();
  }

  HomeController? _findController() {
    try {
      if (Get.isRegistered<HomeController>()) {
        return Get.find<HomeController>();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _healRestartAstrBot() async {
    final controller = _findController();
    if (controller == null) {
      Log.w('自愈时找不到 HomeController，跳过第一级', tag: 'AstrBot');
      return;
    }
    await controller.healRestartAstrBot();
  }

  Future<void> _healRestartEnvironment() async {
    final controller = _findController();
    if (controller == null) return;
    await controller.healRestartEnvironment();
  }

  Future<void> _healRestartService() async {
    await ForegroundServiceManager.applyPowerPolicy();
    await ForegroundServiceManager.startService();
    await StatusTimeline.instance.record(
      'service',
      'service_restarted',
      '自愈第三级：已重启后台服务',
      level: TimelineLevel.warning,
    );
  }

  /// 处理前台服务 isolate 发来的指令
  void _onServiceMessage(dynamic data) {
    if (data is! Map) return;
    final cmd = data['cmd']?.toString();
    if (cmd == KeepAliveCommand.gracefulStop) {
      unawaited(_gracefulStop());
      return;
    }
    // 后台探到掉线：把主 isolate 唤醒，让它在同一套节流/退避里判断
    if (cmd == KeepAliveCommand.probeDown) {
      unawaited(_guard?.tick(force: true) ?? Future<void>.value());
      return;
    }
    if (cmd != KeepAliveCommand.heal) return;

    final stage = data['stage']?.toString();
    HealStage? parsed;
    for (final value in HealStage.values) {
      if (value.name == stage) {
        parsed = value;
        break;
      }
    }
    if (parsed == null) return;
    // 同样交给 guard 统一执行，避免和主 isolate 自己的自愈动作撞车
    unawaited(_guard?.handleExternalHeal(parsed) ?? Future<void>.value());
  }

  /// 通知栏「停止运行」：先停 AstrBot，再把服务收掉
  Future<void> _gracefulStop() async {
    final controller = _findController();
    try {
      if (controller != null && controller.isAstrBotRunning.value) {
        await controller.stopAstrBot();
      }
    } catch (e) {
      Log.e('优雅停止 AstrBot 失败: $e', tag: 'AstrBot');
    }
    await StatusTimeline.instance.record(
      'service',
      'service_stopped',
      '用户从通知栏停止了后台服务',
      level: TimelineLevel.warning,
    );
    await ForegroundServiceManager.stopService();
  }

  @override
  void dispose() {
    _serviceMonitorTimer?.cancel();
    _guard?.stop();
    FlutterForegroundTask.removeTaskDataCallback(_onServiceMessage);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 当应用完全退出时，确保清理所有资源
    if (state == AppLifecycleState.detached) {
      Log.i('应用正在退出，清理所有资源...', tag: 'AstrBot');
      try {
        // 尝试获取并清理 HomeController
        if (Get.isRegistered<HomeController>()) {
          Get.delete<HomeController>(force: true);
        }
      } catch (e) {
        Log.e('清理资源时出错: $e', tag: 'AstrBot');
      }
    }
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'AstrBot Android',
      theme: ThemeData(
        colorSchemeSeed: Colors.primaries[3],
      ),
      // locale: const Locale('zh', 'CN'),
      // locale: const Locale('en'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.delegate.supportedLocales,
      // 使用路由管理
      initialRoute: AppRoutes.main,
      getPages: AppRoutes.routes,
    );
  }
}
