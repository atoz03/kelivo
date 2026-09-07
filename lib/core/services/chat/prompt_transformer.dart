import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import '../../models/assistant.dart';

class PromptTransformer {
  static Map<String, String> buildPlaceholders({
    required BuildContext context,
    required Assistant assistant,
    required String? modelId,
    required String? modelName,
    required String userNickname,
  }) {
    final now = DateTime.now();
    final locale = Localizations.localeOf(context).toLanguageTag();
    final tz = now.timeZoneName;
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final dt = '$date $time';
    final os = Platform.operatingSystem;
    final osv = Platform.operatingSystemVersion;
    final device =
        os; // Simple fallback; can be extended with device_info plugins
    final battery = 'unknown';

    return <String, String>{
      '{cur_date}': date,
      '{cur_time}': time,
      '{cur_datetime}': dt,
      '{model_id}': modelId ?? '',
      '{model_name}': modelName ?? (modelId ?? ''),
      '{locale}': locale,
      '{timezone}': tz,
      '{system_version}': '$os $osv',
      '{device_info}': device,
      '{battery_level}': battery,
      '{nickname}': userNickname,
      '{assistant_name}': assistant.name,
    };
  }

  static String replacePlaceholders(String text, Map<String, String> vars) {
    var out = text;
    vars.forEach((k, v) {
      out = out.replaceAll(k, v);
    });
    return out;
  }

  // Very simple mustache-like replacement for message template variables
  // Supported: {{ role }}, {{ message }}, {{ time }}, {{ date }}
  //
  // [now] defaults to DateTime.now() for backwards compatibility. The memory
  // path passes the message's own timestamp (§8.3 / §9.4).
  static String applyMessageTemplate(
    String template, {
    required String role,
    required String message,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final date =
        '${effectiveNow.year.toString().padLeft(4, '0')}-${effectiveNow.month.toString().padLeft(2, '0')}-${effectiveNow.day.toString().padLeft(2, '0')}';
    final time =
        '${effectiveNow.hour.toString().padLeft(2, '0')}:${effectiveNow.minute.toString().padLeft(2, '0')}';
    final vars = <String, String>{
      'role': role,
      'message': message,
      'time': time,
      'date': date,
    };

    return template.replaceAllMapped(RegExp(r'{{\s*(\w+)\s*}}'), (match) {
      final key = match.group(1);
      return key != null && vars.containsKey(key)
          ? vars[key]!
          : match.group(0) ?? '';
    });
  }

  static const List<String> _weekdayAbbrev = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// Wraps [timestamp] as `<current_time>EEE yyyy-MM-dd HH:mm:ss</current_time>`
  /// in the local timezone, without a UTC offset.
  ///
  /// Four-digit year avoids `yy-MM-dd` / `dd-MM-yy` ambiguity (e.g. 22-26).
  static String formatCurrentTimeTag(DateTime timestamp) {
    final local = timestamp.isUtc ? timestamp.toLocal() : timestamp;
    final eee = _weekdayAbbrev[local.weekday - 1];
    final yyyy = local.year.toString();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '<current_time>$eee $yyyy-$mm-$dd $hh:$min:$ss</current_time>';
  }

  /// Returns which of `{cur_date}`, `{cur_time}`, `{cur_datetime}` occur in
  /// [systemPrompt], in that fixed order. `{timezone}` etc. are ignored.
  static List<String> detectTimeVariablesInSystemPrompt(String systemPrompt) {
    const candidates = ['{cur_date}', '{cur_time}', '{cur_datetime}'];
    return [
      for (final token in candidates)
        if (systemPrompt.contains(token)) token,
    ];
  }
}
