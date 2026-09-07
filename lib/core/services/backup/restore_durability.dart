import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

abstract interface class RestoreDurability {
  Future<void> restrictFile(File file);

  Future<void> restrictDirectory(Directory directory);

  Future<void> syncFile(File file, {bool fullBarrier = false});

  Future<void> syncDirectory(Directory directory, {bool fullBarrier = false});

  Future<void> renameAndSync({
    required FileSystemEntity source,
    required String targetPath,
  });
}

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _FdCallNative = Int32 Function(Int32);
typedef _FdCallDart = int Function(int);
typedef _FcntlNative = Int32 Function(Int32, Int32);
typedef _FcntlDart = int Function(int, int);
typedef _ChmodNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

final class RestorePlatformDurability implements RestoreDurability {
  RestorePlatformDurability()
    : _library = DynamicLibrary.process(),
      _isApple = Platform.isMacOS {
    _open = _library.lookupFunction<_OpenNative, _OpenDart>('open');
    _fsync = _library.lookupFunction<_FdCallNative, _FdCallDart>('fsync');
    _close = _library.lookupFunction<_FdCallNative, _FdCallDart>('close');
    _fcntl = _library.lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
    _chmod = _library.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
    final errnoSymbol = Platform.isAndroid
        ? '__errno'
        : _isApple
        ? '__error'
        : '__errno_location';
    _errno = _library.lookupFunction<_ErrnoNative, _ErrnoDart>(errnoSymbol);
  }

  static const _eintr = 4;
  static const _oReadWrite = 2;
  static const _fFullFsync = 51;

  final DynamicLibrary _library;
  final bool _isApple;
  late final _OpenDart _open;
  late final _FdCallDart _fsync;
  late final _FdCallDart _close;
  late final _FcntlDart _fcntl;
  late final _ChmodDart _chmod;
  late final _ErrnoDart _errno;

  // arm and arm64 define their own O_DIRECTORY/O_NOFOLLOW instead of the
  // asm-generic values; on arm64 the generic O_DIRECTORY is O_DIRECT.
  bool get _usesArmOpenFlags {
    final abi = Abi.current();
    return abi == Abi.androidArm ||
        abi == Abi.androidArm64 ||
        abi == Abi.linuxArm ||
        abi == Abi.linuxArm64;
  }

  int get _oDirectory => _isApple
      ? 0x00100000
      : _usesArmOpenFlags
      ? 0x00004000
      : 0x00010000;
  int get _oNoFollow => _isApple
      ? 0x00000100
      : _usesArmOpenFlags
      ? 0x00008000
      : 0x00020000;
  int get _oCloseOnExec => _isApple ? 0x01000000 : 0x00080000;
  int get _lastError => _errno().value;

  @override
  Future<void> restrictFile(File file) =>
      _restrictPath(file, expectedType: FileSystemEntityType.file, mode: 0x180);

  @override
  Future<void> restrictDirectory(Directory directory) => _restrictPath(
    directory,
    expectedType: FileSystemEntityType.directory,
    mode: 0x1c0,
  );

  Future<void> _restrictPath(
    FileSystemEntity entity, {
    required FileSystemEntityType expectedType,
    required int mode,
  }) async {
    if (await FileSystemEntity.type(entity.path, followLinks: false) !=
        expectedType) {
      throw FileSystemException('restore_durability_path_type', entity.path);
    }
    final nativePath = entity.absolute.path.toNativeUtf8();
    try {
      _callWithEintrRetry(
        () => _chmod(nativePath, mode),
        operation: 'chmod',
        path: entity.path,
      );
    } finally {
      malloc.free(nativePath);
    }
    final actualMode = (await entity.stat()).mode & 0x1ff;
    if (actualMode != mode) {
      throw FileSystemException(
        'restore_durability_mode:$actualMode',
        entity.path,
      );
    }
  }

  @override
  Future<void> syncFile(File file, {bool fullBarrier = false}) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('restore_durability_file_type', file.path);
    }
    final fd = _openPath(
      file.absolute.path,
      _oReadWrite | _oNoFollow | _oCloseOnExec,
    );
    Object? operationError;
    try {
      _callWithEintrRetry(
        () => _fsync(fd),
        operation: 'fsync',
        path: file.path,
      );
      if (fullBarrier && _isApple) {
        _callWithEintrRetry(
          () => _fcntl(fd, _fFullFsync),
          operation: 'fullfsync',
          path: file.path,
        );
      }
    } catch (error) {
      operationError = error;
      rethrow;
    } finally {
      _closeDescriptor(fd, path: file.path, priorError: operationError);
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('restore_durability_file_changed', file.path);
    }
  }

  @override
  Future<void> syncDirectory(
    Directory directory, {
    bool fullBarrier = false,
  }) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'restore_durability_directory_type',
        directory.path,
      );
    }
    final fd = _openPath(
      directory.absolute.path,
      _oDirectory | _oNoFollow | _oCloseOnExec,
    );
    Object? operationError;
    try {
      _callWithEintrRetry(
        () => _fsync(fd),
        operation: 'fsync_directory',
        path: directory.path,
      );
      if (fullBarrier && _isApple) {
        _callWithEintrRetry(
          () => _fcntl(fd, _fFullFsync),
          operation: 'fullfsync_directory',
          path: directory.path,
        );
      }
    } catch (error) {
      operationError = error;
      rethrow;
    } finally {
      _closeDescriptor(fd, path: directory.path, priorError: operationError);
    }
  }

  @override
  Future<void> renameAndSync({
    required FileSystemEntity source,
    required String targetPath,
  }) async {
    final sourcePath = source.absolute.path;
    final target = p.absolute(targetPath);
    final sourceType = await FileSystemEntity.type(
      sourcePath,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.file &&
        sourceType != FileSystemEntityType.directory) {
      throw FileSystemException('restore_durability_source_type', sourcePath);
    }
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('restore_durability_target_exists', target);
    }

    if (sourceType == FileSystemEntityType.file) {
      await File(sourcePath).rename(target);
    } else {
      await Directory(sourcePath).rename(target);
    }
    await _requireRenameResult(
      sourcePath: sourcePath,
      targetPath: target,
      expectedType: sourceType,
    );
    final sourceParent = Directory(p.dirname(sourcePath));
    final targetParent = Directory(p.dirname(target));
    await syncDirectory(targetParent, fullBarrier: true);
    if (!p.equals(sourceParent.absolute.path, targetParent.absolute.path)) {
      await syncDirectory(sourceParent, fullBarrier: true);
    }
  }

  int _openPath(String path, int flags) {
    final nativePath = path.toNativeUtf8();
    try {
      while (true) {
        final fd = _open(nativePath, flags);
        if (fd >= 0) return fd;
        final error = _lastError;
        if (error != _eintr) {
          throw FileSystemException('restore_durability_open:$error', path);
        }
      }
    } finally {
      malloc.free(nativePath);
    }
  }

  void _callWithEintrRetry(
    int Function() action, {
    required String operation,
    required String path,
  }) {
    while (true) {
      if (action() == 0) return;
      final error = _lastError;
      if (error != _eintr) {
        throw FileSystemException('restore_durability_$operation:$error', path);
      }
    }
  }

  void _closeDescriptor(
    int fd, {
    required String path,
    required Object? priorError,
  }) {
    if (_close(fd) != 0 && priorError == null) {
      throw FileSystemException('restore_durability_close:$_lastError', path);
    }
  }
}

Future<void> _requireRenameResult({
  required String sourcePath,
  required String targetPath,
  required FileSystemEntityType expectedType,
}) async {
  if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
          FileSystemEntityType.notFound ||
      await FileSystemEntity.type(targetPath, followLinks: false) !=
          expectedType) {
    throw FileSystemException(
      'restore_durability_rename_result:$targetPath',
      sourcePath,
    );
  }
}
