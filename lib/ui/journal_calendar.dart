import 'package:flutter/material.dart';

import '../data/journal_template.dart';

class JournalCalendar extends StatelessWidget {
  const JournalCalendar({
    super.key,
    required this.month,
    required this.selected,
    required this.entryDays,
    required this.onMonth,
    required this.onDay,
  });

  final DateTime month, selected;
  final Set<String> entryDays;
  final ValueChanged<DateTime>? onMonth, onDay;

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    final offset = DateUtils.firstDayOffset(month.year, month.month, locale);
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final today = DateTime.now();
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: onMonth == null
                  ? null
                  : () => onMonth!(DateTime(month.year, month.month - 1)),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                locale.formatMonthYear(month),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: onMonth == null
                  ? null
                  : () => onMonth!(DateTime(month.year, month.month + 1)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                for (var column = 0; column < 7; column++)
                  Center(
                    child: Text(
                      locale.narrowWeekdays[(column +
                              locale.firstDayOfWeekIndex) %
                          7],
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
              ],
            ),
            for (var week = 0; week < (offset + days + 6) ~/ 7; week++)
              TableRow(
                children: [
                  for (var column = 0; column < 7; column++)
                    if (week * 7 + column - offset + 1 case final day
                        when day > 0 && day <= days)
                      _dayButton(
                        context,
                        DateTime(month.year, month.month, day),
                        today,
                      )
                    else
                      const SizedBox.shrink(),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.circle, size: 6, color: colors.primary),
            const SizedBox(width: 6),
            const Flexible(child: Text('Journal entry')),
          ],
        ),
      ],
    );
  }

  Widget _dayButton(BuildContext context, DateTime day, DateTime today) {
    final locale = MaterialLocalizations.of(context);
    final key = journalDate(day);
    final hasEntry = entryDays.contains(key);
    final isSelected = DateUtils.isSameDay(day, selected);
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          '${locale.formatFullDate(day)}${hasEntry ? ', journal entry' : ''}',
      child: Semantics(
        selected: isSelected,
        child: TextButton(
          key: ValueKey('journal-day-$key'),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(vertical: 4),
            backgroundColor: isSelected ? colors.primaryContainer : null,
            foregroundColor: isSelected ? colors.onPrimaryContainer : null,
            side: DateUtils.isSameDay(day, today)
                ? BorderSide(color: colors.primary)
                : null,
          ),
          onPressed: onDay == null ? null : () => onDay!(day),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(locale.formatDecimal(day.day)),
              Icon(
                Icons.circle,
                size: 5,
                color: hasEntry ? colors.primary : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
