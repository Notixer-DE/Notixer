/// Shared, deterministic workload for widget regression and profile-mode runs.
String longMarkdown({int sections = 1000}) => [
  '# Long text note',
  for (var i = 0; i < sections; i++)
    '## Section $i\n\n'
        'Paragraph $i with **formatting**, a [reference][target] and enough '
        'text to wrap on narrow screens.\n\n'
        '- entry $i\n  - Nested entry $i\n\n'
        '- [ ] Task $i\n- [x] Done $i\n',
  '[target]: https://example.org\n',
].join('\n\n');
