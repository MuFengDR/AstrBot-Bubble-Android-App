import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:global_repository/global_repository.dart';
import 'package:http/http.dart' as http;

import '../config/service_ports.dart';
import '../constants/scripts.dart';

/// 一条日志：`key` 用于去重（同一句话重复发也能区分开），`text` 是清洗后的正文
class AstrBotLogEntry {
  const AstrBotLogEntry(this.key, this.text);

  final String key;
  final String text;

  @override
  String toString() => text;
}

/// AstrBot 面板的只读访问封装
/// Read-only access to the local AstrBot dashboard
///
/// 面板密码登录接口在不同版本之间变动较大，这里沿用 App 既有的做法：
/// 读取本机 cmd_config.json 里的 jwt_secret 自签一个短期 JWT，只对 127.0.0.1 使用。
class AstrBotApi {
  AstrBotApi._();

  static String? _cachedJwt;
  static DateTime? _cachedAt;
  static String? _cachedLogEndpoint;

  static File get _configFile =>
      File('$ubuntuPath/root/AstrBot/data/cmd_config.json');

  /// 判断 AstrBot 是否已经安装
  static bool get isInstalled =>
      File('$ubuntuPath/root/AstrBot/pyproject.toml').existsSync();

  /// 生成本地 JWT，缓存 5 分钟
  static String? _jwt() {
    final now = DateTime.now();
    if (_cachedJwt != null &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < const Duration(minutes: 5)) {
      return _cachedJwt;
    }
    try {
      if (!_configFile.existsSync()) return null;
      final raw = jsonDecode(_configFile.readAsStringSync());
      if (raw is! Map) return null;
      final dashboard = raw['dashboard'];
      if (dashboard is! Map) return null;
      final username = dashboard['username']?.toString() ?? '';
      final secret = dashboard['jwt_secret']?.toString() ?? '';
      if (username.isEmpty || secret.isEmpty) return null;

      final header = _base64UrlJson({'alg': 'HS256', 'typ': 'JWT'});
      final payload = _base64UrlJson({
        'username': username,
        'exp': now.toUtc().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
            1000,
      });
      final unsigned = '$header.$payload';
      final signature =
          Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(unsigned));
      final token =
          '$unsigned.${base64Url.encode(signature.bytes).replaceAll('=', '')}';
      _cachedJwt = token;
      _cachedAt = now;
      return token;
    } catch (e) {
      Log.e('生成 AstrBot 本地 JWT 失败: $e', tag: 'AstrBotApi');
      return null;
    }
  }

  static String _base64UrlJson(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  static Map<String, String> _headers() {
    final token = _jwt();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
  }

  /// 拉取最近的日志文本（新老版本接口都试一遍）
  /// Fetch recent log lines, trying both new and legacy endpoints
  static Future<List<AstrBotLogEntry>> fetchRecentLogs({int limit = 80}) async {
    final endpoints = <String>[
      if (_cachedLogEndpoint != null) _cachedLogEndpoint!,
      '/api/logs/history',
      '/api/log-history',
    ];
    for (final endpoint in endpoints) {
      final lines = await _tryFetchLogs(endpoint, limit);
      if (lines != null) {
        _cachedLogEndpoint = endpoint;
        return lines;
      }
    }
    return const <AstrBotLogEntry>[];
  }

  static Future<List<AstrBotLogEntry>?> _tryFetchLogs(
    String endpoint,
    int limit,
  ) async {
    try {
      final uri = Uri.parse(
        '${ServicePorts.dashboardUrl}$endpoint?limit=$limit',
      );
      final response = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 6));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return _extractLogLines(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 兼容多种返回结构，尽量把日志条目变成可读文本
  static List<AstrBotLogEntry>? _extractLogLines(Object? decoded) {
    if (decoded is! Map) return null;
    final data = decoded['data'] ?? decoded;
    Object? rawList;
    if (data is List) {
      rawList = data;
    } else if (data is Map) {
      rawList = data['logs'] ?? data['history'] ?? data['items'];
    }
    if (rawList is! List) return null;
    final lines = <AstrBotLogEntry>[];
    for (var i = 0; i < rawList.length; i++) {
      final entry = _formatLogItem(rawList[i], i);
      if (entry != null) lines.add(entry);
    }
    return lines;
  }

  /// 终端颜色控制符，`/api/log-history` 返回的原文里成片都是
  static final RegExp _ansiPattern = RegExp('\u001B\\[[0-9;?]*[ -/]*[@-~]');

  /// 行首的 `[时间] [Core] [INFO] [模块:行]: ` 前缀
  static final RegExp _prefixPattern = RegExp(r'^\s*(?:\[[^\]]*\]\s*){1,4}:\s*');

  /// AstrBot 4.x 事件总线打印的会话行，剥掉前缀后形如
  /// `[default] [pre-config(aiocqhttp)] 昵称/号码: 内容`
  static final RegExp _eventBusPattern =
      RegExp(r'^(?:\[[^\]]*\]\s*)+([^\[\]:]+?)/([^\s:]+)\s*:\s*(.+)$');

  static AstrBotLogEntry? _formatLogItem(Object? item, int index) {
    if (item is! Map) {
      final text = _cleanLine(item?.toString() ?? '');
      return text.isEmpty ? null : AstrBotLogEntry('$index|$text', text);
    }
    // AstrBot 4.x 的 data 字段已经是完整日志行（含时间/等级/模块），交给 _cleanLine 剥
    final raw = item['message'] ??
        item['msg'] ??
        item['content'] ??
        item['text'] ??
        item['data'] ??
        '';
    final body = _cleanLine(raw.toString());
    if (body.isEmpty) return null;
    final level =
        (item['level'] ?? item['levelname'] ?? item['type'] ?? '').toString();
    final text = level.isEmpty ? body : '[${level.toUpperCase()}] $body';
    // 去重键带上日志自身的时间戳：同一句话连发两次也不会被当成同一条
    final stamp = item['time'] ?? item['timestamp'] ?? item['created_at'];
    final key = stamp == null ? '$index|$text' : '$stamp|$text';
    return AstrBotLogEntry(key, text);
  }

  /// 去色码、多行只留最后一条有内容的、剥掉冗长的日志前缀
  static String _cleanLine(String text) {
    var line = text.replaceAll(_ansiPattern, '');
    final parts = line
        .split('\n')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    line = parts.last;
    final match = _prefixPattern.firstMatch(line);
    if (match != null && match.end < line.length) {
      line = line.substring(match.end).trim();
    }
    // 会话行统一成 `[MSG] 昵称: 内容`，通知桥只认这个标记
    // 只处理 QQ 平台：WebUI 里自己的对话不该弹系统通知
    final convo = _eventBusPattern.firstMatch(line);
    if (convo != null && line.contains('aiocqhttp')) {
      final who = convo.group(1)!.trim();
      final body = convo.group(3)!.trim();
      if (body.isNotEmpty) return '[MSG] $who: $body';
    }
    return line;
  }

  /// 读取 AstrBot 的启动时间（用作「进程换了」的判断依据）
  static Future<int?> fetchStartTime() async {
    for (final endpoint in ['/api/stat/start-time', '/api/start-time']) {
      try {
        final response = await http
            .get(Uri.parse('${ServicePorts.dashboardUrl}$endpoint'),
                headers: _headers())
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) continue;
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final data = decoded is Map ? decoded['data'] : null;
        if (data is num) return data.toInt();
        if (data is Map) {
          final value = data['start_time'] ?? data['startTime'];
          if (value is num) return value.toInt();
          final parsed = int.tryParse(value?.toString() ?? '');
          if (parsed != null) return parsed;
        }
      } catch (_) {
        // 老版本没有这个接口，忽略
      }
    }
    return null;
  }
}
