import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';

void main() {
  group('Assistant.enableMemory', () {
    test('is off by default', () {
      const a = Assistant(id: 'a', name: 'A');
      expect(a.enableMemory, isFalse);
      expect(a.appendCurrentTimeToUserMessage, isFalse);
    });

    test('round-trips through JSON', () {
      const a = Assistant(id: 'a', name: 'A', enableMemory: true);
      expect(a.toJson()['enableMemory'], isTrue);
      expect(Assistant.fromJson(a.toJson()).enableMemory, isTrue);
    });

    test('a payload without the key falls back to off', () {
      final a = Assistant.fromJson({'id': 'a', 'name': 'A'});
      expect(a.enableMemory, isFalse);
    });
  });
}
