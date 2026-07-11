import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:xterm/xterm.dart';

import '../../controllers/terminal_controller.dart';
import '../../controllers/terminal_tab_manager.dart';
import '../../widgets/glass_panel.dart';
import 'terminal_theme.dart';

class TerminalTabView extends StatefulWidget {
  const TerminalTabView({super.key});

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  static const double _defaultFontSize = 13;
  static const double _minFontSize = 10;
  static const double _maxFontSize = 22;

  final HomeController homeController = Get.find<HomeController>();
  double _terminalFontSize = _defaultFontSize;

  void _showTopSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).size.height - 170,
        ),
      ),
    );
  }

  String? _selectedText(TerminalTab tab) {
    final selection = tab.controller.selection;
    if (selection == null) return null;
    final text = tab.terminal.buffer.getText(selection);
    return text.trim().isEmpty ? null : text;
  }

  String _fullLogText(TerminalTab tab) {
    return tab.type == TerminalTabType.fixed
        ? homeController.startupLogText.trim()
        : tab.logText.trim();
  }

  Future<void> _copySelected(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    if (tab == null) {
      _showTopSnack(context, '暂无选中内容');
      return;
    }

    final text = _selectedText(tab);
    if (text == null) {
      _showTopSnack(context, '暂无选中内容');
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    _showTopSnack(context, '已复制选中内容');
  }

  Future<void> _copyAll(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    if (tab == null) {
      _showTopSnack(context, '暂无内容可复制');
      return;
    }

    final text = _fullLogText(tab);
    if (text.isEmpty) {
      _showTopSnack(context, '暂无内容可复制');
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    _showTopSnack(context, '日志已复制');
  }

  Future<void> _clearActiveTerminal(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    if (tab == null) {
      _showTopSnack(context, '暂无终端可清空');
      return;
    }

    tab.controller.clearSelection();
    tab.terminal.eraseDisplay();
    tab.terminal.eraseScrollbackOnly();
    tab.clearLog();
    if (tab.type == TerminalTabType.fixed) {
      homeController.clearStartupLog();
    }
    _showTopSnack(context, '终端已清空');
  }

  Future<void> _exportActiveLog(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    if (tab == null) {
      _showTopSnack(context, '暂无日志可导出');
      return;
    }

    final text = _fullLogText(tab);
    if (text.isEmpty) {
      _showTopSnack(context, '暂无日志可导出');
      return;
    }

    try {
      final granted = await _ensureStoragePermission(context);
      if (!granted) return;

      final dir = Directory('/storage/emulated/0/Download/AstrBotBubble');
      await dir.create(recursive: true);
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file = File('${dir.path}/terminal-log-$timestamp.txt');
      await file.writeAsString(text);
      if (!context.mounted) return;
      _showTopSnack(context, '已导出: ${file.path}');
    } catch (e) {
      if (!context.mounted) return;
      _showTopSnack(context, '导出失败: $e');
    }
  }

  Future<bool> _ensureStoragePermission(BuildContext context) async {
    var status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;

    status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    var storageStatus = await Permission.storage.status;
    if (!storageStatus.isGranted) {
      storageStatus = await Permission.storage.request();
    }
    if (storageStatus.isGranted) return true;

    if (!context.mounted) return false;
    _showTopSnack(context, '需要存储权限才能导出 log');
    return false;
  }

  Future<void> _showTerminalMenu(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final hasSelection = tab == null ? false : _selectedText(tab) != null;
            return SafeArea(
              child: MediaQuery.withNoTextScaling(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.content_copy),
                        title: const Text('复制选中'),
                        enabled: hasSelection,
                        onTap: hasSelection
                            ? () {
                                Navigator.of(context).pop();
                                _copySelected(context, manager);
                              }
                            : null,
                      ),
                      ListTile(
                        leading: const Icon(Icons.copy_all),
                        title: const Text('复制全部'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _copyAll(context, manager);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.cleaning_services_outlined),
                        title: const Text('清空'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _clearActiveTerminal(context, manager);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('新建终端'),
                        onTap: () {
                          Navigator.of(context).pop();
                          manager.addSystemTerminalTab();
                        },
                      ),
                      const Divider(height: 20),
                      _buildFontSizeMenuItem(
                        onChanged: () => setSheetState(() {}),
                      ),
                      _buildLogLimitMenuItem(
                        onChanged: () => setSheetState(() {}),
                      ),
                      const Divider(height: 20),
                      ListTile(
                        leading: const Icon(Icons.ios_share),
                        title: const Text('导出 log'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _exportActiveLog(context, manager);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLogLimitMenuItem({required VoidCallback onChanged}) {
    final percent = TerminalLogLimits.percent.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.storage_outlined),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              '日志上限',
              style: TextStyle(fontSize: 16),
            ),
          ),
          IconButton(
            tooltip: '减少',
            onPressed: percent <= TerminalLogLimits.minPercent
                ? null
                : () {
                    homeController.setTerminalLogLimitPercent(
                      percent - TerminalLogLimits.stepPercent,
                    );
                    onChanged();
                  },
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 58,
            child: Text(
              '$percent%',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '增加',
            onPressed: percent >= TerminalLogLimits.maxPercent
                ? null
                : () {
                    homeController.setTerminalLogLimitPercent(
                      percent + TerminalLogLimits.stepPercent,
                    );
                    onChanged();
                  },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget _buildFontSizeMenuItem({required VoidCallback onChanged}) {
    final fontSize = _terminalFontSize.round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.format_size),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              '调整字体大小',
              style: TextStyle(fontSize: 16),
            ),
          ),
          IconButton(
            tooltip: '小',
            onPressed: _terminalFontSize <= _minFontSize
                ? null
                : () {
                    setState(() {
                      _terminalFontSize -= 1;
                    });
                    onChanged();
                  },
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$fontSize',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '大',
            onPressed: _terminalFontSize >= _maxFontSize
                ? null
                : () {
                    setState(() {
                      _terminalFontSize += 1;
                    });
                    onChanged();
                  },
            icon: const Icon(Icons.add),
          ),
          TextButton(
            onPressed: _terminalFontSize == _defaultFontSize
                ? null
                : () {
                    setState(() {
                      _terminalFontSize = _defaultFontSize;
                    });
                    onChanged();
                  },
            child: const Text('默认'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final manager = homeController.terminalTabManager;
      final tabs = manager.tabs;
      final activeIndex = manager.activeTabIndex.value;

      if (tabs.isEmpty) {
        return const Center(child: Text('暂无终端'));
      }

      return Column(
        children: [
          _buildTabBar(tabs, activeIndex, manager),
          Expanded(
            child: IndexedStack(
              index: activeIndex,
              children: tabs.map(_buildTerminalContent).toList(),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildTabBar(
    List<TerminalTab> tabs,
    int activeIndex,
    TerminalTabManager manager,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        opacity: homeController.topNavGlassOpacity.value,
        blur: homeController.glassBlurAmount.value * 30,
        child: MediaQuery.withNoTextScaling(
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: tabs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final tab = tabs[index];
                      return _buildTabItem(
                        tab: tab,
                        isActive: index == activeIndex,
                        onTap: () => manager.switchToTab(index),
                        onClose: tab.type == TerminalTabType.system
                            ? () => _showCloseConfirmDialog(index, manager)
                            : null,
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 22),
                  onPressed: () => _showTerminalMenu(context, manager),
                  tooltip: '终端菜单',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabItem({
    required TerminalTab tab,
    required bool isActive,
    required VoidCallback onTap,
    VoidCallback? onClose,
  }) {
    final icon =
        tab.type == TerminalTabType.fixed ? Icons.lock_outline : Icons.terminal;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 104,
          maxWidth: 176,
        ),
        child: InputChip(
          selected: isActive,
          showCheckmark: false,
          label: Text(
            tab.title,
            overflow: TextOverflow.ellipsis,
          ),
          avatar: Icon(icon, size: 16),
          deleteIcon:
              onClose == null ? null : const Icon(Icons.close, size: 16),
          onDeleted: onClose,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }

  Widget _buildTerminalContent(TerminalTab tab) {
    return ClipRect(
      child: Obx(
        () => DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(
              alpha: homeController.terminalOverlayOpacity.value,
            ),
          ),
          child: TerminalView(
            tab.terminal,
            controller: tab.controller,
            readOnly: tab.type == TerminalTabType.fixed,
            backgroundOpacity: 0,
            textStyle: TerminalStyle(fontSize: _terminalFontSize),
            theme: ManjaroTerminalTheme(),
          ),
        ),
      ),
    );
  }

  void _showCloseConfirmDialog(int index, TerminalTabManager manager) {
    Get.dialog(
      AlertDialog(
        title: const Text('确认关闭'),
        content: const Text('确定要关闭这个终端吗？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              manager.closeTab(index);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
