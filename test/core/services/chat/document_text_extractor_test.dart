import 'dart:io';

import 'package:Kelivo/core/services/chat/document_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('kelivo_extract_'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  Future<String> extract(File file, String mime) =>
      DocumentTextExtractor.extractResolved(path: file.path, mime: mime);

  test('binary files are not decoded into prompt text', () async {
    final file = File('${directory.path}/app.apk')
      ..writeAsBytesSync([0x50, 0x4b, 3, 4, 0, 1]);
    expect(
      await extract(file, 'application/vnd.android.package-archive'),
      '[[Binary file cannot be read as text: app.apk]]',
    );
  });

  test('large files are not read into memory', () async {
    final file = File('${directory.path}/large.log');
    final handle = file.openSync(mode: FileMode.write)
      ..truncateSync(64 * 1024 * 1024);
    handle.closeSync();
    expect(
      await extract(file, 'text/plain'),
      '[[File too large to read as text: large.log]]',
    );
  });

  test('CJK text survives a UTF-8 sequence cut by the probe', () async {
    final expected = '文件内容' * 2000;
    final file = File('${directory.path}/notes.txt')
      ..writeAsStringSync(expected);
    expect(await extract(file, 'text/plain'), expected);
  });
}
