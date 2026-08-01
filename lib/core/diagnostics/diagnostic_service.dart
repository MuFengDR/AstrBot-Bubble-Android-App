import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:global_repository/global_repository.dart';
import 'package:http/http.dart' as http;

import '../../ui/controllers/terminal_controller.dart';
import '../config/service_ports.dart';
import '../constants/scripts.dart' as scripts;

enum DiagnosticStatus { pending, running, passed, warning, failed }

class DiagnosticItem {
  final String title;
  DiagnosticStatus status;
  String detail;
  String reportSummary;
  String reportDetail;

  DiagnosticItem(
    this.title, {
    this.status = DiagnosticStatus.pending,
    this.detail = '',
    this.reportSummary = '',
    this.reportDetail = '',
  });
}

class DiagnosticReport {
  final List<DiagnosticItem> items;
  final DateTime startedAt;
  final bool modelTestRequested;
  final bool modelTestSkipped;

  DiagnosticReport({
    required this.items,
    required this.startedAt,
    required this.modelTestRequested,
    required this.modelTestSkipped,
  });

  String toText() {
    final out = StringBuffer(
      'AstrBot 诊断报告\n时间：${startedAt.toLocal()}\n',
    );
    out.writeln('模型测试：${modelTestSkipped ? '已跳过' : '已执行'}');
    for (final item in items) {
      final mark = switch (item.status) {
        DiagnosticStatus.passed => '[正常]',
        DiagnosticStatus.warning => '[注意]',
        DiagnosticStatus.failed => '[异常]',
        _ => '[未完成]',
      };
      if (item.reportDetail.isNotEmpty) {
        out.writeln(
          '$mark ${item.title}：${item.reportSummary}',
        );
        out.writeln(item.reportDetail);
      } else {
        out.writeln(
          '$mark ${item.title}${item.detail.isEmpty ? '' : '：${item.detail}'}',
        );
      }
    }
    return out.toString();
  }
}

class _ConfigInfo {
  final String id;
  final String name;
  final Map<String, dynamic> data;

  const _ConfigInfo(this.id, this.name, this.data);
}

class _NapCatDiagnosticAccount {
  final Map<String, dynamic> instance;
  final NapCatWebSocketClient? client;
  final AstrBotOneBotAdapter? adapter;
  final BotBindingConfigState bindingState;

  const _NapCatDiagnosticAccount({
    required this.instance,
    required this.client,
    required this.adapter,
    required this.bindingState,
  });

  String get name => instance['name']?.toString().trim().isNotEmpty == true
      ? instance['name'].toString()
      : '未命名账号';
  String get qq => instance['qq']?.toString().trim() ?? '';
  int get webUiPort =>
      int.tryParse(instance['webUiPort']?.toString() ?? '') ?? -1;
  bool get running => instance['running'] == true;
}

class _BotDiagnosticContext {
  final List<_NapCatDiagnosticAccount> accounts;
  final List<AstrBotOneBotAdapter> adapters;

  const _BotDiagnosticContext({
    required this.accounts,
    required this.adapters,
  });

  List<_NapCatDiagnosticAccount> get runningAccounts =>
      accounts.where((account) => account.running).toList();
}

class _ConfigRoutingInfo {
  final Map<String, String> names;
  final Map<String, String> routes;

  const _ConfigRoutingInfo({required this.names, required this.routes});
}

@visibleForTesting
Object? firstNonEmptyDiagnosticValue(Iterable<Object?> values) {
  for (final value in values) {
    if (value == null) continue;
    if (value is String && value.trim().isEmpty) continue;
    if (value is Iterable && value.isEmpty) continue;
    return value;
  }
  return null;
}

@visibleForTesting
List<String> diagnosticConfigIdsForAdapter(
  String adapterId,
  Map<String, String> routes,
) {
  final ids = <String>[];
  for (final entry in routes.entries) {
    final parts = entry.key.split(':');
    if (parts.length != 3 || !_diagnosticWildcardMatch(parts[0], adapterId)) {
      continue;
    }
    if (!ids.contains(entry.value)) ids.add(entry.value);
  }
  return ids.isEmpty ? const ['default'] : ids;
}

bool _diagnosticWildcardMatch(String pattern, String value) {
  if (pattern.isEmpty || pattern == '*') return true;
  final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
  return RegExp('^$escaped\$').hasMatch(value);
}

@visibleForTesting
bool diagnosticProcessIsHealthy({
  required bool astrBotRunning,
  required int runningAccountCount,
}) =>
    astrBotRunning && runningAccountCount > 0;

@visibleForTesting
bool diagnosticConnectionsAreHealthy({
  required bool astrBotRunning,
  required Iterable<BotBindingConfigState> runningBindings,
}) {
  final states = runningBindings.toList();
  return astrBotRunning &&
      states.isNotEmpty &&
      states.every((state) => state == BotBindingConfigState.configured);
}

@visibleForTesting
String diagnosticBindingStateLabel(BotBindingConfigState state) =>
    switch (state) {
      BotBindingConfigState.configured => '已绑定BOT',
      BotBindingConfigState.disabled => '已禁用BOT',
      BotBindingConfigState.mismatch => 'BOT绑定异常',
      BotBindingConfigState.unconfigured => '未绑定BOT',
    };

class DiagnosticService {
  static const preferenceKey = 'astrbot_diagnostic_model_preference';
  static const modelPreferenceSkip = 'skip';
  static const modelPreferenceAgree = 'agree';

  static const itemTitles = <String>[
    '应用状态',
    '后台运行权限',
    '运行环境检查',
    'AstrBot 和 NapCat 运行状态',
    'NapCat 连接检查',
    'AstrBot 配置检查',
    '模型连通性测试',
  ];

  final HomeController controller;
  final ValueChanged<DiagnosticItem>? onChanged;
  bool _cancelled = false;
  List<_ConfigInfo>? _configs;
  _BotDiagnosticContext? _botContext;
  _ConfigRoutingInfo? _routingInfo;

  DiagnosticService(this.controller, {this.onChanged});

  void cancel() => _cancelled = true;

  Future<DiagnosticReport> run({required bool testModel}) async {
    _cancelled = false;
    final items = itemTitles.map(DiagnosticItem.new).toList();
    final startedAt = DateTime.now();

    for (var i = 0; i < items.length; i++) {
      if (_cancelled) break;
      final item = items[i]..status = DiagnosticStatus.running;
      onChanged?.call(item);
      try {
        switch (i) {
          case 0:
            item
              ..status = DiagnosticStatus.passed
              ..detail = '泡泡版运行正常';
            break;
          case 1:
            await _checkBackgroundPermission(item);
            break;
          case 2:
            await _checkEnvironment(item);
            break;
          case 3:
            await _checkProcesses(item);
            break;
          case 4:
            await _checkBindings(item);
            break;
          case 5:
            await _summarizeConfigs(item);
            break;
          case 6:
            if (testModel) {
              await _testModels(item);
            } else {
              item
                ..status = DiagnosticStatus.warning
                ..detail = '已按你的选择跳过';
            }
            break;
        }
      } catch (error) {
        item
          ..status = DiagnosticStatus.failed
          ..detail = _safeError(error);
      }
      onChanged?.call(item);
    }

    return DiagnosticReport(
      items: items,
      startedAt: startedAt,
      modelTestRequested: testModel,
      modelTestSkipped: !testModel,
    );
  }

  Future<void> _checkBackgroundPermission(DiagnosticItem item) async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    item
      ..status =
          status.isGranted ? DiagnosticStatus.passed : DiagnosticStatus.warning
      ..detail = status.isGranted ? '允许在后台持续运行' : '未允许后台持续运行，切到后台后机器人可能停止';
  }

  Future<void> _checkEnvironment(DiagnosticItem item) async {
    final root = scripts.ubuntuPath;
    final checks = <String, bool>{
      '基础环境': Directory('$root/root').existsSync() &&
          File('$root/usr/bin/curl').existsSync() &&
          File('$root/usr/bin/git').existsSync() &&
          File('$root/usr/bin/sudo').existsSync(),
      'uv': File('$root/root/.local/bin/uv').existsSync() &&
          File('$root/root/.local/bin/uvx').existsSync(),
      'NapCat': Directory('$root/root/napcat').existsSync() &&
          File('$root/root/libnapcat_launcher.so').existsSync(),
      'AstrBot': controller.isAstrBotInstalled,
    };
    final missing = checks.entries
        .where((entry) => !entry.value)
        .map((entry) => entry.key)
        .toList();
    item
      ..status =
          missing.isEmpty ? DiagnosticStatus.passed : DiagnosticStatus.failed
      ..detail = missing.isEmpty ? '所有环境均已安装' : '未安装完整：${missing.join('、')}';
  }

  Future<_BotDiagnosticContext> _loadBotContext() async {
    if (_botContext != null) return _botContext!;
    final adapters = await controller.listAstrBotOneBotAdapters();
    final accounts = <_NapCatDiagnosticAccount>[];
    for (final raw in controller.napCatInstances) {
      final instance = Map<String, dynamic>.from(raw);
      final qq = instance['qq']?.toString().trim() ?? '';
      if (qq.isEmpty) continue;
      final id = instance['id']?.toString() ?? '';
      final boundClientName = instance['boundWebSocketName']?.toString() ?? '';
      final boundAdapterId = instance['boundAdapterId']?.toString() ?? '';
      final clients = id.isEmpty
          ? const <NapCatWebSocketClient>[]
          : await controller.listNapCatWebSocketClients(id);
      final client =
          clients.where((entry) => entry.name == boundClientName).firstOrNull;
      final adapter =
          adapters.where((entry) => entry.id == boundAdapterId).firstOrNull;
      accounts.add(
        _NapCatDiagnosticAccount(
          instance: instance,
          client: client,
          adapter: adapter,
          bindingState: controller.compareBotBinding(client, adapter),
        ),
      );
    }
    return _botContext = _BotDiagnosticContext(
      accounts: accounts,
      adapters: adapters,
    );
  }

  Future<void> _checkProcesses(DiagnosticItem item) async {
    final astrBotRunning = controller.isAstrBotActive;
    final context = await _loadBotContext();
    final configured = context.accounts.length;
    final running = context.runningAccounts.length;

    final details = <String>[
      'AstrBot ${astrBotRunning ? '运行正常' : '未运行'}',
      if (configured == 0)
        'NapCat 没有已登录账号'
      else if (running == 0)
        'NapCat 未运行（0/$configured）'
      else
        'NapCat 运行正常（$running/$configured）',
    ];
    final summary = details.join('；');
    final processLines = <String>[
      '\tAstrBot ${ServicePorts.dashboardPort} ${astrBotRunning ? '正常运行' : '未运行'}',
      ...context.accounts.map(
        (account) =>
            '\t${account.name} ${account.qq} ${account.webUiPort < 0 ? '端口未配置' : account.webUiPort} '
            '${account.running ? '正常运行' : '未运行'}',
      ),
    ];
    item
      ..status = diagnosticProcessIsHealthy(
        astrBotRunning: astrBotRunning,
        runningAccountCount: running,
      )
          ? DiagnosticStatus.passed
          : DiagnosticStatus.failed
      ..detail = summary
      ..reportSummary = '$summary：'
      ..reportDetail = processLines.join('\n');
  }

  Future<void> _checkBindings(DiagnosticItem item) async {
    final context = await _loadBotContext();
    final routing = await _loadConfigRoutingInfo();
    final running = context.runningAccounts;
    final invalid = running
        .where((account) =>
            account.bindingState != BotBindingConfigState.configured)
        .length;
    final passed = diagnosticConnectionsAreHealthy(
      astrBotRunning: controller.isAstrBotActive,
      runningBindings: running.map((account) => account.bindingState),
    );

    final adapterLines = context.adapters.map((adapter) {
      final configNames =
          diagnosticConfigIdsForAdapter(adapter.id, routing.routes)
              .map(_configDisplayName)
              .join('、');
      return '\t\t${adapter.id} ${adapter.port} $configNames '
          '${adapter.enabled ? '已启用' : '未启用'}';
    });
    final socketLines = context.accounts.map((account) {
      final port = account.client?.port?.toString() ?? '端口未配置';
      final state = !account.running
          ? '未运行'
          : diagnosticBindingStateLabel(account.bindingState);
      return '\t\t${account.name} ${account.qq} $port $state';
    });
    item
      ..status = passed ? DiagnosticStatus.passed : DiagnosticStatus.failed
      ..detail = passed
          ? '连接正常（${running.length} 个运行账号）'
          : running.isEmpty
              ? '连接异常：没有已登录且正在运行的账号'
              : '连接异常：$invalid 个运行账号连接异常'
      ..reportSummary = passed ? '连接正常' : '连接异常'
      ..reportDetail = <String>[
        '\tAstrBot适配器：',
        if (context.adapters.isEmpty) '\t\t（无）' else ...adapterLines,
        '\twebsocket适配器：',
        if (context.accounts.isEmpty) '\t\t（无已登录账号）' else ...socketLines,
      ].join('\n');
  }

  Future<List<_ConfigInfo>> _readConfigs() async {
    if (_configs != null) return _configs!;
    final root = '${scripts.ubuntuPath}/root/AstrBot/data';
    final files = <File>[File('$root/cmd_config.json')];
    final configDir = Directory('$root/config');
    if (configDir.existsSync()) {
      files.addAll(
        configDir.listSync().whereType<File>().where((file) =>
            file.uri.pathSegments.last.startsWith('abconf_') &&
            file.path.endsWith('.json')),
      );
    }

    final configs = <_ConfigInfo>[];
    for (final file in files) {
      if (!file.existsSync()) {
        throw StateError('找不到 ${file.uri.pathSegments.last}');
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('配置文件格式错误');
      }
      final name = file.uri.pathSegments.last;
      final id = name == 'cmd_config.json'
          ? 'default'
          : name.replaceFirst('abconf_', '').replaceFirst('.json', '');
      configs.add(_ConfigInfo(id, id == 'default' ? '默认配置' : id,
          Map<String, dynamic>.from(decoded)));
    }
    _configs = configs;
    return configs;
  }

  Future<_ConfigRoutingInfo> _loadConfigRoutingInfo() async {
    if (_routingInfo != null) return _routingInfo!;
    final configs = await _readConfigs();
    final names = <String, String>{
      for (final config in configs)
        config.id: config.id == 'default' ? 'default' : config.name,
    };
    final routes = <String, String>{};
    final defaultConfig =
        configs.where((config) => config.id == 'default').first;
    final dashboard = _asMap(defaultConfig.data['dashboard']);
    final username = dashboard['username']?.toString() ?? '';
    final secret = dashboard['jwt_secret']?.toString() ?? '';
    if (!controller.isAstrBotActive || username.isEmpty || secret.isEmpty) {
      return _routingInfo = _ConfigRoutingInfo(names: names, routes: routes);
    }

    try {
      final jwt = _createJwt(username, secret);
      final responses = await Future.wait([
        http.get(
          Uri.parse('${ServicePorts.dashboardUrl}/api/config/abconfs'),
          headers: {'Authorization': 'Bearer $jwt'},
        ).timeout(const Duration(seconds: 10)),
        http.get(
          Uri.parse(
              '${ServicePorts.dashboardUrl}/api/config/umo_abconf_routes'),
          headers: {'Authorization': 'Bearer $jwt'},
        ).timeout(const Duration(seconds: 10)),
      ]);
      final configData = _responseData(responses[0]);
      final infoList = configData['info_list'];
      if (infoList is List) {
        for (final raw in infoList.whereType<Map>()) {
          final id = raw['id']?.toString() ?? '';
          final name = raw['name']?.toString().trim() ?? '';
          if (id.isNotEmpty) names[id] = name.isEmpty ? id : name;
        }
      }
      final routeData = _responseData(responses[1]);
      final rawRoutes = routeData['routing'];
      if (rawRoutes is Map) {
        for (final entry in rawRoutes.entries) {
          routes[entry.key.toString()] = entry.value.toString();
        }
      }
    } catch (_) {
      // Older AstrBot versions may not expose these endpoints. UUIDs and the
      // default configuration remain usable as a safe fallback.
    }
    return _routingInfo = _ConfigRoutingInfo(names: names, routes: routes);
  }

  Map<String, dynamic> _responseData(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const {};
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? decoded['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }

  String _configDisplayName(String id) =>
      _routingInfo?.names[id] ?? (id == 'default' ? 'default' : id);

  Set<String> _activeConfigIds(_BotDiagnosticContext context) {
    final routes = _routingInfo?.routes ?? const <String, String>{};
    return context.runningAccounts
        .where((account) => account.adapter != null)
        .expand((account) =>
            diagnosticConfigIdsForAdapter(account.adapter!.id, routes))
        .toSet();
  }

  Future<void> _summarizeConfigs(DiagnosticItem item) async {
    final configs = await _readConfigs();
    await _loadConfigRoutingInfo();
    final context = await _loadBotContext();
    final activeIds = _activeConfigIds(context);
    final relevantConfigs =
        configs.where((config) => activeIds.contains(config.id)).toList();
    final missingIds =
        activeIds.difference(configs.map((config) => config.id).toSet());
    final summaries = <String>[];
    final reportSections = <String>[];
    var hasProblem = relevantConfigs.isEmpty || missingIds.isNotEmpty;

    for (final id in missingIds) {
      summaries.add('${_configDisplayName(id)}：配置文件不存在');
      reportSections.add('\t${_configDisplayName(id)}：\n\t\t配置文件不存在');
    }

    for (final config in relevantConfigs) {
      final providers = _findProviders(config.data);
      final enabled =
          providers.where((provider) => provider['enable'] != false).length;
      final settings = config.data['provider_settings'] is Map
          ? Map<String, dynamic>.from(config.data['provider_settings'])
          : const <String, dynamic>{};
      final defaultId = settings['default_provider_id']?.toString() ?? '';
      final defaultProvider = providers
          .where((provider) => provider['id']?.toString() == defaultId)
          .firstOrNull;
      final defaultOk =
          defaultProvider != null && defaultProvider['enable'] != false;
      if (defaultId.isEmpty || !defaultOk) hasProblem = true;

      final wake = firstNonEmptyDiagnosticValue([
        config.data['wake_prefix'],
        config.data['wake_prefixes'],
        settings['wake_prefix'],
      ]);
      final admins = config.data['admins_id'] is List
          ? (config.data['admins_id'] as List)
              .where((entry) => entry.toString() != 'astrbot')
              .length
          : 0;
      final platformSettings = _asMap(config.data['platform_settings']);
      final proactive = _asMap(settings['proactive_capability']);
      final activeReply = _asMap(settings['active_reply']);
      final plugins = _resolvePluginNames(config.data['plugin_set']);
      summaries.add(
        '${_configDisplayName(config.id)}：模型 $enabled/${providers.length}，'
        '默认模型 ${defaultId.isEmpty ? '未配置' : defaultId}'
        '${defaultId.isNotEmpty && !defaultOk ? '（不可用）' : ''}，'
        '管理员 $admins，唤醒词 ${_displayValue(wake)}',
      );
      reportSections.add(
        _buildConfigReport(
          config: config,
          enabledProviders: enabled,
          providerCount: providers.length,
          defaultId: defaultId,
          defaultOk: defaultOk,
          admins: admins,
          wake: wake,
          extraWake: settings['wake_prefix'],
          computerRuntime: settings['computer_use_runtime'],
          computerRequiresAdmin: settings['computer_use_require_admin'],
          proactiveEnabled: proactive['add_cron_tools'],
          uniqueSession: platformSettings['unique_session'],
          activeReply: activeReply,
          plugins: plugins,
        ),
      );
    }

    item
      ..status = hasProblem ? DiagnosticStatus.failed : DiagnosticStatus.passed
      ..detail = summaries.isEmpty ? '没有已运行账号可映射到配置文件' : summaries.join('\n')
      ..reportDetail = reportSections.isEmpty
          ? '\t（没有已运行账号可映射到配置文件）'
          : reportSections.join('\n\n');
  }

  String _buildConfigReport({
    required _ConfigInfo config,
    required int enabledProviders,
    required int providerCount,
    required String defaultId,
    required bool defaultOk,
    required int admins,
    required Object? wake,
    required Object? extraWake,
    required Object? computerRuntime,
    required Object? computerRequiresAdmin,
    required Object? proactiveEnabled,
    required Object? uniqueSession,
    required Map<String, dynamic> activeReply,
    required List<String> plugins,
  }) {
    final defaultModel =
        defaultId.isEmpty ? '未配置' : '$defaultId${defaultOk ? '' : '（不可用）'}';
    final whitelist = activeReply['whitelist'];
    final whitelistCount = whitelist is List ? whitelist.length : 0;
    final lines = <String>[
      '\t${_configDisplayName(config.id)}：',
      '\t\t模型：$enabledProviders/$providerCount',
      '\t\t默认模型：$defaultModel',
      '\t\t管理员：$admins',
      '\t\t唤醒词：${_displayWakePrefixes(wake)}',
      '\t\t额外唤醒词：${_displayValue(extraWake)}',
      '\t\t电脑能力：',
      '\t\t\t运行环境：${_displayValue(computerRuntime)}',
      '\t\t\t需要管理员权限：${_displaySwitch(computerRequiresAdmin)}',
      '\t\t主动型能力：${_displaySwitch(proactiveEnabled)}',
      '\t\t隔离会话：${_displaySwitch(uniqueSession)}',
      '\t\t主动回复：',
      '\t\t\t开关：${_displaySwitch(activeReply['enable'])}',
      '\t\t\t概率：${_displayValue(activeReply['possibility_reply'])}',
      '\t\t\t白名单数量：$whitelistCount',
      '\t\t插件列表：',
      if (plugins.isEmpty)
        '\t\t\t（无）'
      else
        ...plugins.map((name) => '\t\t\t$name'),
    ];
    return lines.join('\n');
  }

  Map<String, dynamic> _asMap(Object? value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  List<String> _resolvePluginNames(Object? pluginSet) {
    final configured = pluginSet is List
        ? pluginSet.map((entry) => entry.toString()).toList()
        : const <String>['*'];
    if (!configured.contains('*')) return configured;

    final pluginDir =
        Directory('${scripts.ubuntuPath}/root/AstrBot/data/plugins');
    if (!pluginDir.existsSync()) return const [];
    try {
      final names = pluginDir
          .listSync()
          .whereType<Directory>()
          .map((directory) => directory.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last)
          .where((name) => !name.startsWith('.'))
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    } on FileSystemException {
      return const ['（插件目录不可读取）'];
    }
  }

  Future<void> _testModels(DiagnosticItem item) async {
    final configs = await _readConfigs();
    await _loadConfigRoutingInfo();
    final context = await _loadBotContext();
    final activeIds = _activeConfigIds(context);
    final relevantConfigs =
        configs.where((config) => activeIds.contains(config.id)).toList();
    final defaultConfig =
        configs.where((config) => config.id == 'default').first;
    final dashboard = defaultConfig.data['dashboard'];
    if (dashboard is! Map) {
      item
        ..status = DiagnosticStatus.failed
        ..detail = 'AstrBot 登录配置缺失';
      return;
    }
    final username = dashboard['username']?.toString() ?? '';
    final secret = dashboard['jwt_secret']?.toString() ?? '';
    if (username.isEmpty || secret.isEmpty) {
      item
        ..status = DiagnosticStatus.failed
        ..detail = 'AstrBot 登录配置不完整';
      return;
    }

    final jwt = _createJwt(username, secret);
    final results = <String>[];
    var hasFailure = relevantConfigs.isEmpty;
    var tested = 0;
    final missingIds =
        activeIds.difference(configs.map((config) => config.id).toSet());
    for (final id in missingIds) {
      results.add('${_configDisplayName(id)}：配置文件不存在');
      hasFailure = true;
    }
    if (relevantConfigs.isEmpty && missingIds.isEmpty) {
      results.add('没有已运行账号可映射到配置文件');
    }
    for (final config in relevantConfigs) {
      if (_cancelled) return;
      final configName = _configDisplayName(config.id);
      final settings = config.data['provider_settings'];
      final providerId = settings is Map
          ? settings['default_provider_id']?.toString() ?? ''
          : '';
      if (providerId.isEmpty) {
        hasFailure = true;
        results.add('$configName：未配置默认模型');
        continue;
      }
      tested++;
      try {
        final response = await http.get(
          Uri.parse(
                  '${ServicePorts.dashboardUrl}/api/config/provider/check_one')
              .replace(queryParameters: {'id': providerId}),
          headers: {'Authorization': 'Bearer $jwt'},
        ).timeout(const Duration(seconds: 120));
        if (response.statusCode == 404) {
          results.add('$configName：当前 AstrBot 版本不支持自动测试');
          continue;
        }
        final body = jsonDecode(response.body);
        final data = body is Map ? body['data'] : null;
        final available = data is Map && data['status'] == 'available';
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            available) {
          results.add('$configName：$providerId 连接正常');
        } else {
          hasFailure = true;
          final error = data is Map ? data['error'] : null;
          results.add(
              '$configName：$providerId 连接失败${error == null ? '' : '，${_safeError(error)}'}');
        }
      } on TimeoutException {
        hasFailure = true;
        results.add('$configName：$providerId 测试超过 120 秒');
      }
    }

    item
      ..status = hasFailure
          ? DiagnosticStatus.failed
          : tested == 0
              ? DiagnosticStatus.warning
              : DiagnosticStatus.passed
      ..detail = results.join('\n');
  }

  String _createJwt(String username, String secret) {
    final header = _base64UrlJson({'alg': 'HS256', 'typ': 'JWT'});
    final payload = _base64UrlJson({
      'username': username,
      'exp': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 10))
              .millisecondsSinceEpoch ~/
          1000,
    });
    final unsigned = '$header.$payload';
    final signature =
        Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(unsigned));
    return '$unsigned.${base64Url.encode(signature.bytes).replaceAll('=', '')}';
  }

  String _base64UrlJson(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  List<Map<String, dynamic>> _findProviders(Map<String, dynamic> raw) {
    final value = raw['provider'] ?? raw['providers'];
    if (value is List) {
      return value
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    return const [];
  }

  String _displayValue(Object? value) {
    if (value is List) return value.isEmpty ? '未配置' : value.join('、');
    final text = value?.toString() ?? '';
    return text.isEmpty ? '未配置' : text;
  }

  String _displayWakePrefixes(Object? value) {
    if (value is List) {
      return '[${value.map((entry) => '"${entry.toString().replaceAll('"', '\\"')}"').join('、')}]';
    }
    return _displayValue(value);
  }

  String _displaySwitch(Object? value) => switch (value) {
        true => '开',
        false => '关',
        _ => '未配置',
      };

  String _safeError(Object error) {
    var text = error.toString();
    text = text.replaceAll(
      RegExp(r'(api[_ -]?key|token|password|secret)[^,;\s]*',
          caseSensitive: false),
      '[敏感信息已隐藏]',
    );
    text = text.replaceAll(RegExp(r'https?://[^\s]+'), '[地址已隐藏]');
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}
