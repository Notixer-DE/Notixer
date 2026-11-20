class MarkdownTemplate {
  const MarkdownTemplate(this.id, this.name, this.source);
  final String id, name, source;
  Map<String, String> toJson() => {'id': id, 'name': name, 'source': source};
  String render(DateTime date, String title) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return source
        .replaceAll('{{date}}', journalDate(date))
        .replaceAll('{{title}}', title)
        .replaceAll('{{weekday}}', days[date.weekday - 1])
        .replaceAll('{{year}}', '${date.year}');
  }
}

String journalDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

const defaultJournalTemplate = MarkdownTemplate(
  'daily',
  'Daily journal',
  '# {{date}} · {{weekday}}\n\n## Tasks\n\n## Notes\n- \n\n## Reflection\n',
);
