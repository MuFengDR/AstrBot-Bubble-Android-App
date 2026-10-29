import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:global_repository/global_repository.dart';
import 'package:tar/tar.dart';

import '../constants/scripts.dart';
import 'status_timeline.dart';

/// 备份里的一项内容
/// One entry that a backup may contain
class BackupTarget {
  final String label;

  /// 源路径（绝对路径）
  final String sourcePath;

  /// 归档内相对路径
  final String archivePath;

  /// 只打这一层的文件，不进子目录。
  ///
  /// 安卓上 RuntimeEnvir.configPath 指向的是整个 files 目录（rootfs 也在里面），
  /// 递归下去会把 64MB 系统本体、甚至 2GB 的依赖一起塞进备份。
  final bool flat;

  const BackupTarget({
    required this.label,
    required this.sourcePath,
    required this.archivePath,
    this.flat = false,
  });
}

/// 备份文件信息
class BackupEntry {
  final File file;
  final int sizeBytes;
  final DateTime createdAt;

  const BackupEntry({
    required this.file,
    required this.sizeBytes,
    required this.createdAt,
  });

  String get name => file.uri.pathSegments.last;

  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$sizeBytes B';
  }

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${createdAt.year}-${two(createdAt.month)}-${two(createdAt.day)} '
        '${two(createdAt.hour)}:${two(createdAt.minute)}';
  }
}

/// 一键备份与迁移
/// One tap backup and migration
///
/// 只备份「配置 + 会话数据 + 插件」，不含 64MB 的 rootfs 本体：
/// 迁移到新机器时靠 App 自带的安装流程装环境，再把这份归档解回去。
class BackupService {
  BackupService._();

  static const String _prefix = 'astrbot-backup-';
  static const String _ext = '.tar';
  static const String _restoreTmpName = '.restore-tmp';

  /// 自动备份的文件名里带这个标记，保留策略按它区分手动/自动
  static const String _autoTag = '-auto';

  /// 正在备份/恢复中（自动任务和手动按钮互斥，避免同时写同一个目录）
  static bool _busy = false;

  static bool get isBusy => _busy;

  static Directory get backupDir =>
      Directory('${RuntimeEnvir.homePath}/backups');

  /// 需要备份的目录，按顺序打包
  static List<BackupTarget> get targets => [
        if (Directory('$ubuntuPath/root/AstrBot/data').existsSync())
          BackupTarget(
            label: 'AstrBot 数据',
            sourcePath: '$ubuntuPath/root/AstrBot/data',
            archivePath: 'AstrBot/data',
          ),
        if (Directory('$ubuntuPath/root/AstrBot/config').existsSync())
          BackupTarget(
            label: 'AstrBot 配置',
            sourcePath: '$ubuntuPath/root/AstrBot/config',
            archivePath: 'AstrBot/config',
          ),
        if (Directory('$ubuntuPath/root/napcat/config').existsSync())
          BackupTarget(
            label: 'NapCat 配置',
            sourcePath: '$ubuntuPath/root/napcat/config',
            archivePath: 'napcat/config',
          ),
        if (Directory(RuntimeEnvir.configPath).existsSync())
          BackupTarget(
            label: '应用设置',
            sourcePath: RuntimeEnvir.configPath,
            archivePath: 'app/config',
            // 这里只取 setting.hive 这类顶层文件，别把 files 里的系统镜像带走
            flat: true,
          ),
      ];

  /// 当前环境是否有可备份的内容
  static bool get hasContent => targets.isNotEmpty;

  /// 创建一份备份，返回归档文件
  ///
  /// [auto] 为 true 时文件名带 `-auto` 标记，保留策略只清这类文件。
  static Future<BackupEntry> createBackup({
    void Function(String stage, double progress)? onProgress,
    bool auto = false,
  }) async {
    final list = targets;
    if (list.isEmpty) {
      throw StateError('没有可备份的内容，请先安装 AstrBot 环境');
    }
    if (_busy) {
      throw StateError('已有一个备份/恢复任务在执行');
    }
    _busy = true;
    try {
      return await _createBackupInternal(list, onProgress: onProgress, auto: auto);
    } finally {
      _busy = false;
    }
  }

  static Future<BackupEntry> _createBackupInternal(
    List<BackupTarget> list, {
    void Function(String stage, double progress)? onProgress,
    bool auto = false,
  }) async {
    await backupDir.create(recursive: true);

    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final suffix = auto ? _autoTag : '';
    final file = File('${backupDir.path}/$_prefix$stamp$suffix$_ext');

    // 先数文件总数，用于进度
    var total = 0;
    for (final target in list) {
      total += await _countFiles(
        Directory(target.sourcePath),
        flat: target.flat,
      );
    }
    if (total == 0) total = 1;

    var done = 0;
    onProgress?.call('正在打包…', 0);

    final sink = file.openWrite();
    // tar 2.x 的写入入口是 tarWritingSink（TarWriter 已在 2.0 移除）
    final tarSink = tarWritingSink(sink);
    try {
      for (final target in list) {
        final root = Directory(target.sourcePath);
        if (!await root.exists()) continue;
        await _walk(root, (entity, relative) async {
          final name = '${target.archivePath}/$relative';
          final stat = await entity.stat();
          // StreamSink.add 是 void，内部已按顺序串行；错误统一在 close 时抛
          tarSink.add(TarEntry(
            TarHeader(
              name: name,
              mode: stat.mode,
              size: stat.size,
              modified: stat.modified,
            ),
            entity.openRead(),
          ));
          done++;
          if (done % 20 == 0 || done == total) {
            onProgress?.call(
              '正在打包 ${target.label}（$done/$total）',
              (done / total).clamp(0.0, 1.0),
            );
          }
        }, flat: target.flat);
      }
      // close 会补两个空块并关闭底层 sink
      await tarSink.close();
    } catch (e) {
      try {
        await tarSink.close();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }

    final stat = await file.stat();
    final entry = BackupEntry(
      file: file,
      sizeBytes: stat.size,
      createdAt: stat.modified,
    );
    await _writeManifest(entry);
    await StatusTimeline.instance.record(
      'backup',
      auto ? 'auto_backup_created' : 'backup_created',
      '${auto ? '已自动备份' : '已创建备份'} ${entry.name}（${entry.sizeLabel}）',
      level: TimelineLevel.success,
      // 自动备份每次都是新事件，别被 45 秒去重窗口吃掉
      dedupe: !auto,
    );
    onProgress?.call('备份完成', 1);
    return entry;
  }

  /// 遍历时跳过的目录名。
  ///
  /// proot 环境里 `storage/emulated/0` 是挂到安卓外部存储的绑定目录，
  /// 权限位是 000，Dart 一 list 就抛 PathAccessException；跟着它走还会
  /// 把整机存储扫一遍。这类目录一律不碰。
  static const Set<String> _skipDirNames = {
    'storage',
    'proc',
    'sys',
    'dev',
    'lost+found',
  };

  /// 逐层遍历，单个目录读不了就跳过，不让整份备份失败
  static Future<void> _walk(
    Directory dir,
    Future<void> Function(File file, String relative) onFile, {
    String? rootPath,
    bool flat = false,
  }) async {
    final root = rootPath ?? dir.path;
    List<FileSystemEntity> entries;
    try {
      // toList 才会真正触发 IO，权限错误在这里被吞掉
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      final name = entity.path.split('/').last;
      if (entity is Directory) {
        if (flat) continue;
        if (_skipDirNames.contains(name)) continue;
        await _walk(entity, onFile, rootPath: root, flat: flat);
      } else if (entity is File) {
        final relative = entity.path.substring(root.length + 1);
        try {
          await onFile(entity, relative);
        } catch (_) {
          // 单个文件读不了（被占用、权限不足）跳过，不影响其它文件
        }
      }
    }
  }

  static Future<int> _countFiles(Directory dir, {bool flat = false}) async {
    var count = 0;
    await _walk(dir, (file, relative) async {
      count++;
    }, flat: flat);
    return count;
  }

  static Future<void> _writeManifest(BackupEntry entry) async {
    try {
      final manifest = File('${entry.file.path}.json');
      await manifest.writeAsString(jsonEncode({
        'name': entry.name,
        'bytes': entry.sizeBytes,
        'created_at': entry.createdAt.toIso8601String(),
        'targets': targets.map((t) => t.archivePath).toList(),
      }));
    } catch (_) {}
  }

  /// 列出全部备份
  static Future<List<BackupEntry>> listBackups() async {
    final entries = <BackupEntry>[];
    try {
      if (!await backupDir.exists()) return entries;
      await for (final entity in backupDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_prefix) || !name.endsWith(_ext)) continue;
        final stat = await entity.stat();
        entries.add(BackupEntry(
          file: entity,
          sizeBytes: stat.size,
          createdAt: stat.modified,
        ));
      }
    } catch (e) {
      Log.e('读取备份列表失败: $e', tag: 'Backup');
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  /// 恢复到当前环境
  /// Restore an archive into the current environment
  ///
  /// 步骤：先自动备份一份当前状态 → 解压到临时目录 → 逐项替换 → 失败回滚
  static Future<void> restore(
    File archive, {
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (!await archive.exists()) {
      throw StateError('备份文件不存在');
    }
    if (_busy) {
      throw StateError('已有一个备份/恢复任务在执行');
    }
    _busy = true;
    final tmp = Directory('${backupDir.path}/$_restoreTmpName');
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
    await tmp.create(recursive: true);

    try {
      onProgress?.call('正在校验归档…', 0.05);
      var count = 0;
      final reader = TarReader(archive.openRead());
      while (await reader.moveNext()) {
        final entry = reader.current;
        final name = entry.header.name;
        if (name.isEmpty || name.contains('..')) continue;
        final outFile = File('${tmp.path}/$name');
        await outFile.parent.create(recursive: true);
        await entry.contents.pipe(outFile.openWrite());
        count++;
        if (count % 20 == 0) {
          onProgress?.call('正在解包（$count）', 0.05 + (count % 100) / 500);
        }
      }
      if (count == 0) {
        throw StateError('归档里没有可恢复的文件');
      }

      onProgress?.call('正在备份当前状态…', 0.6);
      try {
        // 这里已经持有 _busy，不能再走 createBackup（会被自己的锁挡住）；
        // 快照标成 auto，避免反复恢复把手动备份的名额挤光
        await _createBackupInternal(targets, auto: true);
      } catch (e) {
        Log.w('恢复前自动备份失败，继续恢复: $e', tag: 'Backup');
      }

      onProgress?.call('正在替换文件…', 0.7);
      for (final target in targets) {
        final staged = Directory('${tmp.path}/${target.archivePath}');
        if (!await staged.exists()) continue;
        final live = Directory(target.sourcePath);
        // 直接覆盖复制，绝不搬动整个目录。
        // 以前是先 rename 原目录、成功后删副本：一旦删除中途失败（比如 rootfs
        // 正被 proot 占着），回滚拿回来的是个残缺目录，设置文件和 bin 就这么没了。
        // 「应用设置」这一项的 sourcePath 是整个 files 目录，搬它等于搬走整套环境。
        await _copyDirectory(staged, live);
      }
      onProgress?.call('恢复完成', 1);
      await StatusTimeline.instance.record(
        'backup',
        'restore_done',
        '已从 ${archive.uri.pathSegments.last} 恢复配置与数据',
        level: TimelineLevel.success,
        dedupe: false,
      );
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
      _busy = false;
    }
  }

  static Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await _walk(from, (entity, relative) async {
      final target = File('${to.path}/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    });
  }

  static Future<void> delete(BackupEntry entry, {bool quiet = false}) async {
    try {
      if (await entry.file.exists()) await entry.file.delete();
      final manifest = File('${entry.file.path}.json');
      if (await manifest.exists()) await manifest.delete();
      if (!quiet) {
        await StatusTimeline.instance.record(
          'backup',
          'backup_deleted',
          '已删除备份 ${entry.name}',
        );
      }
    } catch (e) {
      Log.e('删除备份失败: $e', tag: 'Backup');
      rethrow;
    }
  }

  /// 导出到用户选择的路径
  static Future<void> exportTo(BackupEntry entry, String destination) async {
    final target = File(destination);
    await target.parent.create(recursive: true);
    await entry.file.copy(target.path);
  }

  /// 从外部文件导入（复制进备份目录）
  static Future<BackupEntry> importFrom(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('选择的文件不存在');
    }
    await backupDir.create(recursive: true);
    final name = source.uri.pathSegments.last;
    final safeName = name.startsWith(_prefix) ? name : '$_prefix$name';
    final target = File('${backupDir.path}/$safeName');
    if (await target.exists()) {
      await target.delete();
    }
    await source.copy(target.path);
    final stat = await target.stat();
    await StatusTimeline.instance.record(
      'backup',
      'backup_imported',
      '已导入备份 $safeName',
      level: TimelineLevel.success,
    );
    return BackupEntry(
      file: target,
      sizeBytes: stat.size,
      createdAt: stat.modified,
    );
  }

  /// 手动备份的保留策略：只留最近 N 份手动备份，
  /// 自动备份归 [pruneAuto] 管，两边互不挤占。
  static Future<void> prune({int keep = 10}) async {
    final entries = (await listBackups())
        .where((entry) => !entry.name.contains(_autoTag))
        .toList();
    if (entries.length <= keep) return;
    for (final entry in entries.sublist(keep)) {
      try {
        await delete(entry, quiet: true);
      } catch (_) {}
    }
  }

  /// 自动备份单独的保留策略：只清理带 `-auto` 标记的归档，
  /// 手动备份永远不会被自动清掉。返回清理掉的数量。
  static Future<int> pruneAuto({int keep = 5}) async {
    final entries = (await listBackups())
        .where((entry) => entry.name.contains(_autoTag))
        .toList();
    if (entries.length <= keep) return 0;
    var removed = 0;
    for (final entry in entries.sublist(keep)) {
      try {
        await delete(entry, quiet: true);
        removed++;
      } catch (_) {}
    }
    return removed;
  }
}
