import 'package:settings/settings.dart';

/// 省电策略档位
/// Power saving profile
enum PowerMode {
  performance,
  balanced,
  saver;

  static PowerMode fromKey(String? key) {
    for (final value in PowerMode.values) {
      if (value.name == key) return value;
    }
    return PowerMode.balanced;
  }
}

/// 省电策略：统一决定探活频率、前台服务心跳和通知轮询间隔
/// One place that decides probe interval, foreground heartbeat and polling
class PowerPolicy {
  PowerPolicy._();

  static SettingNode get _modeNode => 'power_mode'.setting;
  static SettingNode get _autoHealNode => 'auto_heal_enabled'.setting;
  static SettingNode get _notifyMessagesNode => 'notify_messages_enabled'.setting;
  static SettingNode get _notifyErrorsNode => 'notify_errors_enabled'.setting;
  static SettingNode get _notifyBridgeNode => 'notify_bridge_enabled'.setting;

  static PowerMode get mode => PowerMode.fromKey(_safeGet(_modeNode)?.toString());

  static Future<void> setMode(PowerMode value) async {
    try {
      _modeNode.set(value.name);
    } catch (_) {
      // 配置存储还没就绪时忽略，下次启动会重新写入
    }
  }

  /// 配置存储（Hive box）在 main() 里才初始化，太早读会抛空指针；
  /// 这里统一兜住，读不到就按默认档位走。
  static void _safeSet(SettingNode node, dynamic value) {
    try {
      node.set(value);
    } catch (_) {}
  }

  static dynamic _safeGet(SettingNode node) {
    try {
      return node.get();
    } catch (_) {
      return null;
    }
  }

  static String label(PowerMode value) => switch (value) {
        PowerMode.performance => '性能优先',
        PowerMode.balanced => '均衡',
        PowerMode.saver => '省电',
      };

  static String description(PowerMode value) => switch (value) {
        PowerMode.performance => '每 10 秒探活一次，断线最快恢复，耗电略高',
        PowerMode.balanced => '每 20 秒探活一次，兼顾恢复速度与耗电',
        PowerMode.saver => '每 45 秒探活一次，最省电，恢复略慢',
      };

  /// 前台服务心跳间隔（秒）
  static int get foregroundEventSeconds => switch (mode) {
        PowerMode.performance => 5,
        PowerMode.balanced => 10,
        PowerMode.saver => 20,
      };

  /// 主 isolate 探活间隔（秒）
  static int get probeIntervalSeconds => switch (mode) {
        PowerMode.performance => 10,
        PowerMode.balanced => 20,
        PowerMode.saver => 45,
      };

  /// 连续多少次探活失败才判定 AstrBot 掉线
  static int get failureThreshold => switch (mode) {
        PowerMode.performance => 2,
        PowerMode.balanced => 3,
        PowerMode.saver => 4,
      };

  /// 消息通知轮询间隔（秒）
  static int get messagePollSeconds => switch (mode) {
        PowerMode.performance => 15,
        PowerMode.balanced => 30,
        PowerMode.saver => 90,
      };

  /// 省电档关闭唤醒锁，靠前台服务本身保活
  static bool get allowWakeLock => mode != PowerMode.saver;

  static bool get autoHealEnabled => _readBool(_autoHealNode, true);
  static Future<void> setAutoHealEnabled(bool value) async =>
      _safeSet(_autoHealNode, value);

  static bool get notifyBridgeEnabled => _readBool(_notifyBridgeNode, false);
  static Future<void> setNotifyBridgeEnabled(bool value) async =>
      _safeSet(_notifyBridgeNode, value);

  static bool get notifyMessages => _readBool(_notifyMessagesNode, true);
  static Future<void> setNotifyMessages(bool value) async =>
      _safeSet(_notifyMessagesNode, value);

  static bool get notifyErrors => _readBool(_notifyErrorsNode, true);
  static Future<void> setNotifyErrors(bool value) async =>
      _safeSet(_notifyErrorsNode, value);

  static bool _readBool(SettingNode node, bool fallback) {
    final value = _safeGet(node);
    if (value is bool) return value;
    final text = value?.toString().toLowerCase();
    if (text == 'true') return true;
    if (text == 'false') return false;
    return fallback;
  }
}
