import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config/stream_settings.dart';

const MethodChannel _storageChannel = MethodChannel('sputni/storage');

Future<Directory> resolveRecordingDirectory(StreamSettings settings) async {
  switch (settings.recordingDirectoryMode) {
    case RecordingDirectoryMode.documents:
      final baseDirectory = await getApplicationDocumentsDirectory();
      return Directory(
        '${baseDirectory.path}${Platform.pathSeparator}SputniRecordings',
      );
    case RecordingDirectoryMode.appSupport:
      final baseDirectory = await getApplicationSupportDirectory();
      return Directory(
        '${baseDirectory.path}${Platform.pathSeparator}SputniRecordings',
      );
    case RecordingDirectoryMode.temporary:
      final baseDirectory = await getTemporaryDirectory();
      return Directory(
        '${baseDirectory.path}${Platform.pathSeparator}SputniRecordings',
      );
    case RecordingDirectoryMode.custom:
      final customPath = settings.customRecordingDirectoryPath?.trim();
      if (customPath != null && customPath.isNotEmpty) {
        return Directory(customPath);
      }

      final fallbackDirectory = await getApplicationDocumentsDirectory();
      return Directory(
        '${fallbackDirectory.path}${Platform.pathSeparator}SputniRecordings',
      );
  }
}

bool requiresAndroidScopedRecordingSave(StreamSettings settings) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }

  return settings.recordingDirectoryMode == RecordingDirectoryMode.custom &&
      (settings.customRecordingDirectoryUri?.trim().isNotEmpty ?? false);
}

Future<Directory> resolveRecordingWorkingDirectory(
    StreamSettings settings) async {
  if (requiresAndroidScopedRecordingSave(settings)) {
    final baseDirectory = await getTemporaryDirectory();
    return Directory(
      '${baseDirectory.path}${Platform.pathSeparator}SputniRecordings',
    );
  }

  return resolveRecordingDirectory(settings);
}

Future<String> finalizeRecordingPath({
  required StreamSettings settings,
  required String currentPath,
}) async {
  if (!requiresAndroidScopedRecordingSave(settings)) {
    return currentPath;
  }

  final treeUri = settings.customRecordingDirectoryUri?.trim();
  if (treeUri == null || treeUri.isEmpty) {
    return currentPath;
  }

  final fileName = File(currentPath).uri.pathSegments.isNotEmpty
      ? File(currentPath).uri.pathSegments.last
      : currentPath.split(Platform.pathSeparator).last;

  final savedRecording = await _storageChannel.invokeMapMethod<String, dynamic>(
    'copyRecordingToDirectory',
    {
      'sourcePath': currentPath,
      'treeUri': treeUri,
      'fileName': fileName,
    },
  );

  final savedPath = savedRecording?['path'] as String?;
  if (savedPath == null || savedPath.trim().isEmpty) {
    throw StateError('Unable to save recording to the selected folder.');
  }

  final recordedFile = File(currentPath);
  if (await recordedFile.exists()) {
    await recordedFile.delete();
  }

  return savedPath.trim();
}
