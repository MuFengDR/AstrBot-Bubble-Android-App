import 'package:settings/settings.dart';

class EnvironmentConfig {
  static const String autoProxy = 'auto';
  static const String directProxy = 'direct';

  static const List<Map<String, String>> githubProxyOptions = [
    {'name': '自动测试', 'value': autoProxy},
    {'name': '直连 GitHub', 'value': directProxy},
    {'name': 'Ghfast', 'value': 'https://ghfast.top'},
    {'name': 'Wuliya', 'value': 'https://gh.wuliya.xin'},
    {'name': 'GH Proxy', 'value': 'https://gh-proxy.com'},
    {'name': 'Moeyy', 'value': 'https://github.moeyy.xyz'},
  ];

  static SettingNode get _githubProxy => 'environment_github_proxy'.setting;

  static String get githubProxy {
    final value = _githubProxy.get()?.toString() ?? autoProxy;
    if (value.trim().isEmpty) return autoProxy;
    return value;
  }

  static void setGithubProxy(String value) {
    _githubProxy.set(value);
  }

  static String labelForProxy(String value) {
    for (final option in githubProxyOptions) {
      if (option['value'] == value) return option['name'] ?? value;
    }
    return value;
  }
}
