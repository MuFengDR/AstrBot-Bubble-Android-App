import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:xterm/xterm.dart';

import '../../controllers/terminal_controller.dart';
import 'terminal_theme.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final HomeController controller = Get.put(HomeController());
  final ManjaroTerminalTheme terminalTheme = ManjaroTerminalTheme();
  bool visible = kDebugMode;

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

  Future<void> _copyLogs(BuildContext context) async {
    final text = controller.startupLogText.trim();
    if (text.isEmpty) {
      _showTopSnack(context, '暂无日志可复制');
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    _showTopSnack(context, '日志已复制');
  }

  @override
  void dispose() {
    try {
      if (controller.pseudoTerminal != null) {
        Log.i('TerminalPage dispose: close main terminal', tag: 'AstrBot');
        controller.pseudoTerminal?.kill();
      }
      if (controller.napcatTerminal != null) {
        Log.i('TerminalPage dispose: close NapCat terminal',
            tag: 'AstrBot-Napcat');
        controller.napcatTerminal?.kill();
      }
    } catch (e) {
      Log.e('TerminalPage dispose error: $e', tag: 'AstrBot');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: visible
          ? terminalTheme.background
          : Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: EdgeInsets.all(8.w),
              child: Visibility(
                visible: visible,
                child: AbsorbPointer(
                  absorbing: false,
                  child: TerminalView(
                    controller.terminal,
                    readOnly: false,
                    backgroundOpacity: 1,
                    theme: ManjaroTerminalTheme(),
                  ),
                ),
              ),
            ),
            GetBuilder<HomeController>(
              builder: (controller) {
                if (!controller.showStartupProgress) {
                  return Positioned(
                    top: 8.w,
                    right: 8.w,
                    child: Material(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(6.w),
                      child: IconButton(
                        tooltip: '复制日志',
                        onPressed: () => _copyLogs(context),
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                    ),
                  );
                }

                return Center(
                  child: Material(
                    borderRadius: BorderRadius.circular(12.w),
                    color: Theme.of(context).colorScheme.surface,
                    child: SizedBox(
                      width: 300.w,
                      child: Padding(
                        padding: EdgeInsets.all(12.w),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Center(
                              child: RepaintBoundary(
                                child: LoadingProgress(
                                  minRadius: 6,
                                  strokeWidth: 3,
                                  increaseRadius: 3,
                                ),
                              ),
                            ),
                            SizedBox(height: 12.w),
                            Stack(
                              children: [
                                Container(
                                  height: 5.w,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .opacity02,
                                    borderRadius: BorderRadius.circular(3.w),
                                  ),
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  height: 5.w,
                                  width: 300.w * controller.progress,
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(3.w),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 8.w),
                            Text(
                              controller.currentProgress.trim(),
                              style: TextStyle(
                                fontSize: 12.w,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(height: 8.w),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8.w,
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    visible = true;
                                    controller.revealStartupLog();
                                    setState(() {});
                                  },
                                  icon: const Icon(Icons.terminal, size: 16),
                                  label: const Text('查看日志'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _copyLogs(context),
                                  icon: const Icon(Icons.copy, size: 16),
                                  label: const Text('复制日志'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
