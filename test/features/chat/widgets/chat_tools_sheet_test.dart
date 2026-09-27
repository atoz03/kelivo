import 'dart:convert';

import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/widgets/chat_tools_sheet.dart';
import 'package:Kelivo/features/home/services/local_tool_labels.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_switch.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

class _FakeMcpProvider extends McpProvider {
  _FakeMcpProvider({required super.preferences});

  List<McpServerConfig> fakeServers = const <McpServerConfig>[];

  @override
  List<McpServerConfig> get servers => fakeServers;

  @override
  McpStatus statusFor(String id) => McpStatus.connected;

  @override
  List<McpServerConfig> get connectedServers => fakeServers;

  @override
  bool get hasAnyEnabled => fakeServers.isNotEmpty;
}

McpServerConfig _server(String id, String name, {int tools = 2}) {
  return McpServerConfig(
    id: id,
    enabled: true,
    name: name,
    transport: McpTransportType.sse,
    tools: [
      for (var i = 0; i < tools; i++)
        McpToolConfig(enabled: i == 0, name: '$id-tool-$i'),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late AssistantProvider assistants;
  late _FakeMcpProvider mcp;
  late BusinessPreferences uiPreferences;
  late String assistantId;

  setUp(() async {
    // Every createBusinessTestPreferences() call resets the SharedPreferences
    // mock store, so build them all up front: doing it while a provider load
    // is in flight swaps the store out from under it.
    final settingsPreferences = createBusinessTestPreferences();
    final assistantPreferences = createBusinessTestPreferences();
    final mcpPreferences = createBusinessTestPreferences();
    uiPreferences = createBusinessTestPreferences();
    await uiPreferences.load();
    settings = SettingsProvider(settingsPreferences);
    mcp = _FakeMcpProvider(preferences: mcpPreferences);
    await assistantPreferences.load();
    assistantId = 'assistant-under-test';
    await assistantPreferences.setString(
      'assistants_v1',
      jsonEncode([Assistant(id: assistantId, name: 'Tester').toJson()]),
    );
    await assistantPreferences.setString(
      'current_assistant_id_v1',
      assistantId,
    );
    assistants = AssistantProvider(preferences: assistantPreferences);
    await assistants.loaded;
    await settings.loaded;
  });

  Future<AppLocalizations> pumpSheet(
    WidgetTester tester, {
    List<McpServerConfig> servers = const [],
  }) async {
    mcp.fakeServers = servers;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<McpProvider>.value(value: mcp),
          Provider<BusinessPreferences>.value(value: uiPreferences),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppSnackBarOverlay(
            child: Scaffold(body: ChatToolsSheet(assistantId: assistantId)),
          ),
        ),
      ),
    );
    await tester.pump();
    return AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
  }

  testWidgets('shows the local tools group folded with an enabled count', (
    tester,
  ) async {
    final l10n = await pumpSheet(tester);

    expect(find.byKey(ChatToolsSheet.localGroupKey), findsOneWidget);
    expect(
      find.text('0/${availableLocalToolIds().length}'),
      findsOneWidget,
      reason: 'the folded header still reports how many tools are on',
    );
    expect(
      find.byKey(ChatToolsSheet.localToolKey(LocalToolNames.timeInfo)),
      findsNothing,
      reason: 'local tools start folded',
    );
    expect(find.text(l10n.assistantEditPageLocalToolsTab), findsOneWidget);
  });

  testWidgets('unfolding a group swaps its summary for the rows', (
    tester,
  ) async {
    final l10n = await pumpSheet(tester);
    final count = '0/${availableLocalToolIds().length}';
    expect(find.text(count), findsOneWidget);

    await tester.tap(find.text(l10n.assistantEditPageLocalToolsTab));
    await tester.pumpAndSettle();

    expect(
      find.text(count),
      findsNothing,
      reason: 'an open group shows its rows instead of a summary',
    );
    expect(
      find.byKey(ChatToolsSheet.localToolKey(LocalToolNames.timeInfo)),
      findsOneWidget,
    );
  });

  testWidgets('reopening the sheet restores the last fold state', (
    tester,
  ) async {
    final l10n = await pumpSheet(tester);
    final timeInfo = find.byKey(
      ChatToolsSheet.localToolKey(LocalToolNames.timeInfo),
    );
    expect(timeInfo, findsNothing);

    await tester.tap(find.text(l10n.assistantEditPageLocalToolsTab));
    await tester.pumpAndSettle();
    expect(timeInfo, findsOneWidget);
    // The write goes through SQLite, which the fake clock does not advance.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );

    // Tear the sheet down and open a fresh one, as reopening it would.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSheet(tester);

    expect(
      timeInfo,
      findsOneWidget,
      reason: 'the group the user opened stays open next time',
    );
  });

  testWidgets('unfolding local tools and tapping one enables it', (
    tester,
  ) async {
    final l10n = await pumpSheet(tester);

    await tester.tap(find.text(l10n.assistantEditPageLocalToolsTab));
    await tester.pumpAndSettle();

    final row = find.byKey(
      ChatToolsSheet.localToolKey(LocalToolNames.timeInfo),
    );
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(
      assistants.getById(assistantId)!.localToolIds,
      contains(LocalToolNames.timeInfo),
    );
    // AssistantProvider notifies only after persisting, which needs real async
    // time the fake clock does not advance.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    // The count is the folded header's summary, so fold the group to read it.
    await tester.tap(find.text(l10n.assistantEditPageLocalToolsTab));
    await tester.pumpAndSettle();
    expect(find.text('1/${availableLocalToolIds().length}'), findsOneWidget);
  });

  testWidgets('hides the MCP group when nothing is connected', (tester) async {
    await pumpSheet(tester);
    expect(find.byKey(ChatToolsSheet.mcpGroupKey), findsNothing);
  });

  testWidgets('MCP servers toggle the assistant selection', (tester) async {
    await pumpSheet(tester, servers: [_server('s1', 'Alpha')]);

    expect(find.byKey(ChatToolsSheet.mcpGroupKey), findsOneWidget);
    final row = find.byKey(ChatToolsSheet.mcpServerKey('s1'));
    expect(row, findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(
      find.descendant(of: row, matching: find.byType(IosSwitch)),
    );
    await tester.pumpAndSettle();
    expect(assistants.getById(assistantId)!.mcpServerIds, ['s1']);

    // AssistantProvider notifies only after persisting, so the row would still
    // be reading the pre-toggle selection without real async time.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(assistants.getById(assistantId)!.mcpServerIds, isEmpty);
  });
}
