import 'dart:convert';

import 'package:settings/settings.dart';

class UiPreferences {
  static SettingNode get _homeBackgroundPath => 'home_background_path'.setting;
  static SettingNode get _cardGlassOpacity => 'card_glass_opacity'.setting;
  static SettingNode get _glassBlurAmount => 'glass_blur_amount'.setting;
  static SettingNode get _topNavGlassOpacity => 'top_nav_glass_opacity'.setting;
  static SettingNode get _statusOverlayOpacity =>
      'status_overlay_opacity'.setting;
  static SettingNode get _terminalOverlayOpacity =>
      'terminal_overlay_opacity'.setting;
  static SettingNode get _homeFontScale => 'home_font_scale'.setting;
  static SettingNode get _terminalFontSize => 'terminal_font_size'.setting;
  static SettingNode get _showTerminalShortcutBar =>
      'show_terminal_shortcut_bar'.setting;
  static SettingNode get _webUiZoomLevels => 'web_ui_zoom_levels'.setting;

  static String get homeBackgroundPath =>
      _homeBackgroundPath.get()?.toString() ?? '';
  static double get cardGlassOpacity => _readOpacity(_cardGlassOpacity, 0.62);
  static double get glassBlurAmount => _readPercent(_glassBlurAmount, 0.45);
  static double get topNavGlassOpacity =>
      _readOpacity(_topNavGlassOpacity, 0.62);
  static double get statusOverlayOpacity =>
      _readOpacity(_statusOverlayOpacity, 0.38);
  static double get terminalOverlayOpacity =>
      _readOpacity(_terminalOverlayOpacity, 0.55);
  static double get homeFontScale => _readHomeFontScale(_homeFontScale, 1.0);
  static double get terminalFontSize =>
      _readDouble(_terminalFontSize, 13.0).clamp(10.0, 22.0).toDouble();
  static bool get showTerminalShortcutBar =>
      _readBool(_showTerminalShortcutBar, true);
  static Map<String, int> get webUiZoomLevels {
    final value = _webUiZoomLevels.get();
    if (value == null) return {};

    try {
      final decoded = value is String ? jsonDecode(value) : value;
      if (decoded is! Map) return {};

      final zoomLevels = <String, int>{};
      for (final entry in decoded.entries) {
        final zoom = entry.value is num
            ? (entry.value as num).toInt()
            : int.tryParse(entry.value.toString());
        if (zoom != null) {
          zoomLevels[entry.key.toString()] = zoom.clamp(50, 150).toInt();
        }
      }
      return zoomLevels;
    } catch (_) {
      return {};
    }
  }

  static void saveHomeBackgroundPath(String path) {
    _homeBackgroundPath.set(path);
  }

  static void clearHomeBackgroundPath() {
    _homeBackgroundPath.set('');
  }

  static void saveCardGlassOpacity(double value) {
    _cardGlassOpacity.set(_normalizeOpacity(value));
  }

  static void saveGlassBlurAmount(double value) {
    _glassBlurAmount.set(_normalizePercent(value));
  }

  static void saveTopNavGlassOpacity(double value) {
    _topNavGlassOpacity.set(_normalizeOpacity(value));
  }

  static void saveStatusOverlayOpacity(double value) {
    _statusOverlayOpacity.set(_normalizeOpacity(value));
  }

  static void saveTerminalOverlayOpacity(double value) {
    _terminalOverlayOpacity.set(_normalizeOpacity(value));
  }

  static void saveHomeFontScale(double value) {
    _homeFontScale.set(_normalizeHomeFontScale(value));
  }

  static void saveTerminalFontSize(double value) {
    _terminalFontSize.set(value.clamp(10.0, 22.0).toDouble());
  }

  static void saveShowTerminalShortcutBar(bool value) {
    _showTerminalShortcutBar.set(value);
  }

  static void saveWebUiZoomLevels(Map<String, int> value) {
    final normalized = value.map(
      (key, zoom) => MapEntry(key, zoom.clamp(50, 150).toInt()),
    );
    _webUiZoomLevels.set(jsonEncode(normalized));
  }

  static double _readOpacity(SettingNode node, double fallback) {
    final value = node.get();
    final opacity = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (opacity == null) return fallback;
    return _normalizeOpacity(opacity);
  }

  static double _readPercent(SettingNode node, double fallback) {
    final value = node.get();
    final percent = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (percent == null) return fallback;
    return _normalizePercent(percent);
  }

  static double _readDouble(SettingNode node, double fallback) {
    final value = node.get();
    return value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static bool _readBool(SettingNode node, bool fallback) {
    final value = node.get();
    if (value is bool) return value;
    if (value?.toString().toLowerCase() == 'true') return true;
    if (value?.toString().toLowerCase() == 'false') return false;
    return fallback;
  }

  static double _normalizeOpacity(double value) {
    return value.clamp(0.0, 0.95).toDouble();
  }

  static double _normalizePercent(double value) {
    return value.clamp(0.0, 1.0).toDouble();
  }

  static double _readHomeFontScale(SettingNode node, double fallback) {
    final value = node.get();
    final scale = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (scale == null) return fallback;
    return _normalizeHomeFontScale(scale);
  }

  static double _normalizeHomeFontScale(double value) {
    return value.clamp(0.25, 1.25).toDouble();
  }
}
