import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:monastack/platform/bridge/api/office.dart';
import 'package:monastack/platform/core_bridge.dart';

export 'package:monastack/platform/bridge/api/office.dart'
    show Cell, OfficeCore;

/// Validated office map and seed policy owned by the Rust core. The provider
/// disposes the native handle when it is no longer watched.
final officeCoreProvider = FutureProvider<OfficeCore>((ref) async {
  await CoreBridge.ensureInitialized();
  final core = await OfficeCore.load(
    seedJson: await rootBundle.loadString('assets/seed.v1.json'),
    mapJson: await rootBundle.loadString('assets/map.v1.json'),
  );
  ref.onDispose(core.dispose);
  return core;
});
