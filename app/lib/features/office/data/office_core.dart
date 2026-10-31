import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:monastack/features/office/world/office_map.dart';
import 'package:monastack/platform/bridge/api/office.dart';
import 'package:monastack/platform/core_bridge.dart';

export 'package:monastack/platform/bridge/api/office.dart'
    show Cell, OfficeCore;

/// Validated office map and seed policy owned by the Rust core. The provider
/// disposes the native handle when it is no longer watched.
final officeCoreProvider = FutureProvider<OfficeCore>((ref) async {
  try {
    await CoreBridge.ensureInitialized();
    final core = await OfficeCore.load(
      seedJson: await rootBundle.loadString('assets/seed.v1.json'),
      mapJson: await rootBundle.loadString(mapAsset),
    );
    ref.onDispose(core.dispose);
    return core;
  } catch (e) {
    // Bridge and asset errors carry no workspace records.
    debugPrint('Rust core failed to load: $e');
    rethrow;
  }
});
