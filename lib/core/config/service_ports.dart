import 'package:settings/settings.dart';

class ServicePorts {
  static const int defaultDashboardPort = 6185;
  static const int defaultOneBotWsPort = 6199;
  static const int defaultNapCatWebUiPort = 6099;

  static SettingNode get _dashboardPort => 'astrbot_dashboard_port'.setting;
  static SettingNode get _oneBotWsPort => 'astrbot_onebot_ws_port'.setting;
  static SettingNode get _napCatWebUiPort => 'napcat_webui_port'.setting;

  static int get dashboardPort =>
      _readPort(_dashboardPort, defaultDashboardPort);
  static int get oneBotWsPort => _readPort(_oneBotWsPort, defaultOneBotWsPort);
  static int get napCatWebUiPort =>
      _readPort(_napCatWebUiPort, defaultNapCatWebUiPort);

  static String get dashboardUrl => 'http://127.0.0.1:$dashboardPort';
  static String get napCatWebUiUrl => 'http://127.0.0.1:$napCatWebUiPort/webui';
  static String get oneBotWsUrl => 'ws://localhost:$oneBotWsPort/ws';
  static int get napCatXDisplay {
    if (dashboardPort == defaultDashboardPort &&
        oneBotWsPort == defaultOneBotWsPort &&
        napCatWebUiPort == defaultNapCatWebUiPort) {
      return 1;
    }
    return 10 + dashboardPort % 80;
  }

  static void saveDashboardPort(int port) {
    _dashboardPort.set(port);
  }

  static bool isValidPort(int port) => port >= 1024 && port <= 65535;

  static int _readPort(SettingNode node, int fallback) {
    final value = node.get();
    final port = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (port == null || !isValidPort(port)) {
      return fallback;
    }
    return port;
  }
}
