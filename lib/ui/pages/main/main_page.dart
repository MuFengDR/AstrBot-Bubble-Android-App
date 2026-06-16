import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/terminal_controller.dart';
import '../launcher/launcher_page.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../webview/webview_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final HomeController homeController = Get.put(HomeController());
  Worker? _mainTabWorker;
  int _currentIndex = 0;
  bool _showSettings = false;

  @override
  void initState() {
    super.initState();
    _mainTabWorker = ever<int?>(homeController.pendingMainTabIndex, (index) {
      if (index == null || index < 0 || index > 2) return;
      _openTab(index);
      homeController.clearPendingMainTabIndex(index);
    });
  }

  @override
  void dispose() {
    _mainTabWorker?.dispose();
    super.dispose();
  }

  void _openTab(int index) {
    setState(() {
      _showSettings = false;
      _currentIndex = index;
    });
  }

  void _openSettings() {
    setState(() {
      _showSettings = true;
    });
  }

  void _closeSettings() {
    setState(() {
      _showSettings = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSettings) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _closeSettings,
          ),
          title: const Text('设置'),
        ),
        body: SafeArea(
          child: SettingsPage(
            astrBotController: WebViewPage.astrBotController,
            napCatController: WebViewPage.napCatController,
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            LauncherPage(
              onNavigate: _openTab,
              onOpenSettings: _openSettings,
            ),
            WebViewPage(embedded: true),
            const TerminalTabView(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _openTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy),
            label: '主页',
          ),
          NavigationDestination(
            icon: Icon(Icons.language_outlined),
            selectedIcon: Icon(Icons.language),
            label: 'WebUI',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: '终端',
          ),
        ],
      ),
    );
  }
}
