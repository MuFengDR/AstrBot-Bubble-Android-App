import 'dart:async';

import 'package:flutter/services.dart';
import 'package:global_repository/global_repository.dart';

import 'astrbot_api.dart';
import 'power_policy.dart';
import 'status_timeline.dart';

/// 把 AstrBot 的关键动态转成系统通知
/// Turn key AstrBot activity into system notifications
///
/// 数据源是本机面板的日志接口：AstrBot 收到 QQ 消息、插件报错都会写在里面。
/// 走日志而不是数据库，兼容 AstrBot 3.x / 4.x，也不需要额外的原生依赖。
class MessageBridge {
  MessageBridge._();

  static final MessageBridge instance = MessageBridge._();

  static const MethodChannel _channel = MethodChannel('astrbot_channel');

  /// 只在内存里记最近见过的行，重启后重新建立基线，不会补推历史消息
  static const int _seenLimit = 240;

  final List<String> _seen = <String>[];
  Timer? _timer;
  bool _running = false;
  bool _baselineReady = false;
  DateTime? _lastNotifyAt;
  String? _lastNotifyKey;

  bool get running => _running;

  /// 消息类日志的识别规则
  /// `[MSG]` 是 AstrBotApi 给会话行打的标记（4.x 的 event_bus 格式）
  static final RegExp _messagePattern = RegExp(
    r'(\[MSG\]|收到|发送|\[QQ\]|群消息|私聊)',
    caseSensitive: false,
  );

  /// 去掉标记，只留可读正文
  /// 可叠加多层（`[INFO] [MSG] ...`），一次剥干净
  static final RegExp _tagPattern =
      RegExp(r'^(?:\[(?:MSG|ERROR|WARNING|INFO|DEBUG)\]\s*)+');

  /// 异常类日志的识别规则
  static final RegExp _errorPattern = RegExp(
    r'(\[ERROR\]|\bERROR\b|Traceback|Exception|失败|error:)',
    caseSensitive: false,
  );

  /// 噪音行，直接忽略
  static final RegExp _noisePattern = RegExp(
    r'(DEBUG|心跳|heartbeat|WebSocket.*ping|GET /api/|POST /api/)',
    caseSensitive: false,
  );

  Future<void> start() async {
    if (_running) return;
    if (!PowerPolicy.notifyBridgeEnabled) return;
    _running = true;
    _baselineReady = false;
    _seen.clear();
    await StatusTimeline.instance.record(
      'notify',
      'bridge_start',
      '消息通知桥已启动（每 ${PowerPolicy.messagePollSeconds} 秒检查一次）',
    );
    _timer = Timer.periodic(
      Duration(seconds: PowerPolicy.messagePollSeconds),
      (_) => pollOnce(),
    );
    unawaited(pollOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_running) {
      _running = false;
      unawaited(StatusTimeline.instance.record(
        'notify',
        'bridge_stop',
        '消息通知桥已停止',
      ));
    }
  }

  Future<void> restart() async {
    stop();
    await start();
  }

  /// 拉一次日志并推送新内容
  Future<void> pollOnce() async {
    if (!_running) return;
    if (!AstrBotApi.isInstalled) return;
    final entries = await AstrBotApi.fetchRecentLogs(limit: 60);
    if (entries.isEmpty) return;

    final fresh = <String>[];
    for (final entry in entries) {
      final text = entry.text.trim();
      if (text.isEmpty || _noisePattern.hasMatch(text)) continue;
      // 按「时间戳 + 内容」去重，同一句话连发两次也算两条
      if (_seen.contains(entry.key)) continue;
      fresh.add(text);
      _remember(entry.key);
    }

    // 第一次拉取只建立基线，避免一启动就把一屏历史消息推出去
    if (!_baselineReady) {
      _baselineReady = true;
      return;
    }
    if (fresh.isEmpty) return;

    final errors = <String>[];
    final messages = <String>[];
    for (final line in fresh) {
      // 会话行优先，避免用户发的「报错了」之类被当成异常
      if (line.contains('[MSG]')) {
        if (PowerPolicy.notifyMessages) messages.add(_stripTag(line));
        continue;
      }
      if (_errorPattern.hasMatch(line)) {
        if (PowerPolicy.notifyErrors) errors.add(_stripTag(line));
      } else if (_messagePattern.hasMatch(line)) {
        if (PowerPolicy.notifyMessages) messages.add(_stripTag(line));
      }
    }

    if (errors.isNotEmpty) {
      await _notify(
        key: 'error',
        title: 'AstrBot 出现异常',
        body: _shorten(errors.last),
        level: TimelineLevel.error,
        type: 'notify_error',
      );
    }
    if (messages.isNotEmpty) {
      await _notify(
        key: 'message',
        title: errors.isEmpty ? 'AstrBot 有新消息' : 'AstrBot 有新消息（含异常）',
        body: messages.length > 1
            ? '${_shorten(messages.last)}（另有 ${messages.length - 1} 条）'
            : _shorten(messages.last),
        level: TimelineLevel.info,
        type: 'notify_message',
      );
    }
  }

  void _remember(String line) {
    _seen.add(line);
    if (_seen.length > _seenLimit) {
      _seen.removeRange(0, _seen.length - _seenLimit);
    }
  }

  Future<void> _notify({
    required String key,
    required String title,
    required String body,
    required TimelineLevel level,
    required String type,
  }) async {
    final now = DateTime.now();
    // 同一类通知 45 秒内只弹一次，避免刷屏
    if (_lastNotifyKey == key &&
        _lastNotifyAt != null &&
        now.difference(_lastNotifyAt!) < const Duration(seconds: 45)) {
      return;
    }
    _lastNotifyKey = key;
    _lastNotifyAt = now;

    await showNotification(title: title, body: body);
    await StatusTimeline.instance.record(
      'notify',
      type,
      '$title：$body',
      level: level,
      dedupe: false,
    );
  }

  static String _stripTag(String line) =>
      line.replaceFirst(_tagPattern, '').trim();

  static String _shorten(String text, {int max = 120}) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (single.length <= max) return single;
    return '${single.substring(0, max)}…';
  }

  /// 通过原生通道弹一条系统通知
  static Future<bool> showNotification({
    required String title,
    required String body,
    int id = 9901,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('notify', {
        'id': id,
        'title': title,
        'body': body,
      });
      return result == true;
    } catch (e) {
      Log.e('发送系统通知失败: $e', tag: 'MessageBridge');
      return false;
    }
  }
}
