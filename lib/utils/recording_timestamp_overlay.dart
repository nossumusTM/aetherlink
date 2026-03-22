import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';

Future<String> burnRecordingDateTimeOverlay({
  required String currentPath,
  required DateTime recordingStartedAt,
}) async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    return currentPath;
  }

  final sourceFile = File(currentPath);
  if (!await sourceFile.exists()) {
    return currentPath;
  }

  final tempOutputPath =
      '${sourceFile.parent.path}${Platform.pathSeparator}${sourceFile.uri.pathSegments.last}.timestamped.mp4';
  final tempSourceBackupPath =
      '${sourceFile.parent.path}${Platform.pathSeparator}${sourceFile.uri.pathSegments.last}.source';
  final tempOutputFile = File(tempOutputPath);
  final tempSourceBackupFile = File(tempSourceBackupPath);

  try {
    if (await tempOutputFile.exists()) {
      await tempOutputFile.delete();
    }
    if (await tempSourceBackupFile.exists()) {
      await tempSourceBackupFile.delete();
    }

    await _configureDrawTextFonts();

    final startEpochMicros = recordingStartedAt.millisecondsSinceEpoch * 1000;
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      currentPath,
      '-vf',
      _buildDrawTextFilter(startEpochMicros),
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '18',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      '-c:a',
      'copy',
      tempOutputPath,
    ]);

    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode) ||
        !await tempOutputFile.exists() ||
        await tempOutputFile.length() == 0) {
      final logs = await session.getAllLogsAsString();
      AppLogger.info(
        'Skipping recording timestamp burn-in for $currentPath. FFmpeg result: '
        '${returnCode?.getValue()} ${logs ?? ''}',
      );
      if (await tempOutputFile.exists()) {
        await tempOutputFile.delete();
      }
      return currentPath;
    }

    await sourceFile.rename(tempSourceBackupPath);

    try {
      await tempOutputFile.rename(currentPath);
    } catch (_) {
      await tempOutputFile.copy(currentPath);
      await tempOutputFile.delete();
    }

    if (await tempSourceBackupFile.exists()) {
      await tempSourceBackupFile.delete();
    }
    return currentPath;
  } catch (error, stackTrace) {
    AppLogger.error(
      'Unable to burn recording timestamp overlay',
      error,
      stackTrace,
    );

    if (!await sourceFile.exists() && await tempSourceBackupFile.exists()) {
      try {
        await tempSourceBackupFile.rename(currentPath);
      } catch (restoreError, restoreStackTrace) {
        AppLogger.error(
          'Unable to restore source recording after timestamp failure',
          restoreError,
          restoreStackTrace,
        );
      }
    }

    if (await tempOutputFile.exists()) {
      await tempOutputFile.delete();
    }

    return currentPath;
  }
}

String _buildDrawTextFilter(int startEpochMicros) {
  return "drawtext="
      "text='%Y-%m-%d %H\\:%M\\:%S':"
      "expansion=strftime:"
      "basetime=$startEpochMicros:"
      "x=18:"
      "y=18:"
      "fontsize=h/20:"
      "fontcolor=white:"
      "box=1:"
      "boxcolor=black@0.45:"
      "boxborderw=14";
}

Future<void> _configureDrawTextFonts() async {
  final fontDirectories = <String>[
    if (Platform.isAndroid) '/system/fonts',
    if (Platform.isIOS) '/System/Library/Fonts',
    if (Platform.isIOS) '/System/Library/Fonts/Core',
    if (Platform.isIOS) '/System/Library/Fonts/CoreUI',
  ];

  if (fontDirectories.isEmpty) {
    return;
  }

  await FFmpegKitConfig.setFontDirectoryList(fontDirectories);
}
