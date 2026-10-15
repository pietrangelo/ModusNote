import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../theme/golden_ratio.dart';

/// Days of the journal as the app shows them.
abstract final class JournalDays {
  /// The device's day at [now].
  static DateValue of(DateTime now) => DateValue(now.year, now.month, now.day);

  static DateTime local(DateValue day) =>
      DateTime(day.year, day.month, day.day);

  /// «Wednesday, October 15, 2026», in the person's language.
  static String long(BuildContext context, DateValue day) =>
      MaterialLocalizations.of(context).formatFullDate(local(day));

  /// For [NoteTitle]: [long] in [context].
  static String Function(DateValue) longIn(BuildContext context) =>
      (day) => long(context, day);

  /// 2026-10-15: a page's name outside the screen, in a file name.
  static String iso(DateValue day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// How strongly a day's dot shows its mood, in steps of φ: the
  /// brightest mood in full, the hardest at 1/φ⁴, a day without one in
  /// full.
  static double strength(String? mood) {
    final step = mood == null ? 0 : Journal.moods.indexOf(mood);
    var strength = 1.0;
    for (var i = 0; i < step; i++) {
      strength /= GoldenRatio.phi;
    }
    return strength;
  }
}
