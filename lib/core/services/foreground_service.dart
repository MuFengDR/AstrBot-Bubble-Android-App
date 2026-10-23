import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:global_repository/global_repository.dart';

import '../config/service_ports.dart';
import 'keep_alive_guard.dart';
import 'power_policy.dart';
import 'status_timeline.dart';

/// 前台服务管理类
/// Foreground Service Manager
class ForegroundServiceManager {
  /// 标记用户是否点击了停止按钮（只有这种情况才不重建）
  static bool _userClickedStopButton = false;

  /// 初始化前台服务
  /// Initialize foreground service
  ///
  /// 心跳间隔和唤醒锁由省电策略决定，切换档位时重新调用即可生效。
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'astrbot_keep_alive_channel',
        channelName: 'AstrBot后台服务',
        channelDescription: '保持AstrBot在后台运行',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          PowerPolicy.foregroundEventSeconds * 1000,
        ),
        autoRunOnBoot: false,
        allowWakeLock: PowerPolicy.allowWakeLock,
        allowWifiLock: false,
      ),
    );
  }

  /// 切换省电策略后重新应用
  /// Re-apply options after the power profile changed
  static Future<void> applyPowerPolicy() async {
    init();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    }
  }

  /// 把后台 isolate 需要的最少参数写进去
  /// Persist the parameters the service isolate needs
  static Future<void> _saveGuardContext() async {
    // 服务 isolate 里 RuntimeEnvir 没有初始化，configPath 会直接抛异常；
    // 那种场景下保存不了也没关系，后台守护用默认参数即可。
    String configPath;
    try {
      configPath = RuntimeEnvir.configPath;
    } catch (_) {
      return;
    }
    if (configPath.isEmpty) return;
    try {
      await FlutterForegroundTask.saveData(
        key: KeepAliveCommand.configPathKey,
        value: configPath,
      );
      final config = GuardConfig.fromPowerPolicy(ServicePorts.dashboardPort);
      await FlutterForegroundTask.saveData(
        key: KeepAliveCommand.guardConfigKey,
        value: jsonEncode(config.toJson()),
      );
    } catch (e) {
      Log.w('保存守护参数失败: $e', tag: 'ForegroundService');
    }
  }

  /// 启动前台服务
  /// Start foreground service
  static Future<ServiceRequestResult> startService({
    bool restartIfRunning = false,
  }) async {
    _userClickedStopButton = false; // 重置停止标记
    Log.i('启动前台服务...', tag: 'ForegroundService');

    await _saveGuardContext();

    if (await FlutterForegroundTask.isRunningService) {
      if (!restartIfRunning) {
        // 服务本来就在跑，直接返回成功。
        // 以前这里无条件 restartService，服务 isolate 每次都以为
        // “服务没起来”又去重建一次，形成 300ms 一次的重启风暴。
        Log.i('服务已在运行，跳过重启', tag: 'ForegroundService');
        return const ServiceRequestSuccess();
      }
      Log.i('服务已在运行，按需重启', tag: 'ForegroundService');
      return FlutterForegroundTask.restartService();
    } else {
      Log.i('启动新服务', tag: 'ForegroundService');
      return FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'AstrBot正在运行',
        notificationText: '应用正在后台保持运行状态',
        notificationIcon: null,
        notificationButtons: [
          const NotificationButton(
            id: 'btn_stop',
            text: '停止运行',
          ),
        ],
        callback: startCallback,
      );
    }
  }

  /// 停止前台服务（仅在用户点击停止按钮时调用）
  /// Stop foreground service (only called when user clicks stop button)
  static Future<ServiceRequestResult> stopService() async {
    _userClickedStopButton = true; // 标记为用户点击了停止按钮
    Log.i('用户点击停止按钮，停止前台服务', tag: 'ForegroundService');
    return FlutterForegroundTask.stopService();
  }

  /// 获取用户是否点击了停止按钮
  /// Get if user clicked stop button
  static bool get userClickedStopButton => _userClickedStopButton;

  /// 检查服务是否正在运行
  /// Check if service is running
  static Future<bool> isRunningService() async {
    return FlutterForegroundTask.isRunningService;
  }

  /// 更新通知内容
  /// Update notification content
  static Future<void> updateNotification({
    String? title,
    String? text,
  }) async {
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.updateService(
        notificationTitle: title ?? 'AstrBot正在运行',
        notificationText: text ?? '应用正在后台保持运行状态',
        notificationButtons: [
          const NotificationButton(
            id: 'btn_stop',
            text: '停止运行',
          ),
        ],
      );
    }
  }
}

/// 前台服务回调函数
/// Foreground service callback
@pragma('vm:entry-point')
void startCallback() {
  // 后台 isolate 需要插件注册，否则 MethodChannel / 通知都不可用
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(KeepAliveTaskHandler());
}

/// 前台任务处理器
/// Foreground task handler
class KeepAliveTaskHandler extends TaskHandler {
  /// 服务重建计数器
  int _rebuildCount = 0;

  /// 后台运行的守护（只做探活，动作交给主 isolate）
  KeepAliveGuard? _guard;

  /// 标记是否是用户主动划掉通知（用于区分系统自动清理）
  static bool _userDismissedNotification = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    Log.i('前台服务已启动', tag: 'KeepAliveTaskHandler');

    // 后台 isolate 里 RuntimeEnvir / settings 都可能是空的，
    // 所以时间线目录与守护参数都由主 isolate 预先写进来。
    try {
      final configPath = await FlutterForegroundTask.getData<String>(
        key: KeepAliveCommand.configPathKey,
      );
      if (configPath != null && configPath.isNotEmpty) {
        StatusTimeline.instance.configure(configPath);
      }
      final raw = await FlutterForegroundTask.getData<String>(
        key: KeepAliveCommand.guardConfigKey,
      );
      final config = GuardConfig.fromJsonString(raw) ??
          const GuardConfig(
            dashboardPort: 6185,
            probeIntervalSeconds: 20,
            failureThreshold: 3,
            autoHealEnabled: true,
          );
      _guard = KeepAliveGuard(
        isBackground: true,
        config: config,
        probeOnly: true,
      );
      // 只负责发现掉线：把主 isolate 叫醒，自愈的级别和动作都由它统一执行
      _guard!.onProbeDown = () {
        FlutterForegroundTask.sendDataToMain({
          'cmd': KeepAliveCommand.probeDown,
        });
      };
      // 探活由 onRepeatEvent 驱动，后台不再自己开定时器
      _guard!.start(useTimer: false);
    } catch (e) {
      Log.e('初始化后台守护失败: $e', tag: 'KeepAliveTaskHandler');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 根据 eventAction 设置的间隔定期调用
    // 这里只做探活；服务是否还活着由主 isolate 每 30 秒兜底检查。
    // 在服务 isolate 里判断 isRunningService 会在重启窗口内得到 false，
    // 进而触发自我重启的死循环。
    _guard?.tick();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTaskRemoved) async {
    // 服务销毁时调用
    // isTaskRemoved: 用户从最近任务中移除应用（值为true）
    Log.i(
        '前台服务被销毁，isTaskRemoved: $isTaskRemoved, 用户主动划掉: $_userDismissedNotification',
        tag: 'KeepAliveTaskHandler');

    _guard?.stop();

    // 重建场景判断：
    // 1. 如果是用户主动划掉通知：onNotificationDismissed() 已处理，这里不处理
    // 2. 如果是系统自动清理通知（如充电完成等）：onNotificationDismissed() 不会被调用，需要在这里重建
    // 3. 如果是用户点击停止按钮：不重建

    if (!_userDismissedNotification &&
        !ForegroundServiceManager.userClickedStopButton) {
      Log.w('检测到系统自动清理通知或服务被终止，准备重建...',
          tag: 'KeepAliveTaskHandler');
      // 延迟重建以确保服务完全关闭
      await Future.delayed(const Duration(milliseconds: 500));
      await _rebuildService();
    }

    // 重置用户划掉标记
    _userDismissedNotification = false;
  }

  /// 上次重建时间，防止短时间内反复重建
  static DateTime? _lastRebuildAt;

  /// 重建服务
  Future<void> _rebuildService() async {
    final now = DateTime.now();
    final last = _lastRebuildAt;
    if (last != null && now.difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _lastRebuildAt = now;
    try {
      _rebuildCount++;
      Log.i('正在重建服务（第 $_rebuildCount 次）...', tag: 'KeepAliveTaskHandler');

      final result = await ForegroundServiceManager.startService();

      if (result is ServiceRequestSuccess) {
        Log.i('服务重建成功', tag: 'KeepAliveTaskHandler');
        await StatusTimeline.instance.record(
          'service',
          'service_rebuilt',
          '后台服务已自动重建',
          level: TimelineLevel.success,
        );
        _rebuildCount = 0; // 重置计数器
      } else if (result is ServiceRequestFailure) {
        Log.e('服务重建失败: ${result.error}', tag: 'KeepAliveTaskHandler');

        // 如果重建失败，等待更长时间后再次尝试
        if (_rebuildCount < 5) {
          await Future.delayed(Duration(seconds: _rebuildCount * 2));
          await _rebuildService();
        } else {
          Log.e('服务重建失败次数过多，停止尝试', tag: 'KeepAliveTaskHandler');
          _rebuildCount = 0;
        }
      }
    } catch (e) {
      Log.e('重建服务时发生异常: $e', tag: 'KeepAliveTaskHandler');
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    // 通知按钮点击时调用
    if (id == 'btn_stop') {
      Log.i('用户点击停止按钮', tag: 'KeepAliveTaskHandler');
      // 交给主 isolate 先停 AstrBot（停进程、等端口释放），再关服务退出；
      // 主 isolate 不在时由超时兜底，不能像以前一样直接 exit(0) 留下孤儿进程。
      FlutterForegroundTask.sendDataToMain({
        'cmd': KeepAliveCommand.gracefulStop,
      });
      Future.delayed(const Duration(milliseconds: 2500), () async {
        await ForegroundServiceManager.stopService();
        exit(0);
      });
    }
  }

  @override
  void onNotificationPressed() {
    // 点击通知时调用
    Log.i('用户点击通知', tag: 'KeepAliveTaskHandler');
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    // 用户从通知栏主动划掉通知时调用
    Log.w('用户主动划掉通知，准备重建服务...', tag: 'KeepAliveTaskHandler');

    // 标记为用户主动划掉，避免 onDestroy() 中重复处理
    _userDismissedNotification = true;

    // 只有用户点击了停止按钮才不重建
    // 划掉通知应该重建服务
    if (!ForegroundServiceManager.userClickedStopButton) {
      Log.i('检测到用户主动划掉通知，将重建服务', tag: 'KeepAliveTaskHandler');
      // 延迟一小段时间后重建服务
      Future.delayed(const Duration(milliseconds: 500), () {
        _rebuildService();
      });
    } else {
      Log.i('用户点击了停止按钮，不重建服务', tag: 'KeepAliveTaskHandler');
    }
  }
}
