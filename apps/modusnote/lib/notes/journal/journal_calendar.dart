import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../../theme/modus_palette.dart';
import 'journal_days.dart';

/// The journal as a month: seven columns of square days, a rose dot on
/// each day written, as strong as the day's mood ([JournalDays.strength]).
/// A tap opens the day's page, or starts one; days still to come wait.
///
/// [compact], on a phone, folds it into the week of today. Everything is
/// worked out from the notes already open: no index, nothing asked of the
/// server.
class JournalCalendar extends StatefulWidget {
  const JournalCalendar({
    required this.entries,
    required this.today,
    required this.onDay,
    this.compact = false,
    this.actions = const [],
    super.key,
  });

  final List<DynamicEntry> entries;
  final DateValue today;

  /// Opens the page of a day, or starts one.
  final ValueChanged<DateValue> onDay;
  final bool compact;

  /// Buttons at the end of the heading (the journal's settings).
  final List<Widget> actions;

  @override
  State<JournalCalendar> createState() => _JournalCalendarState();
}

class _JournalCalendarState extends State<JournalCalendar> {
  late var _month = DateTime(widget.today.year, widget.today.month);

  void _move(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  /// The days shown, in weeks: a whole month, or the week of today.
  List<DateTime?> _days(int firstWeekday) {
    if (widget.compact) {
      final today = JournalDays.local(widget.today);
      final back = (today.weekday % 7 - firstWeekday) % 7;
      return [
        for (var i = 0; i < 7; i++)
          DateTime(today.year, today.month, today.day - back + i),
      ];
    }
    final first = DateTime(_month.year, _month.month);
    final length = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = (first.weekday % 7 - firstWeekday) % 7;
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 1; d <= length; d++) DateTime(_month.year, _month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dates = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final firstWeekday = dates.firstDayOfWeekIndex;
    final days = _days(firstWeekday);
    final shownMonths = {
      for (final day in days)
        if (day != null) (day.year, day.month),
    };
    final written = <DateValue, String?>{
      for (final (year, month) in shownMonths)
        ...Journal.month(widget.entries, year, month),
    };
    final today = widget.today;
    final todayWritten = Journal.pagesOn(widget.entries, today).isNotEmpty;
    final atToday = _month.year == today.year && _month.month == today.month;
    return Semantics(
      container: true,
      label: l10n.journalCalendar,
      child: Column(
        key: const ValueKey('journal-calendar'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dates.formatMonthYear(
                    widget.compact ? JournalDays.local(today) : _month,
                  ),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (!widget.compact) ...[
                IconButton(
                  key: const ValueKey('calendar-previous'),
                  onPressed: () => _move(-1),
                  tooltip: l10n.previousMonth,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  key: const ValueKey('calendar-next'),
                  onPressed: () => _move(1),
                  tooltip: l10n.nextMonth,
                  icon: const Icon(Icons.chevron_right),
                ),
                if (!atToday)
                  TextButton(
                    key: const ValueKey('calendar-today'),
                    onPressed: () => setState(
                      () => _month = DateTime(today.year, today.month),
                    ),
                    child: Text(l10n.calendarToday),
                  ),
              ],
              ...widget.actions,
            ],
          ),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      dates.narrowWeekdays[(firstWeekday + i) % 7],
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          for (var week = 0; week < days.length; week += 7)
            Row(
              children: [
                for (final day in days.sublist(week, week + 7))
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: day == null
                          ? const SizedBox.shrink()
                          : _Day(
                              day: JournalDays.of(day),
                              today: today,
                              written: written.containsKey(JournalDays.of(day)),
                              mood: written[JournalDays.of(day)],
                              palette: palette,
                              onTap: widget.onDay,
                            ),
                    ),
                  ),
              ],
            ),
          if (!todayWritten)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                l10n.notWrittenToday,
                key: const ValueKey('not-written-today'),
                style: theme.textTheme.labelMedium,
              ),
            ),
        ],
      ),
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({
    required this.day,
    required this.today,
    required this.written,
    required this.mood,
    required this.palette,
    required this.onTap,
  });

  final DateValue day;
  final DateValue today;
  final bool written;
  final String? mood;
  final ModusPalette palette;
  final ValueChanged<DateValue> onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isToday = day == today;
    final future = JournalDays.local(day).isAfter(JournalDays.local(today));
    final long = JournalDays.long(context, day);
    return Semantics(
      button: !future,
      selected: isToday,
      label: written ? l10n.journalDayWritten(long) : long,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('calendar-day-${JournalDays.iso(day)}'),
        onTap: future ? null : () => onTap(day),
        customBorder: const CircleBorder(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: isToday ? Border.all(color: palette.primary) : null,
          ),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xxs),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: FittedBox(
                    child: Text(
                      '${day.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: future ? palette.muted : palette.text,
                      ),
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: Spacing.xs,
                  child: written
                      ? DecoratedBox(
                          key: ValueKey('calendar-dot-${JournalDays.iso(day)}'),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.rose.withValues(
                              alpha: JournalDays.strength(mood),
                            ),
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
