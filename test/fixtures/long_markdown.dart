/// Shared, deterministic workload for widget regression and profile-mode runs.
String longMarkdown({int sections = 1000}) => [
  '# Lange Textnotiz',
  for (var i = 0; i < sections; i++)
    '## Abschnitt $i\n\n'
        'Absatz $i mit **Formatierung**, einem [Verweis][ziel] und genügend '
        'Text zum Umbrechen auf schmalen Bildschirmen.\n\n'
        '- Eintrag $i\n  - Verschachtelter Eintrag $i\n\n'
        '- [ ] Aufgabe $i\n- [x] Erledigt $i\n',
  '[ziel]: https://example.org\n',
].join('\n\n');
