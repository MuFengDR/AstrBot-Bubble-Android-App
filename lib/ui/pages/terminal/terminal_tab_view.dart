import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
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
  final HomeController homeController = Get.find<HomeController>();

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

  Future<void> _copyActiveTerminalLog(
    BuildContext context,
    TerminalTabManager manager,
  ) async {
    final tab = manager.activeTab;
    final text = tab?.type == TerminalTabType.fixed
        ? homeController.startupLogText.trim()
        : (tab?.logText.trim() ?? '');

    if (text.isEmpty) {
      _showTopSnack(context, '暂无日志可复制');
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    _showTopSnack(context, '日志已复制');
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(24),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        opacity: homeController.topNavGlassOpacity.value,
        blur: homeController.glassBlurAmount.value * 30,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: tabs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
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
                icon: const Icon(Icons.copy),
                onPressed: () => _copyActiveTerminalLog(context, manager),
                tooltip: '复制当前终端日志',
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => manager.addSystemTerminalTab(),
                tooltip: '添加新终端',
              ),
            ],
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 112,
          maxWidth: 190,
        ),
        child: InputChip(
          selected: isActive,
          showCheckmark: false,
          label: Text(
            tab.title,
            overflow: TextOverflow.ellipsis,
          ),
          avatar: Icon(icon, size: 18),
          deleteIcon:
              onClose == null ? null : const Icon(Icons.close, size: 18),
          onDeleted: onClose,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }

  Widget _buildTerminalContent(TerminalTab tab) {
    return ClipRect(
      child: TerminalView(
        tab.terminal,
        readOnly: tab.type == TerminalTabType.fixed,
        backgroundOpacity: 1,
        theme: ManjaroTerminalTheme(),
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
