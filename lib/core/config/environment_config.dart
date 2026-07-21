import 'package:settings/settings.dart';

class EnvironmentConfig {
  static const String autoProxy = 'auto';
  static const String directProxy = 'direct';

  static const List<Map<String, String>> githubProxyOptions = [
    {'name': '自动选择', 'value': autoProxy},
    {'name': '直连 (GitHub 原始)', 'value': directProxy},
    {'name': 'Ghfast', 'value': 'https://ghfast.top'},
    {'name': 'Gh-Proxy', 'value': 'https://gh-proxy.com'},
    {'name': 'GhProxyNet', 'value': 'https://ghproxy.net'},
    {'name': 'GhProxyCc', 'value': 'https://ghproxy.cc'},
    {'name': 'Dpik', 'value': 'https://gh.dpik.top'},
    {'name': 'Monlor', 'value': 'https://gh.monlor.com'},
    {'name': 'Chjina', 'value': 'https://gh.chjina.com'},
    {'name': 'BokiMoe', 'value': 'https://github.boki.moe'},
    {'name': 'JasonZeng', 'value': 'https://gh.jasonzeng.dev'},
    {'name': 'GeekerTao', 'value': 'https://gh.geekertao.top'},
    {'name': 'Nxnow', 'value': 'https://gh.nxnow.top'},
    {'name': 'Npee', 'value': 'https://down.npee.cn'},
  ];

  static SettingNode get _githubProxy => 'environment_github_proxy'.setting;
  static SettingNode get _githubProxyAutoResolved =>
      'environment_github_proxy_auto_resolved'.setting;

  static String get githubProxy {
    final value = _githubProxy.get()?.toString() ?? autoProxy;
    if (value.trim().isEmpty) return autoProxy;
    return value;
  }

  static void setGithubProxy(String value) {
    _githubProxy.set(value);
  }

  static String get githubProxyAutoResolved {
    final value = _githubProxyAutoResolved.get()?.toString() ?? directProxy;
    if (value.trim().isEmpty || value == autoProxy) return directProxy;
    return value;
  }

  static void setGithubProxyAutoResolved(String value) {
    if (value != autoProxy) _githubProxyAutoResolved.set(value);
  }

  static String get effectiveGithubProxy =>
      githubProxy == autoProxy ? githubProxyAutoResolved : githubProxy;

  static String labelForProxy(String value) {
    for (final option in githubProxyOptions) {
      if (option['value'] == value) return option['name'] ?? value;
    }
    return value;
  }
}
