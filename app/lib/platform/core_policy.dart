import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:monastack/platform/native_library.dart';

/// Map and room-policy calls into the bundled Rust core.
class Policy {
  final DynamicLibrary library = DynamicLibrary.open(nativeLibraryPath());
  List<List<int>>? path(
    Map<String, dynamic> seed,
    String actor,
    List<int> start,
    List<int> goal, {
    List<String>? allowedRooms,
  }) {
    final call = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)
        >('monastack_path_v1');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('monastack_free_v1');
    final input = jsonEncode({
      'seed': seed,
      'actor': actor,
      'start': start,
      'goal': goal,
      'allowed_rooms': allowedRooms,
    }).toNativeUtf8();
    try {
      final result = call(input);
      if (result == nullptr) return null;
      try {
        final raw =
            (jsonDecode(result.toDartString()) as Map<String, dynamic>)['path'];
        return raw == null
            ? null
            : (raw as List).map((p) => (p as List).cast<int>()).toList();
      } finally {
        free(result);
      }
    } finally {
      malloc.free(input);
    }
  }

  bool allows(Map<String, dynamic> seed, String actor, String room) {
    final call = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)
        >('monastack_policy_v1');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('monastack_free_v1');
    final input = jsonEncode({
      'seed': seed,
      'tenant': 'nviai',
      'actor': actor,
      'room': room,
    }).toNativeUtf8();
    try {
      final result = call(input);
      if (result == nullptr) return false;
      try {
        return (jsonDecode(result.toDartString())
                as Map<String, dynamic>)['ok'] ==
            true;
      } finally {
        free(result);
      }
    } finally {
      malloc.free(input);
    }
  }
}
