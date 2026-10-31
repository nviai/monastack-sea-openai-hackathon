import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'package:monastack/platform/bridge/api.dart';
import 'package:monastack/platform/bridge/frb_generated.dart';
import 'package:monastack/platform/native_library.dart';

export 'package:monastack/platform/bridge/api.dart'
    show CoreError, CoreErrorKind;

/// Bridge signature version this Dart code was generated against.
const expectedBridgeVersion = 2;

/// Loads the Rust core into the current isolate once. Generated calls run on
/// Rust worker threads and never block the UI isolate.
abstract final class CoreBridge {
  static Future<void>? _ready;

  static Future<void> ensureInitialized() =>
      _ready ??= _initialize().catchError((Object error, StackTrace stack) {
        _ready = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<void> _initialize() async {
    await CoreLib.init(
      externalLibrary: ExternalLibrary.open(nativeLibraryPath()),
    );
    final version = bridgeVersion();
    if (version != expectedBridgeVersion) {
      CoreLib.dispose();
      throw StateError(
        'Rust core bridge v$version does not match app v$expectedBridgeVersion',
      );
    }
  }
}
