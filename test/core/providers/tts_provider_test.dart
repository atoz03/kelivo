import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/providers/tts_provider.dart';
import 'package:Kelivo/core/services/tts/network_tts.dart';
import 'package:Kelivo/core/services/tts/tts_playback_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../support/business_preferences_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const channel = MethodChannel('flutter_tts');
  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const audioChannel = MethodChannel('xyz.luan/audioplayers');
  late Set<String> audioEventChannels;
  late int speakCallCount;
  late List<String> spokenTexts;
  late String? audioPlayerEventChannel;
  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;
  var networkSources = 0;

  setUp(() async {
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
    networkSources = 0;
    audioEventChannels = <String>{};
    speakCallCount = 0;
    spokenTexts = <String>[];
    audioPlayerEventChannel = null;
    _mockAudioEventStream('xyz.luan/audioplayers.global/events');
    audioEventChannels.add('xyz.luan/audioplayers.global/events');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (call) async {
          final args = call.arguments as Map<dynamic, dynamic>;
          final playerId = args['playerId'] as String;
          final eventChannel = 'xyz.luan/audioplayers/events/$playerId';
          if (call.method == 'create') {
            audioPlayerEventChannel = eventChannel;
            _mockAudioEventStream(eventChannel);
            audioEventChannels.add(eventChannel);
          } else if (call.method == 'setSourceUrl') {
            networkSources++;
            scheduleMicrotask(() {
              unawaited(
                _emitAudioEvent(eventChannel, {
                  'event': 'audio.onPrepared',
                  'value': true,
                }),
              );
            });
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getLanguages':
              return const <String>['en-US', 'zh-CN'];
            case 'getEngines':
              return const <String>['test-tts'];
            case 'isLanguageAvailable':
              return true;
            case 'speak':
              speakCallCount++;
              final arguments = call.arguments;
              final text = arguments is Map
                  ? arguments['text']?.toString()
                  : arguments?.toString();
              spokenTexts.add(text ?? '');
              await _emitTtsCallback('speak.onStart');
              return 1;
            case 'stop':
              await _emitTtsCallback('speak.onComplete');
              return 1;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, null);
    for (final channelName in audioEventChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(channelName, null);
    }
    return harness.dispose();
  });

  test('maps network audio MIME types to matching file extensions', () {
    expect(ttsAudioFileExtensionForMime('audio/mpeg'), 'mp3');
    expect(ttsAudioFileExtensionForMime('audio/wav'), 'wav');
    expect(ttsAudioFileExtensionForMime('audio/flac'), 'flac');
    expect(ttsAudioFileExtensionForMime('audio/pcm'), 'pcm');
  });

  test(
    'changing system TTS speed keeps the current playback position',
    () async {
      final provider = TtsProvider(preferences: session.preferences);
      addTearDown(provider.dispose);

      await _waitUntil(() => provider.isAvailable);

      final text = List.filled(240, 'a').join();
      unawaited(provider.speakSystem(text));
      await _waitUntil(
        () => provider.playbackState.status == TtsPlaybackStatus.playing,
      );

      await _emitTtsCallback('speak.onProgress', {
        'text': text,
        'start': 0,
        'end': 80,
        'word': 'a',
      });
      final beforeSpeedChange = provider.playbackState.position;
      expect(beforeSpeedChange, greaterThan(Duration.zero));
      expect(beforeSpeedChange, lessThan(provider.playbackState.duration));

      await provider.setPlaybackSpeed(1.2);

      expect(provider.playbackState.status, isNot(TtsPlaybackStatus.ended));
      expect(provider.playbackState.position, beforeSpeedChange);
    },
  );

  test(
    'finished system TTS can be replayed from the floating player',
    () async {
      final provider = TtsProvider(preferences: session.preferences);
      addTearDown(provider.dispose);

      await _waitUntil(() => provider.isAvailable);

      unawaited(provider.speakSystem('hello again'));
      await _waitUntil(
        () => provider.playbackState.status == TtsPlaybackStatus.playing,
      );
      await _emitTtsCallback('speak.onComplete');
      await _waitUntil(
        () => provider.playbackState.status == TtsPlaybackStatus.ended,
      );

      expect(provider.playbackState.isActive, isFalse);
      expect(provider.playbackState.isPlayerVisible, isTrue);
      final callsBeforeReplay = speakCallCount;

      unawaited(provider.togglePause());
      await _waitUntil(
        () =>
            provider.playbackState.status == TtsPlaybackStatus.playing &&
            speakCallCount == callsBeforeReplay + 1,
      );

      expect(spokenTexts.last, 'hello again');
      expect(provider.playbackState.position, Duration.zero);
    },
  );

  test('system TTS strips supported Markdown code ranges', () async {
    final provider = TtsProvider(preferences: session.preferences);
    addTearDown(provider.dispose);

    await _waitUntil(() => provider.isAvailable);

    unawaited(
      provider.speakSystem(
        '保留\n'
        '``print("行内代码")``\n'
        '~~~dart\n'
        'print("波浪线围栏");\n'
        '~~~\n'
        '```dart\n'
        'print("未闭合围栏");',
      ),
    );
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.playing,
    );

    expect(spokenTexts.last, '保留');
  });

  for (final kind in [NetworkTtsKind.openai, NetworkTtsKind.mimo]) {
    for (final replaceSession in [false, true]) {
      test(
        '${kind.name} prefetch cancellation is handled after '
        '${replaceSession ? 'starting another session' : 'stopping'}',
        () async {
          final provider = TtsProvider(preferences: session.preferences);
          addTearDown(provider.dispose);
          await _waitUntil(() => provider.isAvailable);
          final requests = <HttpRequest>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            await request.drain<void>();
            requests.add(request);
          });
          final baseUrl = 'http://${server.address.address}:${server.port}/v1';
          final TtsServiceOptions service = kind == NetworkTtsKind.mimo
              ? MimoTtsOptions(
                  enabled: true,
                  name: 'test',
                  apiKey: '',
                  baseUrl: baseUrl,
                  model: 'mimo-v2.5-tts',
                  voice: 'mimo_default',
                )
              : OpenAiTtsOptions(
                  enabled: true,
                  name: 'test',
                  apiKey: '',
                  baseUrl: baseUrl,
                  model: 'tts',
                  voice: 'alloy',
                );
          unawaited(
            provider.speakWithNetworkService(
              service,
              List.filled(650, 'a').join(),
            ),
          );
          await _waitUntil(() => requests.length == 3);

          if (replaceSession) {
            await provider.speak(
              'replacement session',
              waitForCompletion: false,
            );
            await _waitUntil(
              () => provider.playbackState.status == TtsPlaybackStatus.playing,
            );
          } else {
            await provider.stop();
          }
          for (final request in requests) {
            request.response.add([1, 2, 3, 4]);
            await request.response.close();
          }
          // Let the cancelled synthesis futures settle, including the two
          // prefetched chunks that the playback queue will never await.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(networkSources, 0);
          expect(provider.error, isNull);
          expect(
            provider.playbackState.status,
            replaceSession ? TtsPlaybackStatus.playing : TtsPlaybackStatus.idle,
          );
          await provider.stop();
        },
      );
    }
  }

  test('prefetch failures remain available to the playback queue', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_tts_prefetch_error_',
    );
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(directory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPaths;
      await directory.delete(recursive: true);
    });
    final provider = TtsProvider(preferences: session.preferences);
    addTearDown(provider.dispose);
    await _waitUntil(() => provider.isAvailable);
    final requests = <String, HttpRequest>{};
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      requestCount++;
      requests[(body['input'] as String)[0]] = request;
    });
    final playback = provider.speakWithNetworkService(
      OpenAiTtsOptions(
        enabled: true,
        name: 'test',
        apiKey: '',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'tts',
        voice: 'alloy',
      ),
      ['a', 'b', 'c'].map((letter) => List.filled(220, letter).join()).join(),
    );
    await _waitUntil(() => requests.length == 3);
    for (final letter in ['b', 'c']) {
      requests[letter]!.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..write('temporary provider failure');
      await requests[letter]!.response.close();
    }
    // The future must handle an error even before its chunk is consumed.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(provider.playbackState.status, TtsPlaybackStatus.buffering);
    expect(provider.error, isNull);

    requests['a']!.response.add([1, 2, 3, 4]);
    await requests['a']!.response.close();
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.playing,
    );
    await _emitAudioEvent(audioPlayerEventChannel!, {
      'event': 'audio.onComplete',
    });
    await playback;
    expect(provider.playbackState.status, TtsPlaybackStatus.error);
    expect(provider.error, contains('503'));
    expect(provider.error, contains('temporary provider failure'));
    expect(networkSources, 1);
    expect(requestCount, 3);
  });

  test('network replay uses cached audio only when enabled', () async {
    final originalPathProvider = PathProviderPlatform.instance;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'kelivo_tts_replay_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      tempDirectory.path,
    );
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      await tempDirectory.delete(recursive: true);
    });

    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestCount++;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.ok;
      request.response.add(const <int>[1, 2, 3]);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final provider = TtsProvider(preferences: session.preferences);
    addTearDown(provider.dispose);
    await _waitUntil(() => provider.isAvailable);

    expect(provider.cacheNetworkAudioForReplay, isFalse);
    await provider.setCacheNetworkAudioForReplay(true);
    expect(
      session.preferences.getBool('tts_cache_network_audio_for_replay_v1'),
      isTrue,
    );

    final service = OpenAiTtsOptions(
      enabled: true,
      name: 'Local TTS',
      apiKey: 'test-key',
      baseUrl: 'http://${server.address.address}:${server.port}/v1',
      model: 'test-model',
      voice: 'alloy',
    );
    unawaited(provider.speakWithNetworkService(service, 'hello network'));
    await _waitUntil(
      () =>
          requestCount == 1 &&
          provider.playbackState.status == TtsPlaybackStatus.playing,
    );
    await _emitAudioEvent(audioPlayerEventChannel!, {
      'event': 'audio.onComplete',
    });
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.ended,
    );

    unawaited(provider.togglePause());
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.playing,
    );
    expect(requestCount, 1);
    await _emitAudioEvent(audioPlayerEventChannel!, {
      'event': 'audio.onComplete',
    });
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.ended,
    );

    await provider.setCacheNetworkAudioForReplay(false);
    unawaited(provider.togglePause());
    await _waitUntil(
      () =>
          requestCount == 2 &&
          provider.playbackState.status == TtsPlaybackStatus.playing,
    );
    await _emitAudioEvent(audioPlayerEventChannel!, {
      'event': 'audio.onComplete',
    });
    await _waitUntil(
      () => provider.playbackState.status == TtsPlaybackStatus.ended,
    );
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for TTS provider condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _emitTtsCallback(String method, [dynamic arguments]) async {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  final completer = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter_tts', data, (_) => completer.complete());
  await completer.future;
}

Future<void> _emitAudioEvent(String channel, Map<String, dynamic> event) async {
  final data = const StandardMethodCodec().encodeSuccessEnvelope(event);
  final completer = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel, data, (_) => completer.complete());
  await completer.future;
}

void _mockAudioEventStream(String channel) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(channel, (message) async {
        final methodCall = const StandardMethodCodec().decodeMethodCall(
          message,
        );
        if (methodCall.method == 'listen' || methodCall.method == 'cancel') {
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        }
        fail(
          'Unexpected audioplayers event stream method ${methodCall.method}',
        );
      });
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}
