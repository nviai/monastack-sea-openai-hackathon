import 'dart:io';

String nativeLibraryPath() {
  final bundled =
      '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libmonastack_core.dylib';
  if (File(bundled).existsSync()) return bundled;
  return Platform.environment['MONASTACK_CORE'] ??
      '../core/target/debug/libmonastack_core.dylib';
}
