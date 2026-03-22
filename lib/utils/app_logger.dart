import 'dart:developer' as developer;

abstract final class AppLogger {
  static void info(String message) {
    developer.log(message, name: 'Sputni');
  }

  static void error(String message, Object error, [StackTrace? stackTrace]) {
    developer.log(
      message,
      name: 'Sputni',
      error: error,
      stackTrace: stackTrace,
      level: 1000,
    );
  }
}
