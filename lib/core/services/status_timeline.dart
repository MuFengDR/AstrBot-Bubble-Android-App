import 'dart:convert';
import 'dart:io';

import 'package:global_repository/global_repository.dart';

/// 时间线事件级别
/// Timeline event level
enum TimelineLevel {
  info,
  success,
  warning,
  error;

  static TimelineLevel fromKey(String? key) {
    for (final value in TimelineLevel.values) {
      if (value.name == key) return value;
    }
    return TimelineLevel.info;
  }
}

/// 一条运行状态事件
/// A single runtime status event
class TimelineEvent {
  final DateTime time;
  final String source;
  final String type;
  final TimelineLevel level;
  final String message;

  const TimelineEvent({
    required this.time,
    required this.source,
    required this.type,
    required this.level,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        's': source,
        'k': type,
        'l': level.name,
        'm': message,
      };

  static TimelineEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    final message = raw['m']?.toString() ?? '';
    if (t is! num || message.isEmpty) return null;
    return TimelineEvent(
      time: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
      source: raw['s']?.toString() ?? 'app',
      type: raw['k']?.toString() ?? 'event',
      level: TimelineLevel.fromKey(raw['l']?.toString()),
      message: message,
    );
  }

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String get dateLabel => '${time.year}-${time.month.toString().padLeft(2, '0')}'
      '-${time.day.toString().padLeft(2, '0')}';

  String toText() => '[$dateLabel $timeLabel][${level.name}][$source] $message';
}

/// 运行状态时间线（本地 jsonl 追加写，跨 isolate 以文件为准）
/// Runtime status timeline backed by an append-only jsonl file
class StatusTimeline {
  StatusTimeline._();

  static final StatusTimeline instance = StatusTimeline._();

  /// 内存中最多保留的事件数
  static const int maxEventsInMemory = 800;

  /// 文件最多保留的行数，超出后压缩重写
  static const int maxFileLines = 2500;

  /// 相同事件在窗口期内只记一次，避免刷屏
  static const Duration dedupeWindow = Duration(seconds: 45);

  final List<TimelineEvent> _events = <TimelineEvent>[];
  Future<void>? _loading;
  DateTime? _lastRecordAt;
  String? _lastSignature;

  /// 后台 isolate 里 RuntimeEnvir 不可用，需要显式指定目录
  String? _configuredBaseDir;

  /// 显式指定存储目录（前台服务 isolate 使用）
  void configure(String baseDir) {
    if (baseDir.trim().isEmpty) return;
    _configuredBaseDir = baseDir;
  }

  String get _baseDir {
    final configured = _configuredBaseDir;
    if (configured != null && configured.isNotEmpty) return configured;
    try {
      final runtime = RuntimeEnvir.configPath;
      if (runtime.isNotEmpty) return runtime;
    } catch (_) {
      // 后台 isolate 没有初始化 RuntimeEnvir，落到临时目录
    }
    return Directory.systemTemp.path;
  }

  File get _file => File('$_baseDir/status_timeline.jsonl');

  void _logError(String message) {
    try {
      Log.e(message, tag: 'Timeline');
    } catch (_) {
      // 后台 isolate 里 Log 可能不可用，忽略
    }
  }

  List<TimelineEvent> get events => List<TimelineEvent>.unmodifiable(_events);

  List<TimelineEvent> recent([int count = 5]) {
    if (_events.isEmpty) return const <TimelineEvent>[];
    final start = _events.length - count;
    return _events.sublist(start < 0 ? 0 : start).reversed.toList();
  }

  int countWhere(bool Function(TimelineEvent event) test) =>
      _events.where(test).length;

  TimelineEvent? get lastError {
    for (var i = _events.length - 1; i >= 0; i--) {
      final event = _events[i];
      if (event.level == TimelineLevel.error) return event;
    }
    return null;
  }

  /// 首次使用时从磁盘加载
  /// Load persisted events on first use
  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) {
        await _file.parent.create(recursive: true);
        return;
      }
      // 主 isolate 和前台服务 isolate 都会追加写，极端情况下可能写出
      // 半行或非法字节；这里用宽松解码，坏行在后面逐行跳过。
      final bytes = await _file.readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(content);
      final parsed = <TimelineEvent>[];
      var broken = 0;
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final event = TimelineEvent.fromJson(jsonDecode(line));
          if (event != null) {
            parsed.add(event);
          } else {
            broken++;
          }
        } catch (_) {
          // 跳过损坏行，时间线不能因为一行坏数据整体失效
          broken++;
        }
      }
      // 发现坏行就顺手把文件重写干净，避免垃圾行越积越多
      if (broken > 0) {
        await _rewrite(parsed);
      }
      if (parsed.length > maxEventsInMemory) {
        parsed.removeRange(0, parsed.length - maxEventsInMemory);
      }
      _events
        ..clear()
        ..addAll(parsed);
    } catch (e) {
      _logError('读取状态时间线失败: $e');
    }
  }

  /// 用给定的事件列表重写文件（自愈用）
  Future<void> _rewrite(List<TimelineEvent> events) async {
    try {
      await _file.parent.create(recursive: true);
      final buffer = StringBuffer();
      for (final event in events) {
        buffer.writeln(jsonEncode(event.toJson()));
      }
      await _file.writeAsString(buffer.toString(), flush: true);
    } catch (e) {
      _logError('重写状态时间线失败: $e');
    }
  }

  /// 追加一条事件
  /// Append one event
  Future<void> record(
    String source,
    String type,
    String message, {
    TimelineLevel level = TimelineLevel.info,
    bool dedupe = true,
  }) async {
    final now = DateTime.now();
    final signature = '$source|$type|$message';
    if (dedupe &&
        signature == _lastSignature &&
        _lastRecordAt != null &&
        now.difference(_lastRecordAt!) < dedupeWindow) {
      return;
    }
    _lastSignature = signature;
    _lastRecordAt = now;

    final event = TimelineEvent(
      time: now,
      source: source,
      type: type,
      level: level,
      message: message,
    );
    _events.add(event);
    if (_events.length > maxEventsInMemory) {
      _events.removeRange(0, _events.length - maxEventsInMemory);
    }

    try {
      await _file.parent.create(recursive: true);
      final line = '${jsonEncode(event.toJson())}\n';
      // append 模式写入单行，跨 isolate 读到的都是完整记录
      final raf = await _file.open(mode: FileMode.append);
      try {
        // 主 isolate 和服务 isolate 会同时追加，必须串行化整行写入
        await raf.lock(FileLock.exclusive);
        await raf.writeString(line);
        await raf.flush();
      } finally {
        try {
          await raf.unlock();
        } catch (_) {}
        await raf.close();
      }
      await _trimFileIfNeeded();
    } catch (e) {
      _logError('写入状态时间线失败: $e');
    }
  }

  Future<void> _trimFileIfNeeded() async {
    try {
      final stat = await _file.stat();
      // 粗略用字节数控制：单行约 150B，2MB 已经远超需要
      if (stat.size < 2 * 1024 * 1024) return;
      final bytes = await _file.readAsBytes();
      final lines = const LineSplitter()
          .convert(utf8.decode(bytes, allowMalformed: true));
      if (lines.length <= maxFileLines) return;
      final kept = lines.sublist(lines.length - maxFileLines);
      await _file.writeAsString('${kept.join('\n')}\n');
    } catch (e) {
      _logError('压缩状态时间线失败: $e');
    }
  }

  /// 重新从磁盘读取（UI 侧定时刷新用）
  /// Reload from disk, used by the UI refresh timer
  Future<void> reload() async {
    _loading = null;
    await ensureLoaded();
  }

  Future<void> clear() async {
    _events.clear();
    _loading = null;
    _lastSignature = null;
    _lastRecordAt = null;
    try {
      if (await _file.exists()) {
        await _file.writeAsString('');
      }
    } catch (e) {
      _logError('清空状态时间线失败: $e');
    }
  }

  String exportAsText({int limit = 500}) {
    final slice = _events.length > limit
        ? _events.sublist(_events.length - limit)
        : _events;
    return slice.map((event) => event.toText()).join('\n');
  }

  /// 按天分组，供时间线页面渲染
  /// Group events by day for the timeline page
  Map<String, List<TimelineEvent>> groupedByDay({bool onlyAbnormal = false}) {
    final grouped = <String, List<TimelineEvent>>{};
    for (final event in _events) {
      if (onlyAbnormal &&
          event.level != TimelineLevel.warning &&
          event.level != TimelineLevel.error) {
        continue;
      }
      grouped.putIfAbsent(event.dateLabel, () => <TimelineEvent>[]).add(event);
    }
    return grouped;
  }
}
