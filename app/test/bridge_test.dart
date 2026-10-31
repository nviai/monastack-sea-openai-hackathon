import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/main.dart';

void main() {
  test('native Rust bridge enforces room membership', () {
    final seed = jsonDecode(
      File('assets/seed.v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final policy = Policy();
    expect(policy.allows(seed, 'van', 'finance'), isTrue);
    expect(policy.allows(seed, 'an', 'finance'), isFalse);
    expect(policy.allows(seed, 'van', 'hr'), isFalse);
    expect(policy.path(seed, 'an', [2, 2], [2, 14]), isNull);
    expect(
      policy.path(
        seed,
        'an',
        [2, 2],
        [2, 14],
        allowedRooms: ['lobby', 'finance'],
      ),
      isNotNull,
    );
    expect(
      policy.path(
        seed,
        'unknown',
        [2, 2],
        [2, 14],
        allowedRooms: ['lobby', 'finance'],
      ),
      isNull,
    );
    final route = policy.path(seed, 'van', [2, 2], [2, 14]);
    expect(route!.first, [2, 2]);
    expect(route.last, [2, 14]);
    expect(
      policy.path(seed, 'van', [2, 2], [2, 14], allowedRooms: ['lobby']),
      isNull,
    );
    expect(policy.path(seed, 'an', [2, 2], [0, 0]), isNull);
  });
}
