import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/widgets/bottom_tools_sheet.dart';
import 'package:Kelivo/features/chat/widgets/tools_sheet_row.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });

  Future<AppLocalizations> pumpSheet(
    WidgetTester tester, {
    VoidCallback? onClear,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: BottomToolsSheet(onClear: onClear)),
        ),
      ),
    );
    await tester.pump();
    return AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
  }

  Finder row(String label) => find.byWidgetPredicate(
    (widget) => widget is ToolsSheetRow && widget.label == label,
  );

  testWidgets('offers attachments and context management without OCR', (
    tester,
  ) async {
    var cleared = 0;
    final l10n = await pumpSheet(tester, onClear: () => cleared++);

    expect(find.text(l10n.bottomToolsSheetCamera), findsOneWidget);
    expect(find.text(l10n.bottomToolsSheetPhotos), findsOneWidget);
    expect(find.text(l10n.bottomToolsSheetUpload), findsOneWidget);
    expect(row(l10n.bottomToolsSheetOcr), findsNothing);

    final context = row(l10n.contextManagement);
    expect(context, findsOneWidget);
    final trailing = tester.widget<ToolsSheetRow>(context).trailing;
    expect(trailing, isA<Icon>());
    expect((trailing! as Icon).icon, Lucide.ChevronRight);

    await tester.tap(context);
    await tester.pumpAndSettle();
    expect(cleared, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a configured OCR model adds a row that toggles OCR', (
    tester,
  ) async {
    await tester.runAsync(() => settings.setOcrModel('provider', 'model'));
    final l10n = await pumpSheet(tester);

    final ocr = row(l10n.bottomToolsSheetOcr);
    expect(ocr, findsOneWidget);
    expect(tester.widget<ToolsSheetRow>(ocr).selected, isFalse);

    await tester.tap(ocr);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(settings.ocrEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
