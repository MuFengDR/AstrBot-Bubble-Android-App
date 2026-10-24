import 'package:settings/settings.dart';

/// 省电策略：统一决定探活频率、前台服务心跳和通知轮询间隔
/// One place that decides probe interval, foreground heartbeat and polling
class PowerPolicy {
  PowerPolicy._();

  /// 探活间隔（分钟）。0 表示关闭探活。
  static SettingNode get _probeMinutesNode => 'probe_interval_minutes'.setting;
  static SettingNode get _autoHealNode => 'auto_heal_enabled'.setting;
  static SettingNode get _notifyMessagesNode => 'notify_messages_enabled'.setting;
  static SettingNode get _notifyErrorsNode => 'notify_errors_enabled'.setting;
  static SettingNode get _notifyBridgeNode => 'notify_bridge_enabled'.setting;

  /// 探活间隔（分钟）：0 表示不再探活，默认 60
  static int get probeIntervalMinutes {
    final value = _safeGet(_probeMinutesNode);
    final minutes = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    return (minutes ?? defaultProbeIntervalMinutes).clamp(0, 1440);
  }

  static const int defaultProbeIntervalMinutes = 60;
  static const int maxProbeIntervalMinutes = 1440;

  static Future<void> setProbeIntervalMinutes(int minutes) async {
    try {
      _probeMinutesNode.set(minutes.clamp(0, maxProbeIntervalMinutes));
    } catch (_) {
      // 配置存储还没就绪时忽略，下次启动会重新写入
    }
  }

  /// 探活是否开启（间隔为 0 即关闭）
  static bool get probeEnabled => probeIntervalMinutes > 0;

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

  /// 探活间隔的展示文案
  static String get probeIntervalLabel {
    final minutes = probeIntervalMinutes;
    if (minutes <= 0) return '已关闭';
    if (minutes < 60) return '每 $minutes 分钟一次';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (rest == 0) return '每 $hours 小时一次';
    return '每 $hours 小时 $rest 分钟一次';
  }

  /// 前台服务心跳间隔（秒）
  static int get foregroundEventSeconds => 10;

  /// 主 isolate 探活间隔（秒）；0 表示关闭
  static int get probeIntervalSeconds => probeIntervalMinutes * 60;

  /// 连续多少次探活失败才判定 AstrBot 掉线。
  ///
  /// 只要一次：探活间隔由用户自己定（默认 60 分钟），再乘 3 的话最慢要三小时
  /// 才发现掉线，太慢。误判风险交给守卫里的二次复核兜着。
  static int get failureThreshold => 1;

  /// 消息通知轮询间隔（秒）
  static int get messagePollSeconds => 30;

  /// 保持唤醒锁，靠前台服务本身保活
  static bool get allowWakeLock => true;

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
