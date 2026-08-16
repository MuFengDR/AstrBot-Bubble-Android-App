import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/environment_config.dart';
import '../../../core/config/service_ports.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../controllers/terminal_controller.dart';
import '../../widgets/glass_panel.dart';

class LauncherPage extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  final VoidCallback? onOpenSettings;

  const LauncherPage({super.key, this.onNavigate, this.onOpenSettings});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage>
    with WidgetsBindingObserver {
  static final Uri _installerRepositoryUri =
      Uri.parse(
        'https://github.com/MuFengDR/AstrBot-Android-Scripts/releases/latest',
      );
  final HomeController homeController = Get.find<HomeController>();
  final Map<String, _EnvStepState> _environmentStates = {};
  final Map<String, _NapCatAccountOperation> _napCatBusyOperations = {};
  final Map<String, BotBindingConfigState> _botBindingStates = {};
  final Set<String> _botBindingStateLoading = {};
  final Map<String, int> _botBindingRefreshVersions = {};
  final Set<String> _runningNapCatIds = {};
  Worker? _napCatInstancesWorker;
  bool _checkingEnvironment = false;
  bool _initialEnvironmentCheckComplete = false;
  Object? _initialEnvironmentError;
  bool _environmentExpanded = false;
  _InstallerScriptState _installerScriptState =
      _InstallerScriptState.notDownloaded;
  String? _installerScriptVersion;

  Future<void> _showGithubProxyDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _GithubProxyDialog(),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openInstallerRepository() async {
    try {
      final opened = await launchUrl(
        _installerRepositoryUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) _showSnack('无法打开脚本仓库');
    } catch (_) {
      if (mounted) _showSnack('无法打开脚本仓库');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runningNapCatIds.addAll(_currentRunningNapCatIds());
    _napCatInstancesWorker = ever(
      homeController.napCatInstances,
      _handleNapCatInstancesChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshEnvironmentStatus();
      _refreshAllBotBindingStates();
      homeController.refreshInitialPasswordAssistanceState();
    });
  }

  @override
  void dispose() {
    _napCatInstancesWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshEnvironmentStatus();
      _refreshAllBotBindingStates();
    }
  }

  Future<void> _startAstrBot() async {
    try {
      await homeController.loadAstrBot();
      _showSnack('AstrBot 启动任务已进入 main 终端');
      widget.onNavigate?.call(2);
    } catch (e) {
      _showSnack('启动失败：$e');
    }
  }

  Future<void> _stopAstrBot() async {
    try {
      await homeController.stopAstrBot();
      _showSnack('AstrBot 已停止');
    } catch (e) {
      _showSnack('停止失败：$e');
    }
  }

  Future<void> _copyAstrBotInitialPassword() async {
    final copied = await homeController.copyAstrBotInitialPassword();
    _showSnack(copied ? '密码已复制' : '未检测到密码');
  }

  Future<void> _resetAstrBotDashboardPassword() async {
    if (!homeController.isAstrBotInstalled) {
      _showSnack('AstrBot 环境未安装完整');
      return;
    }

    final running = homeController.isAstrBotRunning.value ||
        homeController.isAstrBotStarting.value;
    if (running) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重置面板密码'),
          content: const Text(
            '重置密码前需要停止 AstrBot。确认后将停止服务，并打开官方密码修改终端。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('停止并继续'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await homeController.stopAstrBot();
    }

    try {
      await homeController.openAstrBotPasswordResetTerminal();
      widget.onNavigate?.call(2);
      _showSnack('请在终端中输入两次新密码');
    } catch (e) {
      _showSnack('打开密码重置终端失败：$e');
    }
  }

  Future<void> _handleAstrBotMenu(String action) async {
    switch (action) {
      case 'copy_initial_password':
        await _copyAstrBotInitialPassword();
      case 'reset_dashboard_password':
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        await _resetAstrBotDashboardPassword();
      case 'change_dashboard_port':
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        await _showAstrBotPortDialog();
    }
  }

  Future<void> _runStep(_EnvStep step, _EnvStepState currentState) async {
    if (!currentState.enabled) {
      _showSnack(
        _installerScriptState == _InstallerScriptState.valid
            ? '请先安装上方依赖项'
            : '请先下载或更新脚本',
      );
      return;
    }

    final reinstall = currentState.installed;
    var reinstallLinuxqq = false;
    if (reinstall) {
      final bool? confirmed;
      if (step.id == 'napcat') {
        confirmed = await _showNapCatReinstallDialog();
        reinstallLinuxqq = confirmed == true;
      } else {
        confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('重装 ${step.title}'),
            content: Text(step.reinstallMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认重装'),
              ),
            ],
          ),
        );
      }
      if (step.id == 'napcat') {
        if (confirmed == null) return;
      } else if (confirmed != true) {
        return;
      }
    }

    try {
      await homeController.runEnvironmentStep(
        step: step.id,
        title: step.title,
        reinstall: reinstall,
        reinstallLinuxqq: reinstallLinuxqq,
        onCommandDone: () {
          if (mounted) {
            _refreshEnvironmentStatus();
          }
        },
      );
      _showSnack('${step.title} 已在终端运行');
      widget.onNavigate?.call(2);
    } catch (e) {
      _showSnack('启动失败：$e');
    }
  }

  Future<bool?> _showNapCatReinstallDialog() {
    var reinstallLinuxqq = false;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('重装 NapCat'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('将清理 NapCat 安装文件并重新安装，尽量保留配置目录。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: reinstallLinuxqq,
                onChanged: (value) => setDialogState(
                  () => reinstallLinuxqq = value == true,
                ),
                title: const Text('同时重装 QQ'),
                subtitle: const Text('未安装 QQ 时，即使不勾选也会自动安装'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(reinstallLinuxqq),
              child: const Text('确认重装'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkThenOfferInstallerUpdate() async {
    final isFirstDownload =
        _installerScriptState == _InstallerScriptState.notDownloaded;
    InstallerUpdateCheckResult? result;
    StateSetter? updateDialog;
    VoidCallback? cancelCheck;
    Timer? checkTimeout;
    var dialogOpen = true;
    var started = false;
    var checkGeneration = 0;

    Future<void> runCheck() async {
      final generation = ++checkGeneration;
      checkTimeout?.cancel();
      checkTimeout = Timer(const Duration(seconds: 60), () {
        if (!mounted || !dialogOpen || generation != checkGeneration) return;
        checkGeneration++;
        cancelCheck?.call();
        updateDialog?.call(
          () => result = InstallerUpdateCheckResult.timedOut,
        );
      });
      try {
        await homeController.checkInstallerUpdate(
          onCancelReady: (cancel) {
            if (generation != checkGeneration) {
              cancel();
            } else {
              cancelCheck = cancel;
            }
          },
          onResult: (value) {
            if (generation != checkGeneration ||
                !mounted ||
                !dialogOpen ||
                updateDialog == null) {
              return;
            }
            checkTimeout?.cancel();
            updateDialog!(() => result = value);
          },
        );
      } catch (_) {
        if (generation != checkGeneration ||
            !mounted ||
            !dialogOpen ||
            updateDialog == null) {
          return;
        }
        checkTimeout?.cancel();
        updateDialog!(() => result = InstallerUpdateCheckResult.failed);
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          updateDialog = setDialogState;
          if (!started) {
            started = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => runCheck());
          }

          final checking = result == null;
          final icon = switch (result) {
            InstallerUpdateCheckResult.failed => Icons.error_outline,
            InstallerUpdateCheckResult.timedOut => Icons.timer_off_outlined,
            InstallerUpdateCheckResult.updateAvailable =>
              Icons.system_update_alt,
            InstallerUpdateCheckResult.upToDate => Icons.check_circle_outline,
            null => null,
          };
          final message = switch (result) {
            InstallerUpdateCheckResult.failed =>
              '检查失败。关闭此提示后可到终端查看检查日志，或前往脚本仓库下载离线包后手动导入。',
            InstallerUpdateCheckResult.timedOut =>
              '检查超过 60 秒，已停止。关闭此提示后可到终端查看检查日志，或前往脚本仓库下载离线包后手动导入。',
            InstallerUpdateCheckResult.updateAvailable =>
              isFirstDownload
                  ? '已找到可用安装脚本，是否立即下载？'
                  : '发现新版安装脚本，是否立即更新？',
            InstallerUpdateCheckResult.upToDate => '当前已是最新安装脚本。',
            null => '正在检查安装脚本更新，请稍候…',
          };

          return AlertDialog(
            title: const Text('安装脚本更新'),
            content: Row(
              children: [
                if (checking)
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Icon(icon),
                const SizedBox(width: 16),
                Expanded(child: Text(message)),
              ],
            ),
            actions: [
              if (checking)
                TextButton(
                  onPressed: () {
                    checkGeneration++;
                    checkTimeout?.cancel();
                    dialogOpen = false;
                    cancelCheck?.call();
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('取消'),
                ),
              if (!checking)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              if (result == InstallerUpdateCheckResult.failed ||
                  result == InstallerUpdateCheckResult.timedOut)
                TextButton.icon(
                  onPressed: _openInstallerRepository,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('打开脚本仓库'),
                ),
              if (result == InstallerUpdateCheckResult.failed ||
                  result == InstallerUpdateCheckResult.timedOut)
                FilledButton.tonal(
                  onPressed: () {
                    cancelCheck = null;
                    setDialogState(() => result = null);
                    runCheck();
                  },
                  child: const Text('重试'),
                ),
              if (result == InstallerUpdateCheckResult.updateAvailable)
                FilledButton(
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    await homeController.updateInstaller(
                      onCommandDone: _refreshEnvironmentStatus,
                    );
                    _showSnack('正在终端更新安装脚本');
                    widget.onNavigate?.call(2);
                  },
                  child: Text(isFirstDownload ? '立即下载' : '立即更新'),
                ),
            ],
          );
        },
      ),
    );
    checkGeneration++;
    checkTimeout?.cancel();
    dialogOpen = false;
  }

  Future<void> _importInstallerPackage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gz', 'tgz'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null || bytes.isEmpty) return;

    await homeController.importInstallerPackage(
      bytes,
      onCommandDone: _refreshEnvironmentStatus,
    );
    _showSnack('正在终端导入离线安装脚本包');
    if (mounted) widget.onNavigate?.call(2);
  }

  void _openSettings() {
    widget.onOpenSettings?.call();
  }

  Future<void> _showAstrBotPortDialog() async {
    final controller =
        TextEditingController(text: ServicePorts.dashboardPort.toString());
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AstrBot 监听端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '端口',
            hintText: '6185',
            helperText: '范围 1024-65535，保存后重启 AstrBot 生效',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final portText = controller.text.trim();
    // Navigator.pop 的 Future 会早于对话框退场动画完成。延迟释放，避免
    // TextField 仍在卸载依赖时提前销毁 controller。
    await Future<void>.delayed(kThemeAnimationDuration);
    controller.dispose();
    if (!mounted || result != true) return;

    final port = int.tryParse(portText);
    if (port == null || !ServicePorts.isValidPort(port)) {
      _showSnack('端口无效：请输入 1024-65535');
      return;
    }
    if (port == ServicePorts.oneBotWsPort) {
      _showSnack('端口 $port 已被 OneBot WS 使用');
      return;
    }
    final duplicatedNapCat = homeController.napCatInstances.any(
      (instance) =>
          int.tryParse(instance['webUiPort']?.toString() ?? '') == port,
    );
    if (duplicatedNapCat) {
      _showSnack('端口 $port 已被 NapCat 账号使用');
      return;
    }

    ServicePorts.saveDashboardPort(port);
    await homeController.syncAstrBotDashboardPortConfig();
    if (mounted) {
      setState(() {});
    }
    _showSnack('AstrBot 端口已保存，重启 AstrBot 后生效');
  }

  Future<void> _showOpenCodePortDialog() async {
    final controller =
        TextEditingController(text: ServicePorts.openCodePort.toString());
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OpenCode 监听端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'WebUI 端口',
            hintText: '范围 1024-65535，默认 4096',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final portText = controller.text.trim();
    await Future<void>.delayed(kThemeAnimationDuration);
    controller.dispose();
    if (!mounted || result != true) return;

    final port = int.tryParse(portText);
    if (port == null || !ServicePorts.isValidPort(port)) {
      _showSnack('端口无效：请输入 1024-65535');
      return;
    }
    if (port == ServicePorts.dashboardPort ||
        port == ServicePorts.oneBotWsPort ||
        port == ServicePorts.napCatWebUiPort ||
        homeController.napCatInstances.any(
          (instance) => int.tryParse(instance['webUiPort']?.toString() ?? '') == port,
        )) {
      _showSnack('端口 $port 已被其他服务配置使用');
      return;
    }
    if (!await homeController.isPortAvailable(port)) {
      _showSnack('端口 $port 当前已被系统占用');
      return;
    }
    ServicePorts.saveOpenCodePort(port);
    if (mounted) setState(() {});
    _showSnack('OpenCode 端口已保存，重启服务后生效');
  }

  Future<void> _startOpenCode() async {
    if (!await _ensureOpenCodeRuntimeSupported()) return;
    if (homeController.isOpenCodeRunning.value) {
      await homeController.stopOpenCode();
      _showSnack('正在终端停止 OpenCode');
    } else {
      await homeController.startOpenCode(
        onCommandDone: () {
          if (!mounted) return;
          homeController.requestOpenOpenCodeWebUi();
          widget.onNavigate?.call(1);
        },
      );
      _showSnack('正在终端启动 OpenCode Web 服务');
    }
    if (mounted) {
      if (homeController.isOpenCodeRunning.value) {
        widget.onNavigate?.call(1);
      }
      _refreshEnvironmentStatus();
    }
  }

  Future<void> _showOpenCodeUninstallDialog() async {
    if (!await _ensureOpenCodeRuntimeSupported()) return;
    var cleanData = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('卸载 OpenCode'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('项目目录始终保留。请选择是否同时清理 OpenCode 配置和缓存。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: cleanData,
                onChanged: (value) =>
                    setDialogState(() => cleanData = value == true),
                title: const Text('同时清理配置和缓存'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认卸载'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await homeController.uninstallOpenCode(
      cleanData: cleanData,
      onCommandDone: () {
        homeController.isOpenCodeInstalled.value = false;
        _refreshEnvironmentStatus();
      },
    );
    _showSnack('正在终端卸载 OpenCode');
    if (mounted) widget.onNavigate?.call(2);
  }

  Future<bool> _ensureOpenCodeRuntimeSupported() async {
    final runtimeScript = File(
      '${scripts.ubuntuPath}/root/.astrbot-android/installer/current/astrbot-startup.sh',
    );
    try {
      if (await runtimeScript.exists()) {
        final source = await runtimeScript.readAsString();
        if (source.contains('opencode_start)') &&
            source.contains('opencode_stop)') &&
            source.contains('opencode_uninstall)')) {
          return true;
        }
      }
    } catch (_) {
      // Treat unreadable runtime scripts as unsupported and guide the user.
    }
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要更新脚本'),
        content: const Text('当前安装脚本版本不支持 OpenCode 服务管理，请先在环境管理中更新脚本。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return false;
  }

  void _showSnack(String message) {
    if (!mounted) return;
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

  Future<void> _refreshEnvironmentStatus() async {
    if (_checkingEnvironment) return;
    _checkingEnvironment = true;
    if (mounted && _initialEnvironmentError != null) {
      setState(() => _initialEnvironmentError = null);
    }

    try {
      // The existing startup transition remains visible until Ubuntu is ready.
      // This prevents the first script operation from racing rootfs setup.
      await homeController.prepareInitialUbuntuEnvironment();
      final installerState = await _readInstallerScriptState();
      final scriptReady = installerState.state == _InstallerScriptState.valid;
      final baseCommandReady = scriptReady && await _hasBaseCommands();
      final uvReady = scriptReady && baseCommandReady && await _hasUv();
      final napCatReady = scriptReady && baseCommandReady && await _hasNapCat();
      final astrBotReady = scriptReady && uvReady && await _hasAstrBot();
      final openCodeReady = scriptReady && baseCommandReady && await _hasOpenCode();

      if (!mounted) return;
      setState(() {
        _initialEnvironmentError = null;
        _installerScriptState = installerState.state;
        _installerScriptVersion = installerState.version;
        _environmentStates['base'] = _EnvStepState(
          installed: baseCommandReady,
          enabled: scriptReady,
        );
        _environmentStates['uv'] = _EnvStepState(
          installed: uvReady,
          enabled: scriptReady && baseCommandReady,
        );
        _environmentStates['napcat'] = _EnvStepState(
          installed: napCatReady,
          enabled: scriptReady && baseCommandReady,
        );
        _environmentStates['astrbot'] = _EnvStepState(
          installed: astrBotReady,
          enabled: scriptReady && uvReady,
        );
        _environmentStates['opencode'] = _EnvStepState(
          installed: openCodeReady,
          enabled: scriptReady && baseCommandReady,
        );
        homeController.isOpenCodeInstalled.value = openCodeReady;
        _initialEnvironmentCheckComplete = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _initialEnvironmentError = error);
      }
    } finally {
      _checkingEnvironment = false;
      if (mounted &&
          !_initialEnvironmentCheckComplete &&
          _initialEnvironmentError == null) {
        setState(() => _initialEnvironmentCheckComplete = true);
      }
    }
  }

  Future<bool> _hasBaseCommands() async {
    final rootfs = Directory(scripts.ubuntuPath);
    if (!await rootfs.exists()) return false;
    final hasRoot = await Directory('${scripts.ubuntuPath}/root').exists();
    if (!hasRoot) return false;

    final baseFiles = [
      File('${scripts.ubuntuPath}/usr/bin/curl'),
      File('${scripts.ubuntuPath}/usr/bin/git'),
      File('${scripts.ubuntuPath}/usr/bin/sudo'),
    ];
    for (final file in baseFiles) {
      if (!await file.exists()) return false;
    }
    return true;
  }

  Future<_InstallerScriptInfo> _readInstallerScriptState() async {
    final root = '${scripts.ubuntuPath}/root';
    final stateDir = '$root/.astrbot-android/installer';
    final versionFile = File('$stateDir/version');
    final runtimeScript = File('$stateDir/current/astrbot-startup.sh');
    final legacyScript = File('$root/astrbot-startup.sh');

    if (await versionFile.exists() && await runtimeScript.exists()) {
      final version = (await versionFile.readAsString()).trim();
      if (RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
        final mode = (await runtimeScript.stat()).mode;
        if ((mode & 0x49) != 0) {
          return _InstallerScriptInfo(
            state: _InstallerScriptState.valid,
            version: version,
          );
        }
      }
    }

    if (await legacyScript.exists()) {
      return const _InstallerScriptInfo(
        state: _InstallerScriptState.unknownVersion,
      );
    }
    return const _InstallerScriptInfo(
      state: _InstallerScriptState.notDownloaded,
    );
  }

  Future<bool> _hasUv() async {
    return await File('${scripts.ubuntuPath}/root/.local/bin/uv').exists() &&
        await File('${scripts.ubuntuPath}/root/.local/bin/uvx').exists();
  }

  Future<bool> _hasNapCat() async {
    final qqCandidates = [
      File('${scripts.ubuntuPath}/usr/bin/qq'),
      File('${scripts.ubuntuPath}/usr/local/bin/qq'),
      File('${scripts.ubuntuPath}/opt/QQ/qq'),
    ];
    final hasQq = await _anyFileExists(qqCandidates);
    final hasXvfb = await _anyFileExists([
      File('${scripts.ubuntuPath}/usr/bin/Xvfb'),
      File('${scripts.ubuntuPath}/usr/local/bin/Xvfb'),
    ]);
    return hasQq &&
        hasXvfb &&
        await _hasDpkgPackageInstalled('linuxqq') &&
        await _hasDpkgPackageInstalled('libnss3') &&
        await _hasDpkgPackageInstalled('libnspr4') &&
        await _hasAnyDpkgPackageInstalled(['libasound2t64', 'libasound2']) &&
        await File('${scripts.ubuntuPath}/root/launcher.sh').exists() &&
        await File('${scripts.ubuntuPath}/root/libnapcat_launcher.so')
            .exists() &&
        await Directory('${scripts.ubuntuPath}/root/napcat').exists();
  }

  Future<bool> _anyFileExists(List<File> files) async {
    for (final file in files) {
      if (await file.exists()) return true;
    }
    return false;
  }

  Future<bool> _hasAnyDpkgPackageInstalled(List<String> packageNames) async {
    for (final packageName in packageNames) {
      if (await _hasDpkgPackageInstalled(packageName)) return true;
    }
    return false;
  }

  Future<bool> _hasDpkgPackageInstalled(String packageName) async {
    final statusFile = File('${scripts.ubuntuPath}/var/lib/dpkg/status');
    if (!await statusFile.exists()) return false;
    try {
      final blocks = (await statusFile.readAsString())
          .replaceAll('\r\n', '\n')
          .split('\n\n');
      for (final block in blocks) {
        if (block.contains('\nPackage: $packageName\n') ||
            block.startsWith('Package: $packageName\n')) {
          return block.contains('Status: install ok installed');
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<bool> _hasAstrBot() async {
    final root = '${scripts.ubuntuPath}/root/AstrBot';
    if (!await Directory(root).exists()) return false;
    if (!await File('$root/pyproject.toml').exists()) return false;
    if (!await File('$root/main.py').exists()) return false;
    if (!await Directory('$root/.venv').exists()) return false;

    final libDir = Directory('$root/.venv/lib');
    if (!await libDir.exists()) return false;
    await for (final entity in libDir.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = entity.path.replaceAll('\\', '/');
      if (entity is Directory && path.contains('/site-packages/aiohttp')) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _hasOpenCode() {
    return File('${scripts.ubuntuPath}/root/.local/bin/opencode').exists();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final fontScale = homeController.homeFontScale.value;
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(fontScale),
        ),
        child: Column(
          children: [
            GlassAppBar(
              title: '主页',
              opacity: homeController.topNavGlassOpacity.value,
              blur: homeController.glassBlurAmount.value * 30,
              actions: [
                IconButton(
                  tooltip: '设置',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
            Expanded(
              child: _initialEnvironmentCheckComplete
                  ? ListView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                      children: [
                        _buildQuickStartCard(context),
                        const SizedBox(height: 12),
                        _buildNapCatAccountsCard(context),
                        const SizedBox(height: 12),
                        Obx(() => homeController.isOpenCodeInstalled.value
                            ? Column(
                                children: [
                                  _buildOpenCodeCard(context),
                                  const SizedBox(height: 12),
                                ],
                              )
                            : const SizedBox.shrink()),
                        _buildEnvironmentCard(context),
                      ],
                    )
                  : _EnvironmentLoadingView(
                      error: _initialEnvironmentError,
                      onRetry: _initialEnvironmentError == null
                          ? null
                          : _refreshEnvironmentStatus,
                      stage: homeController.initialEnvironmentStage.value,
                      progress: homeController.initialEnvironmentProgress.value,
                    ),
            ),
          ],
        ),
      );
    });
  }

  Color _homeButtonForeground(
    BuildContext context,
    _HomeButtonTone tone,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (tone) {
      _HomeButtonTone.primary => colorScheme.onPrimary,
      _HomeButtonTone.secondary => colorScheme.onSurface,
      _HomeButtonTone.success => Colors.white,
      _HomeButtonTone.destructive => colorScheme.onError,
    };
  }

  ButtonStyle _homeButtonStyle(
    BuildContext context,
    _HomeButtonTone tone,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final secondaryBackground = Color.lerp(
      colorScheme.surface,
      colorScheme.onSurface,
      theme.brightness == Brightness.dark ? 0.14 : 0.08,
    )!;
    final background = switch (tone) {
      _HomeButtonTone.primary => colorScheme.primary,
      _HomeButtonTone.secondary => secondaryBackground,
      _HomeButtonTone.success => theme.brightness == Brightness.dark
          ? Colors.green.shade500
          : Colors.green.shade400,
      _HomeButtonTone.destructive => colorScheme.error,
    };
    final foreground = _homeButtonForeground(context, tone);
    final shadow = switch (tone) {
      _HomeButtonTone.primary => colorScheme.primary.withValues(alpha: 0.30),
      _HomeButtonTone.secondary =>
        colorScheme.shadow.withValues(alpha: 0.13),
      _HomeButtonTone.success => Colors.green.withValues(alpha: 0.20),
      _HomeButtonTone.destructive => colorScheme.error.withValues(alpha: 0.28),
    };
    final edgeColor = switch (tone) {
      _HomeButtonTone.primary => foreground.withValues(alpha: 0.16),
      _HomeButtonTone.secondary => theme.brightness == Brightness.dark
          ? colorScheme.onSurface.withValues(alpha: 0.10)
          : colorScheme.surface.withValues(alpha: 0.78),
      _HomeButtonTone.success => Colors.white.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.34 : 0.72,
        ),
      _HomeButtonTone.destructive => foreground.withValues(alpha: 0.16),
    };

    return ButtonStyle(
      animationDuration: const Duration(milliseconds: 140),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w600),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return Color.lerp(
            colorScheme.surface,
            colorScheme.onSurface,
            theme.brightness == Brightness.dark ? 0.10 : 0.06,
          );
        }
        return background;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colorScheme.onSurface.withValues(alpha: 0.38);
        }
        return foreground;
      }),
      overlayColor: WidgetStatePropertyAll(
        foreground.withValues(alpha: 0.10),
      ),
      elevation: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return 0;
        if (states.contains(WidgetState.pressed)) return 1;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return 4;
        }
        return 3;
      }),
      shadowColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return Colors.transparent;
        }
        return shadow;
      }),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(
            color: colorScheme.onSurface.withValues(alpha: 0.04),
          );
        }
        return BorderSide(color: edgeColor);
      }),
    );
  }

  Widget _homeButton({
    required BuildContext context,
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
    _HomeButtonTone tone = _HomeButtonTone.secondary,
  }) {
    return FilledButton.icon(
      style: _homeButtonStyle(context, tone),
      onPressed: onPressed,
      icon: icon,
      label: label,
    );
  }

  Widget _buildQuickStartCard(BuildContext context) {
    final installed = _environmentStates['astrbot']?.installed == true;
    final card = GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AstrBotSparkleIcon(),
              const SizedBox(width: 8),
              Text('AstrBot', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'AstrBot 更多',
                onSelected: _handleAstrBotMenu,
                itemBuilder: (context) {
                  final completed =
                      homeController.initialPasswordAssistanceCompleted.value;
                  return [
                    PopupMenuItem<String>(
                      value: 'copy_initial_password',
                      enabled: !completed,
                      child: Row(
                        children: [
                          const Icon(Icons.copy, size: 20),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              completed ? '复制初始密码（已完成首次登录）' : '复制初始密码',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'reset_dashboard_password',
                      child: Row(
                        children: [
                          Icon(Icons.lock_reset, size: 20),
                          SizedBox(width: 10),
                          Text('重置面板密码'),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'change_dashboard_port',
                      child: Row(
                        children: [
                          Icon(Icons.settings_ethernet, size: 20),
                          SizedBox(width: 10),
                          Text('修改监听端口'),
                        ],
                      ),
                    ),
                  ];
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Obx(
                  () {
                    final starting = homeController.isAstrBotStarting.value;
                    final running = homeController.isAstrBotRunning.value;
                    final stopping = homeController.isAstrBotStopping.value;
                    final busy = starting || stopping;

                    final tone = running || stopping
                        ? _HomeButtonTone.destructive
                        : _HomeButtonTone.primary;
                    return _homeButton(
                      context: context,
                      tone: tone,
                      onPressed: busy
                          ? null
                          : running
                              ? _stopAstrBot
                              : _startAstrBot,
                      icon: busy
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _homeButtonForeground(context, tone),
                              ),
                            )
                          : Icon(running ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        starting
                            ? '启动中'
                            : stopping
                                ? '停止中'
                                : running
                                    ? '停止'
                                    : '启动 AstrBot',
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _homeButton(
                  context: context,
                  onPressed: () {
                    homeController.requestOpenAstrBotWebUi();
                    widget.onNavigate?.call(1);
                  },
                  icon: const Icon(Icons.language),
                  label: const Text('打开 WebUI'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return _buildInstallGatedCard(
      installed: installed,
      message: '请先在环境管理中安装 AstrBot',
      child: card,
    );
  }

  Widget _buildNapCatAccountsCard(BuildContext context) {
    final installed = _environmentStates['napcat']?.installed == true;
    final card = GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pets),
              const SizedBox(width: 8),
              Text(
                'NapCat 账号',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: '添加账号',
                onPressed: _showAddNapCatAccountDialog,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Obx(() {
            final instances = homeController.napCatInstances;
            if (instances.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '添加账号后单独扫码登录，每个账号独立端口和登录态。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  _homeButton(
                    context: context,
                    onPressed: _showAddNapCatAccountDialog,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('添加账号'),
                  ),
                ],
              );
            }

            return Column(
              children: instances
                  .map((instance) => _buildNapCatAccountTileV2(instance))
                  .toList(),
            );
          }),
        ],
      ),
    );
    return _buildInstallGatedCard(
      installed: installed,
      message: '请先在环境管理中安装 NapCat',
      child: card,
    );
  }

  Widget _buildInstallGatedCard({
    required bool installed,
    required String message,
    required Widget child,
  }) {
    if (installed) return child;
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        IgnorePointer(
          child: Opacity(opacity: 0.42, child: child),
        ),
        Positioned.fill(
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.94,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_for_offline_outlined,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      message,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNapCatAccountTileV2(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    final running = instance['running'] == true;
    final operation = _napCatBusyOperations[id];
    final busy = operation != null;
    final deleting = operation == _NapCatAccountOperation.deleting;
    final name = instance['name']?.toString() ?? '账号';
    final qq = instance['qq']?.toString() ?? '';
    final port = instance['webUiPort']?.toString() ?? '';
    final canBindBot = qq.trim().isNotEmpty;
    if (running && canBindBot) {
      _ensureBotBindingState(instance);
    }
    final hasBoundAdapter =
        (instance['boundAdapterId']?.toString() ?? '').trim().isNotEmpty;
    final bindingState = running && canBindBot
        ? (_botBindingStates[id] ??
            (hasBoundAdapter
                ? BotBindingConfigState.configured
                : BotBindingConfigState.unconfigured))
        : BotBindingConfigState.unconfigured;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: deleting ? 0.55 : 1,
      child: AbsorbPointer(
        absorbing: busy,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    running ? Icons.play_circle : Icons.pause_circle_outline,
                    color: running ? Colors.green : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: Theme.of(context).textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildBotBindingStatusChip(
                              running ? bindingState : null,
                              refreshing: _botBindingStateLoading.contains(id),
                              onTap: running && canBindBot
                                  ? () => _refreshBotBindingState(instance)
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          deleting
                              ? '删除中...\n正在清理登录态和实例目录'
                              : 'QQ ${qq.isEmpty ? '未绑定，启动后扫码登录' : qq}\nWebUI $port',
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '打开 WebUI',
                        onPressed: () => _openNapCatWebUi(instance),
                        icon: const Icon(Icons.language),
                      ),
                      IconButton(
                        tooltip: busy
                            ? operation.label
                            : running
                                ? '停止'
                                : '启动',
                        onPressed: () => _toggleNapCatInstance(instance),
                        icon: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(running ? Icons.stop : Icons.play_arrow),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) async {
                          switch (value) {
                            case 'edit':
                              await _showEditNapCatAccountDialog(instance);
                              break;
                            case 'copyToken':
                              await _copyNapCatToken(instance);
                              break;
                            case 'copyUrl':
                              await _copyNapCatWebUiUrl(instance);
                              break;
                            case 'bindBot':
                              if (canBindBot) {
                                await _showBindBotDialog(instance);
                              } else {
                                _showSnack('登录 QQ 后可绑定 BOT');
                              }
                              break;
                            case 'logout':
                              await _confirmLogoutNapCatAccount(instance);
                              break;
                            case 'delete':
                              await _confirmDeleteNapCatAccount(instance);
                              break;
                          }
                        },
                        itemBuilder: (context) {
                          final token = instance['token']?.toString() ?? '';
                          return [
                            const PopupMenuItem(
                                value: 'edit', child: Text('编辑')),
                            PopupMenuItem(
                              value: 'bindBot',
                              enabled: canBindBot,
                              child: Text(
                                bindingState ==
                                            BotBindingConfigState.configured ||
                                        bindingState ==
                                            BotBindingConfigState.disabled
                                    ? '管理 BOT 绑定'
                                    : '绑定 BOT',
                              ),
                            ),
                            PopupMenuItem(
                              value: 'copyToken',
                              enabled: token.isNotEmpty,
                              child: const Text('复制 token'),
                            ),
                            const PopupMenuItem(
                              value: 'copyUrl',
                              child: Text('复制完整链接'),
                            ),
                            const PopupMenuItem(
                                value: 'logout', child: Text('退出登录')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('删除')),
                          ];
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openNapCatWebUi(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty) return;
    homeController.requestOpenNapCatWebUi(id);
    widget.onNavigate?.call(1);
  }

  Widget _buildBotBindingStatusChip(
    BotBindingConfigState? state, {
    required bool refreshing,
    VoidCallback? onTap,
  }) {
    final color = switch (state) {
      BotBindingConfigState.configured => Colors.green,
      BotBindingConfigState.disabled => Colors.red,
      BotBindingConfigState.mismatch => Colors.orange,
      BotBindingConfigState.unconfigured => Colors.red,
      null => Colors.grey,
    };
    final text = switch (state) {
      BotBindingConfigState.configured => '已绑定BOT',
      BotBindingConfigState.disabled => '已禁用BOT',
      BotBindingConfigState.mismatch => 'BOT绑定异常',
      BotBindingConfigState.unconfigured => '未绑定BOT',
      null => '未运行',
    };
    final borderRadius = BorderRadius.circular(999);
    final chip = Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: borderRadius,
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: InkWell(
          borderRadius: borderRadius,
          onTap: refreshing ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 9, color: color),
                const SizedBox(width: 5),
                Text(
                  text,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (onTap == null) return chip;
    return Tooltip(
      message: refreshing ? '正在刷新状态' : '点击刷新状态',
      child: chip,
    );
  }

  Widget _buildInstallerScriptStatusChip() {
    final color = switch (_installerScriptState) {
      _InstallerScriptState.valid => Colors.green,
      _InstallerScriptState.unknownVersion => Colors.amber.shade800,
      _InstallerScriptState.notDownloaded => Colors.red,
    };
    final label = switch (_installerScriptState) {
      _InstallerScriptState.valid => 'v${_installerScriptVersion ?? '?'}',
      _InstallerScriptState.unknownVersion => '未知版本',
      _InstallerScriptState.notDownloaded => '脚本未下载',
    };
    final borderRadius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: borderRadius,
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 7, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Set<String> _currentRunningNapCatIds() {
    return homeController.napCatInstances
        .where((instance) => instance['running'] == true)
        .map((instance) => instance['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  void _handleNapCatInstancesChanged(List<Map<String, dynamic>> instances) {
    final runningIds = instances
        .where((instance) => instance['running'] == true)
        .map((instance) => instance['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final stoppedIds = _runningNapCatIds.difference(runningIds);
    final startedIds = runningIds.difference(_runningNapCatIds);

    for (final id in stoppedIds) {
      _invalidateBotBindingState(id);
    }
    _runningNapCatIds
      ..clear()
      ..addAll(runningIds);

    for (final instance in instances) {
      final id = instance['id']?.toString() ?? '';
      final qq = instance['qq']?.toString().trim() ?? '';
      if (startedIds.contains(id) && qq.isNotEmpty) {
        _refreshBotBindingState(instance);
      }
    }
  }

  void _invalidateBotBindingState(String id) {
    _botBindingRefreshVersions[id] = (_botBindingRefreshVersions[id] ?? 0) + 1;
    _botBindingStateLoading.remove(id);
    _botBindingStates.remove(id);
  }

  void _ensureBotBindingState(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty ||
        _botBindingStates.containsKey(id) ||
        _botBindingStateLoading.contains(id)) {
      return;
    }
    _refreshBotBindingState(instance);
  }

  void _refreshAllBotBindingStates() {
    for (final instance in homeController.napCatInstances) {
      final qq = instance['qq']?.toString().trim() ?? '';
      if (qq.isNotEmpty && instance['running'] == true) {
        _refreshBotBindingState(instance);
      }
    }
  }

  Future<void> _refreshBotBindingState(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty) return;
    if (_botBindingStateLoading.contains(id)) return;
    final refreshVersion = (_botBindingRefreshVersions[id] ?? 0) + 1;
    _botBindingRefreshVersions[id] = refreshVersion;
    _botBindingStateLoading.add(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _botBindingRefreshVersions[id] == refreshVersion &&
          _botBindingStateLoading.contains(id)) {
        setState(() {});
      }
    });
    try {
      final data = await _loadBotBindingData(instance);
      if (!mounted || _botBindingRefreshVersions[id] != refreshVersion) {
        return;
      }
      final current = homeController.napCatInstances.firstWhereOrNull(
        (item) => item['id']?.toString() == id,
      );
      if (current == null || current['running'] != true) return;
      setState(() {
        _botBindingStates[id] = data.state;
      });
    } catch (_) {
      if (!mounted || _botBindingRefreshVersions[id] != refreshVersion) {
        return;
      }
      final current = homeController.napCatInstances.firstWhereOrNull(
        (item) => item['id']?.toString() == id,
      );
      if (current == null || current['running'] != true) return;
      setState(() {
        _botBindingStates[id] = BotBindingConfigState.unconfigured;
      });
    } finally {
      if (_botBindingRefreshVersions[id] == refreshVersion) {
        _botBindingStateLoading.remove(id);
        if (mounted) setState(() {});
      }
    }
  }

  Future<_BotBindingData> _loadBotBindingData(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    final current = homeController.napCatInstances.firstWhereOrNull(
          (item) => item['id']?.toString() == id,
        ) ??
        instance;
    final clients = await homeController.listNapCatWebSocketClients(id);
    final adapters = await homeController.listAstrBotOneBotAdapters();
    final selectedClient = await homeController.selectedNapCatWebSocketClient(
      current,
    );
    final selectedAdapter = await homeController.selectedAstrBotAdapter(
      current,
    );
    return _BotBindingData(
      instance: current,
      clients: clients,
      adapters: adapters,
      selectedClient: selectedClient,
      selectedAdapter: selectedAdapter,
      state: homeController.compareBotBinding(selectedClient, selectedAdapter),
    );
  }

  Future<void> _showBindBotDialog(Map<String, dynamic> instance) async {
    final qq = instance['qq']?.toString().trim() ?? '';
    if (qq.isEmpty) {
      _showSnack('登录 QQ 后可绑定 BOT');
      return;
    }
    var refresh = 0;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('绑定BOT'),
            content: SizedBox(
              width: 520,
              child: FutureBuilder<_BotBindingData>(
                key: ValueKey(refresh),
                future: _loadBotBindingData(instance),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox(
                      height: 160,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final data = snapshot.data!;
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBindingStatusBanner(data.state),
                        if (data.state == BotBindingConfigState.mismatch) ...[
                          const SizedBox(height: 8),
                          Text(
                            '当前 BOT 配置与 websocket 不一致，可修复绑定。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.icon(
                              onPressed: data.selectedClient == null ||
                                      data.selectedAdapter == null
                                  ? null
                                  : () async {
                                      final repaired =
                                          await _repairBotBinding(data);
                                      if (repaired == true) {
                                        setDialogState(() => refresh++);
                                      }
                                    },
                              icon: const Icon(Icons.build),
                              label: const Text('修复绑定'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'websocket适配器',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        if (data.clients.isEmpty)
                          const Text('未找到 websocket client 配置')
                        else
                          ...data.clients.map(
                            (client) => RadioListTile<String>(
                              dense: true,
                              value: client.name,
                              groupValue: data.selectedClient?.name,
                              onChanged: (_) async {
                                try {
                                  await homeController
                                      .bindNapCatWebSocketClient(
                                    id: data.instance['id']?.toString() ?? '',
                                    clientName: client.name,
                                  );
                                  setDialogState(() => refresh++);
                                } catch (e) {
                                  _showSnack('绑定 websocket 失败：$e');
                                }
                              },
                              title: Text(client.name),
                              subtitle: Text(
                                '${client.enabled ? '已启用' : '未启用'} · ${client.url}',
                              ),
                            ),
                          ),
                        const Divider(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'AstrBot适配器',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: data.selectedClient == null
                                  ? null
                                  : () async {
                                      final created =
                                          await _createAstrBotAdapter(data);
                                      if (created == true) {
                                        setDialogState(() => refresh++);
                                      }
                                    },
                              icon: const Icon(Icons.add),
                              label: const Text('新建'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (data.adapters.isEmpty)
                          const Text('未找到 AstrBot OneBot 适配器')
                        else
                          ...data.adapters.map(
                            (adapter) => RadioListTile<String>(
                              dense: true,
                              value: adapter.id,
                              groupValue: data.selectedAdapter?.id,
                              onChanged: (_) async {
                                final changed = await _bindAstrBotAdapter(
                                  data,
                                  adapter,
                                );
                                if (changed == true) {
                                  setDialogState(() => refresh++);
                                }
                              },
                              title: Text(adapter.id),
                              subtitle: Text(
                                '${adapter.enabled ? '已启用' : '未启用'} · ${adapter.port} · token ${adapter.token.isEmpty ? '空' : '已设置'}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    await _refreshBotBindingState(instance);
  }

  Widget _buildBindingStatusBanner(BotBindingConfigState state) {
    final color = switch (state) {
      BotBindingConfigState.configured => Colors.green,
      BotBindingConfigState.disabled => Colors.red,
      BotBindingConfigState.mismatch => Colors.orange,
      BotBindingConfigState.unconfigured => Colors.red,
    };
    final text = switch (state) {
      BotBindingConfigState.configured => '已绑定BOT',
      BotBindingConfigState.disabled => '已禁用BOT',
      BotBindingConfigState.mismatch => 'BOT绑定异常',
      BotBindingConfigState.unconfigured => '未绑定BOT',
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: color)),
      ],
    );
  }

  Future<bool?> _bindAstrBotAdapter(
    _BotBindingData data,
    AstrBotOneBotAdapter adapter,
  ) async {
    final id = data.instance['id']?.toString() ?? '';
    final client = data.selectedClient;
    if (id.isEmpty || client == null) {
      _showSnack('请先绑定 websocket 适配器');
      return false;
    }

    var invalidatePrevious = false;
    final currentAdapterId = data.instance['boundAdapterId']?.toString() ?? '';
    if (currentAdapterId.isNotEmpty && currentAdapterId != adapter.id) {
      final confirmed = await _confirm(
        title: '换绑适配器',
        content: _withAstrBotRestartNotice(
          '当前账号已经绑定 $currentAdapterId，是否换绑到 ${adapter.id}？',
        ),
        confirmText: '换绑',
      );
      if (confirmed != true) return false;
      invalidatePrevious = true;
    }

    final mismatch =
        client.port != adapter.port || client.token != adapter.token;
    if (mismatch &&
        homeController.isAstrBotAdapterBoundByOther(adapter.id, id)) {
      final confirmed = await _confirm(
        title: '适配器已被绑定',
        content: _withAstrBotRestartNotice(
          '${adapter.id} 已被其他 NapCat 账号绑定，是否按当前 websocket 配置覆盖并换绑？',
        ),
        confirmText: '覆盖换绑',
      );
      if (confirmed != true) return false;
    }

    if (mismatch) {
      final confirmed = await _confirm(
        title: '配置不一致',
        content: _withAstrBotRestartNotice(
          '该 AstrBot 适配器与当前 websocket 的端口或 token 不一致，是否自动修改 AstrBot 适配器？',
        ),
        confirmText: '自动修改',
      );
      if (confirmed != true) return false;
    }

    try {
      await homeController.bindAstrBotAdapter(
        id: id,
        adapterId: adapter.id,
        updateAdapterFromWebSocket: mismatch,
        invalidatePreviousAdapter: invalidatePrevious,
      );
      if (mismatch || invalidatePrevious) {
        await _restartAstrBotIfRunningAfterAdapterChange();
      }
      return true;
    } catch (e) {
      _showSnack('绑定 AstrBot 适配器失败：$e');
      return false;
    }
  }

  Future<bool?> _repairBotBinding(_BotBindingData data) async {
    final id = data.instance['id']?.toString() ?? '';
    final adapter = data.selectedAdapter;
    if (id.isEmpty || data.selectedClient == null || adapter == null) {
      _showSnack('请先选择 websocket 和 AstrBot 适配器');
      return false;
    }
    final confirmed = await _confirm(
      title: '修复绑定',
      content: _withAstrBotRestartNotice(
        '是否将当前 AstrBot 适配器同步为所选 websocket 的端口和 token？',
      ),
      confirmText: '修复绑定',
    );
    if (confirmed != true) return false;

    try {
      await homeController.bindAstrBotAdapter(
        id: id,
        adapterId: adapter.id,
        updateAdapterFromWebSocket: true,
      );
      await _restartAstrBotIfRunningAfterAdapterChange();
      _showSnack('BOT 绑定已修复');
      return true;
    } catch (e) {
      _showSnack('修复 BOT 绑定失败：$e');
      return false;
    }
  }

  Future<bool?> _createAstrBotAdapter(_BotBindingData data) async {
    final id = data.instance['id']?.toString() ?? '';
    final controller = TextEditingController(
      text: data.instance['name']?.toString() ?? '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 AstrBot 适配器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'BOT名称',
                hintText: '留空使用 NapCat 卡片名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _newAstrBotAdapterNotice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('新建'),
          ),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return false;
    final oldAdapterId = data.instance['boundAdapterId']?.toString() ?? '';
    var allowSharedPreviousAdapter = false;
    if (oldAdapterId.isNotEmpty &&
        homeController.isAstrBotAdapterBoundByOther(oldAdapterId, id)) {
      final continueCreate = await _confirm(
        title: '旧适配器被复用',
        content: _withAstrBotRestartNotice(
          '旧 AstrBot 适配器 $oldAdapterId 已被其他 NapCat 账号绑定，继续新建不会无效化旧适配器，可能导致端口冲突。是否继续？',
        ),
        confirmText: '继续新建',
      );
      if (continueCreate != true) return false;
      allowSharedPreviousAdapter = true;
    }
    try {
      await homeController.createAstrBotAdapterForNapCat(
        id: id,
        preferredName: name,
        allowSharedPreviousAdapter: allowSharedPreviousAdapter,
      );
      await _restartAstrBotIfRunningAfterAdapterChange();
      return true;
    } catch (e) {
      _showSnack('新建 AstrBot 适配器失败：$e');
      return false;
    }
  }

  static const String _astrBotRestartNotice = '修改后，已运行的 AstrBot 会重启。';
  static const String _newAstrBotAdapterNotice = '新建后会自动绑定，已运行的 AstrBot 会重启。';

  String _withAstrBotRestartNotice(String content) {
    return '$content\n\n$_astrBotRestartNotice';
  }

  Future<void> _restartAstrBotIfRunningAfterAdapterChange() async {
    if (!homeController.isAstrBotRunning.value) return;
    try {
      _showSnack('AstrBot 配置已保存，正在重启...');
      await homeController.stopAstrBot();
      await Future.delayed(const Duration(milliseconds: 300));
      await homeController.loadAstrBot();
    } catch (e) {
      _showSnack('配置已保存，但 AstrBot 重启失败：$e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Future<void> _copyNapCatToken(Map<String, dynamic> instance) async {
    final token = instance['token']?.toString() ?? '';
    if (token.isEmpty) {
      _showSnack('暂未获取到 token');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _showSnack('token 已复制');
  }

  Future<void> _copyNapCatWebUiUrl(Map<String, dynamic> instance) async {
    final url = homeController.napCatInstanceWebUiUrl(instance);
    await Clipboard.setData(ClipboardData(text: url));
    _showSnack('完整链接已复制');
  }

  Future<void> _toggleNapCatInstance(Map<String, dynamic> instance) async {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    final running = instance['running'] == true;
    setState(() {
      _napCatBusyOperations[id] = running
          ? _NapCatAccountOperation.stopping
          : _NapCatAccountOperation.starting;
    });
    try {
      if (running) {
        await homeController.stopNapCatInstance(id);
      } else {
        widget.onNavigate?.call(2);
        await Future.delayed(const Duration(milliseconds: 50));
        await homeController.startNapCatInstance(id);
      }
    } catch (e) {
      _showSnack('${running ? '停止' : '启动'}失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Future<void> _showAddNapCatAccountDialog() async {
    final result = await _showNapCatAccountDialog(
      title: '添加 NapCat 账号',
    );
    if (result == null) return;

    final webUiPort = result.webUiPortText.isEmpty
        ? null
        : int.tryParse(result.webUiPortText);
    if (result.webUiPortText.isNotEmpty && webUiPort == null) {
      _showSnack('端口只能填写数字，留空表示自动分配');
      return;
    }

    try {
      await homeController.addNapCatInstance(webUiPort: webUiPort);
      Future.delayed(
          const Duration(milliseconds: 300), _refreshEnvironmentStatus);
    } catch (e) {
      _showSnack('添加失败：$e');
    }
  }

  Future<void> _showEditNapCatAccountDialog(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    final oneBotPort = await homeController.napCatInstanceOneBotPort(id);
    final result = await _showNapCatAccountDialog(
      title: '编辑 NapCat 账号',
      initialName: instance['name']?.toString() ?? '',
      initialWebUiPort: instance['webUiPort']?.toString() ?? '',
      initialOneBotPort: oneBotPort?.toString() ?? '',
      initialDisplay: instance['display']?.toString() ?? '',
      showAdvancedFields: true,
    );
    if (result == null) return;

    final portText = result.webUiPortText;
    final oneBotPortText = result.oneBotPortText;
    final displayText = result.displayText;
    final port = int.tryParse(portText);
    final nextOneBotPort =
        oneBotPortText.isEmpty ? null : int.tryParse(oneBotPortText);
    final nextDisplay = displayText.isEmpty ? null : int.tryParse(displayText);
    final name = result.nameText;

    if (portText.isNotEmpty && port == null) {
      _showSnack('WebUI 端口只能填写数字');
      return;
    }
    if (oneBotPortText.isNotEmpty && nextOneBotPort == null) {
      _showSnack('OneBot WebSocket 端口只能填写数字');
      return;
    }
    if (displayText.isNotEmpty && nextDisplay == null) {
      _showSnack('DISPLAY 只能填写数字');
      return;
    }

    try {
      await homeController.updateNapCatInstanceConfig(
        id: id,
        webUiPort: port,
        oneBotPort: nextOneBotPort,
        display: nextDisplay,
        name: name,
      );
      Future.delayed(
          const Duration(milliseconds: 300), _refreshEnvironmentStatus);
    } catch (e) {
      _showSnack('保存失败：$e');
    }
  }

  Future<_NapCatAccountDialogResult?> _showNapCatAccountDialog({
    required String title,
    String initialName = '',
    String initialWebUiPort = '',
    String initialOneBotPort = '',
    String initialDisplay = '',
    bool showAdvancedFields = false,
  }) {
    return showDialog<_NapCatAccountDialogResult>(
      context: context,
      builder: (context) => _NapCatAccountDialog(
        title: title,
        initialName: initialName,
        initialWebUiPort: initialWebUiPort,
        initialOneBotPort: initialOneBotPort,
        initialDisplay: initialDisplay,
        showAdvancedFields: showAdvancedFields,
      ),
    );
  }

  Future<void> _confirmLogoutNapCatAccount(
    Map<String, dynamic> instance,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: Text('确定退出 ${instance['name'] ?? '账号'} 吗？后续启动需要重新扫码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    setState(() {
      _napCatBusyOperations[id] = _NapCatAccountOperation.loggingOut;
    });
    try {
      await homeController.logoutNapCatInstance(id);
      _showSnack('已退出登录');
    } catch (e) {
      _showSnack('退出登录失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Future<void> _confirmDeleteNapCatAccount(
    Map<String, dynamic> instance,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除 ${instance['name'] ?? '账号'} 吗？登录态和配置会一并清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    setState(() {
      _napCatBusyOperations[id] = _NapCatAccountOperation.deleting;
    });
    try {
      await homeController.deleteNapCatInstance(id);
      _showSnack('已删除账号');
    } catch (e) {
      _showSnack('删除失败：$e');
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Widget _buildOpenCodeCard(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined),
              const SizedBox(width: 8),
              Text('OpenCode', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'OpenCode 更多',
                onSelected: (value) {
                  if (value == 'port') _showOpenCodePortDialog();
                  if (value == 'uninstall') _showOpenCodeUninstallDialog();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'port',
                    child: ListTile(
                      leading: Icon(Icons.settings_ethernet),
                      title: Text('修改监听端口'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'uninstall',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('卸载'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Obx(() => _homeButton(
                      context: context,
                      tone: homeController.isOpenCodeRunning.value
                          ? _HomeButtonTone.destructive
                          : _HomeButtonTone.primary,
                      onPressed: _startOpenCode,
                      icon: Icon(homeController.isOpenCodeRunning.value
                          ? Icons.stop
                          : Icons.play_arrow),
                      label: Text(homeController.isOpenCodeRunning.value
                          ? '停止'
                          : '启动'),
                    )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _homeButton(
                  context: context,
                  onPressed: _openOpenCodeWebUi,
                  icon: const Icon(Icons.language),
                  label: const Text('打开 WebUI'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openOpenCodeWebUi() async {
    if (!homeController.isOpenCodeRunning.value) {
      _showSnack('请先启动 OpenCode');
      return;
    }
    _showSnack('正在等待 OpenCode WebUI 就绪');
    final uri = Uri.parse(ServicePorts.openCodeWebUiUrl);
    var ready = false;
    for (var attempt = 0; attempt < 15 && mounted; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      try {
        final request = await client.getUrl(uri).timeout(
              const Duration(seconds: 2),
            );
        final response = await request.close().timeout(
              const Duration(seconds: 2),
            );
        await response.drain<void>();
        ready = response.statusCode > 0;
      } catch (_) {
        ready = false;
      } finally {
        client.close(force: true);
      }
      if (ready) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    if (!ready) {
      _showSnack('OpenCode WebUI 暂未响应，请查看终端日志');
      return;
    }
    homeController.requestOpenOpenCodeWebUi();
    widget.onNavigate?.call(1);
  }

  Widget _buildEnvironmentCard(BuildContext context) {
    final steps = [
      _EnvStep(
        'base',
        '基础命令',
        'sudo / git / curl',
        const Icon(Icons.extension),
        reinstallDescription: '将重新检查并补装 sudo / git / curl，不会主动删除系统包。是否继续？',
      ),
      _EnvStep(
        'uv',
        'uv',
        'Python 依赖管理工具',
        const Icon(Icons.construction),
        reinstallDescription: '将删除现有 uv/uvx 后重新下载。是否继续？',
      ),
      _EnvStep(
        'napcat',
        'NapCat',
        '安装或修复 NapCatQQ',
        const Icon(Icons.pets),
        reinstallDescription: '将清理 NapCat 安装文件并重新安装，尽量保留配置目录。是否继续？',
      ),
      _EnvStep(
        'astrbot',
        'AstrBot',
        '克隆 AstrBot 并同步依赖',
        const AstrBotSparkleIcon(),
        reinstallDescription:
            '将重新克隆 AstrBot 并重建 Python 依赖，尽量保留 data 数据目录。是否继续？',
      ),
      _EnvStep(
        'opencode',
        'OpenCode',
        'AI 编程助手',
        const Icon(Icons.smart_toy_outlined),
        isExtension: true,
        reinstallDescription: '将重新下载 OpenCode 二进制文件。是否继续？',
      ),
    ];

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        onExpansionChanged: (expanded) {
          if (mounted) setState(() => _environmentExpanded = expanded);
        },
        leading: const Icon(Icons.inventory_2_outlined),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('环境管理', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            _buildInstallerScriptStatusChip(),
          ],
        ),
        subtitle: Text(_environmentExpanded ? '点击收起' : '点击展开'),
        trailing: _homeButton(
          context: context,
          tone: EnvironmentConfig.githubProxy != EnvironmentConfig.autoProxy &&
                  EnvironmentConfig.githubProxy !=
                      EnvironmentConfig.directProxy
              ? _HomeButtonTone.success
              : _HomeButtonTone.secondary,
          onPressed: _showGithubProxyDialog,
          icon: const Icon(Icons.speed),
          label: const Text('加速器'),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: _homeButton(
                    context: context,
                    tone: _HomeButtonTone.primary,
                    onPressed: _checkThenOfferInstallerUpdate,
                    icon: const Icon(Icons.system_update_alt),
                    label: Text(
                      _installerScriptState == _InstallerScriptState.notDownloaded
                          ? '下载脚本'
                          : '更新脚本',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _homeButton(
                    context: context,
                    onPressed: _importInstallerPackage,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('导入脚本'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...steps.take(4).map(_buildEnvironmentStepTile),
          const Divider(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('扩展应用', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(height: 4),
          ...steps.skip(4).map(_buildEnvironmentStepTile),
        ],
      ),
    );
  }

  Widget _buildEnvironmentStepTile(_EnvStep step) {
    final state = _environmentStates[step.id] ?? const _EnvStepState.unknown();
    final color = !state.enabled
        ? Colors.grey
        : state.installed
            ? Colors.green
            : Colors.red;
    final statusIcon = !state.enabled
        ? Icons.lock_outline
        : state.installed
            ? Icons.check_circle
            : step.isExtension
                ? null
                : Icons.error;
    final buttonText = state.installed ? '重装' : '安装';
    final scriptReady = _installerScriptState == _InstallerScriptState.valid;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          IconTheme.merge(
            data: IconThemeData(color: state.enabled ? null : Colors.grey),
            child: step.icon,
          ),
          if (statusIcon != null)
            Positioned(
              right: -8,
              bottom: -6,
              child: Icon(statusIcon, size: 16, color: color),
            ),
        ],
      ),
      title: Text(
        step.title,
        style: TextStyle(color: state.enabled ? null : Colors.grey),
      ),
      subtitle: Text(
        state.enabled
            ? step.subtitle
            : scriptReady
                ? '请先安装上方依赖项'
                : '请先下载或更新脚本',
        style: TextStyle(color: state.enabled ? null : Colors.grey),
      ),
      trailing: _homeButton(
        context: context,
        onPressed: state.enabled ? () => _runStep(step, state) : null,
        icon: const Icon(Icons.download),
        label: Text(buttonText),
      ),
    );
  }
}

class _EnvironmentLoadingView extends StatelessWidget {
  final Object? error;
  final VoidCallback? onRetry;
  final String stage;
  final double progress;

  const _EnvironmentLoadingView({
    this.error,
    this.onRetry,
    required this.stage,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              Icon(
                Icons.error_outline,
                size: 32,
                color: Theme.of(context).colorScheme.error,
              )
            else
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            const SizedBox(height: 16),
            Text(
              failed ? '运行环境准备失败' : stage,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              failed
                  ? '请重试后再进入主页'
                  : '首次启动可能需要一些时间，完成后将自动进入主页',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (!failed) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(value: progress),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _NapCatAccountOperation {
  starting,
  stopping,
  deleting,
  loggingOut,
}

class _NapCatAccountDialogResult {
  final String nameText;
  final String webUiPortText;
  final String oneBotPortText;
  final String displayText;

  const _NapCatAccountDialogResult({
    required this.nameText,
    required this.webUiPortText,
    required this.oneBotPortText,
    required this.displayText,
  });
}

class _NapCatAccountDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final String initialWebUiPort;
  final String initialOneBotPort;
  final String initialDisplay;
  final bool showAdvancedFields;

  const _NapCatAccountDialog({
    required this.title,
    required this.initialName,
    required this.initialWebUiPort,
    required this.initialOneBotPort,
    required this.initialDisplay,
    required this.showAdvancedFields,
  });

  @override
  State<_NapCatAccountDialog> createState() => _NapCatAccountDialogState();
}

class _NapCatAccountDialogState extends State<_NapCatAccountDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _webUiPortController;
  late final TextEditingController _oneBotPortController;
  late final TextEditingController _displayController;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _webUiPortController = TextEditingController(text: widget.initialWebUiPort);
    _oneBotPortController =
        TextEditingController(text: widget.initialOneBotPort);
    _displayController = TextEditingController(text: widget.initialDisplay);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _webUiPortController.dispose();
    _oneBotPortController.dispose();
    _displayController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      _NapCatAccountDialogResult(
        nameText: _nameController.text.trim(),
        webUiPortText: _webUiPortController.text.trim(),
        oneBotPortText: _oneBotPortController.text.trim(),
        displayText: _displayController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.initialName.isNotEmpty || widget.showAdvancedFields) ...[
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '账号名称',
                  hintText: '例如：账号1',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _webUiPortController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'NapCat WebUI 端口',
                hintText: '留空自动分配，范围 6099-6149',
                border: OutlineInputBorder(),
              ),
            ),
            if (widget.showAdvancedFields) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _showAdvanced = !_showAdvanced);
                  },
                  icon: Icon(
                    _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: const Text('高级'),
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _oneBotPortController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'OneBot WebSocket 端口',
                    hintText: '例如：6199',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _displayController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'DISPLAY ID',
                    hintText: '范围 2-99',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _BotBindingData {
  final Map<String, dynamic> instance;
  final List<NapCatWebSocketClient> clients;
  final List<AstrBotOneBotAdapter> adapters;
  final NapCatWebSocketClient? selectedClient;
  final AstrBotOneBotAdapter? selectedAdapter;
  final BotBindingConfigState state;

  const _BotBindingData({
    required this.instance,
    required this.clients,
    required this.adapters,
    required this.selectedClient,
    required this.selectedAdapter,
    required this.state,
  });
}

extension _NapCatAccountOperationLabel on _NapCatAccountOperation {
  String get label {
    switch (this) {
      case _NapCatAccountOperation.starting:
        return '正在启动';
      case _NapCatAccountOperation.stopping:
        return '正在停止';
      case _NapCatAccountOperation.deleting:
        return '正在删除';
      case _NapCatAccountOperation.loggingOut:
        return '正在退出登录';
    }
  }
}

class _GithubProxyDialog extends StatefulWidget {
  const _GithubProxyDialog();

  @override
  State<_GithubProxyDialog> createState() => _GithubProxyDialogState();
}

class _GithubProxyDialogState extends State<_GithubProxyDialog> {
  static const String _testTarget =
      'https://raw.githubusercontent.com/astral-sh/uv/main/README.md';
  final Map<String, int> _latencies = {};
  final Set<String> _testing = {};

  String get _selectedProxyLabel {
    final selected = EnvironmentConfig.githubProxy;
    if (selected == EnvironmentConfig.autoProxy) return 'AUTO';
    if (selected == EnvironmentConfig.directProxy) return '直连';
    return EnvironmentConfig.labelForProxy(selected);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _testAll());
  }

  void _testAll() {
    final targets = EnvironmentConfig.githubProxyOptions.where(
      (option) => option['value'] != EnvironmentConfig.autoProxy,
    );
    setState(() {
      _latencies.clear();
      _testing
        ..clear()
        ..addAll(targets.map((option) => option['value']!));
    });
    for (final option in targets) {
      _testProxy(option['value']!);
    }
  }

  Future<void> _testProxy(String proxy) async {
    final stopwatch = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    var result = -1;
    try {
      final url = proxy == EnvironmentConfig.directProxy
          ? _testTarget
          : '$proxy/$_testTarget';
      final request = await client.getUrl(Uri.parse(url));
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        result = stopwatch.elapsedMilliseconds;
      }
    } catch (_) {
      result = -1;
    } finally {
      stopwatch.stop();
      client.close(force: true);
      _latencies[proxy] = result;
      _testing.remove(proxy);
      _updateAutoResolved();
      if (mounted) setState(() {});
    }
  }

  void _updateAutoResolved() {
    String? fastest;
    var fastestMs = 1 << 30;
    for (final entry in _latencies.entries) {
      if (entry.value >= 0 && entry.value < fastestMs) {
        fastest = entry.key;
        fastestMs = entry.value;
      }
    }
    if (fastest != null) {
      EnvironmentConfig.setGithubProxyAutoResolved(fastest);
    }
  }

  List<Map<String, String>> get _sortedOptions {
    final all = EnvironmentConfig.githubProxyOptions;
    final direct = all.firstWhere(
      (option) => option['value'] == EnvironmentConfig.directProxy,
    );
    final auto = all.firstWhere(
      (option) => option['value'] == EnvironmentConfig.autoProxy,
    );
    final proxies = all
        .where(
          (option) =>
              option['value'] != EnvironmentConfig.directProxy &&
              option['value'] != EnvironmentConfig.autoProxy,
        )
        .toList();
    proxies.sort((a, b) {
      final av = _latencies[a['value']!];
      final bv = _latencies[b['value']!];
      final ar = av == null ? 1 : (av < 0 ? 2 : 0);
      final br = bv == null ? 1 : (bv < 0 ? 2 : 0);
      if (ar != br) return ar.compareTo(br);
      if (ar == 0 && av != bv) return av!.compareTo(bv!);
      return a['name']!.compareTo(b['name']!);
    });
    return [direct, auto, ...proxies];
  }

  Color _latencyColor(int latency) {
    if (latency < 0) return Colors.red;
    if (latency < 800) return Colors.green;
    if (latency < 2000) return Colors.orange;
    return Colors.grey;
  }

  Widget _statusWidget(String value) {
    if (value == EnvironmentConfig.autoProxy) {
      final resolved = EnvironmentConfig.githubProxyAutoResolved;
      return Text(
        EnvironmentConfig.labelForProxy(resolved),
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    if (_testing.contains(value)) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 6),
          Text('测速中', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    final latency = _latencies[value];
    if (latency == null) {
      return const Text(
        '未测速',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Text(
      latency < 0 ? '失败' : '$latency ms',
      style: TextStyle(
        fontSize: 12,
        color: _latencyColor(latency),
        fontWeight: FontWeight.bold,
      ),
    );
  }

  void _select(String value) {
    if (value == EnvironmentConfig.autoProxy) _updateAutoResolved();
    EnvironmentConfig.setGithubProxy(value);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.min(400.0, MediaQuery.sizeOf(context).height * 0.55);
    return AlertDialog(
      title: const Text('GitHub 代理测速'),
      content: SizedBox(
        width: double.maxFinite,
        height: maxHeight,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '当前选择节点：$_selectedProxyLabel',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                TextButton.icon(
                  onPressed: _testing.isEmpty ? _testAll : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新测速'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: _sortedOptions.map((option) {
                  final value = option['value']!;
                  return ListTile(
                    leading: Radio<String>(
                      value: value,
                      groupValue: EnvironmentConfig.githubProxy,
                      onChanged: (_) => _select(value),
                    ),
                    title: Text(option['name']!),
                    trailing: _statusWidget(value),
                    onTap: () => _select(value),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _EnvStep {
  final String id;
  final String title;
  final String subtitle;
  final Widget icon;
  final String? reinstallDescription;
  final bool isExtension;

  const _EnvStep(
    this.id,
    this.title,
    this.subtitle,
    this.icon, {
    this.reinstallDescription,
    this.isExtension = false,
  });

  String get reinstallMessage =>
      reinstallDescription ?? '将先清理现有 $title 组件，再重新安装。是否继续？';
}

class AstrBotSparkleIcon extends StatelessWidget {
  final double? size;
  final Color? color;

  const AstrBotSparkleIcon({
    super.key,
    this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color ?? Colors.black;
    return SizedBox.square(
      dimension: resolvedSize,
      child: CustomPaint(
        painter: _AstrBotSparkleIconPainter(resolvedColor),
      ),
    );
  }
}

class _AstrBotSparkleIconPainter extends CustomPainter {
  final Color color;

  const _AstrBotSparkleIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final center = Offset(size.width / 2, size.height / 2);
    final longRadius = size.shortestSide * 0.46;
    final shortRadius = size.shortestSide * 0.16;
    final path = Path();

    for (var i = 0; i < 8; i++) {
      final angle = -1.57079632679 + i * 0.78539816339;
      final radius = i.isEven ? longRadius : shortRadius;
      final point = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }

    canvas.drawPath(path..close(), paint);
  }

  @override
  bool shouldRepaint(_AstrBotSparkleIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _EnvStepState {
  final bool installed;
  final bool enabled;

  const _EnvStepState({
    required this.installed,
    required this.enabled,
  });

  const _EnvStepState.unknown()
      : installed = false,
        enabled = false;
}

enum _InstallerScriptState { valid, unknownVersion, notDownloaded }

enum _HomeButtonTone { primary, secondary, success, destructive }

class _InstallerScriptInfo {
  final _InstallerScriptState state;
  final String? version;

  const _InstallerScriptInfo({required this.state, this.version});
}
