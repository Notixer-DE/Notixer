import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/learning.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1, 12);
  final tape = 'a' * 64;
  test('version 1 intervals are deterministic, bounded and UTC-based', () {
    var progress = const LearningProgress.empty();
    expect(progress.schedule(tape), isNull);
    progress = progress.assess(
      tape,
      ReviewRating.known,
      id: 'first',
      at: start,
    );
    expect(progress.schedule(tape)!.due, start.add(const Duration(days: 1)));
    progress = progress.assess(
      tape,
      ReviewRating.known,
      id: 'second',
      at: start.add(const Duration(days: 1)),
    );
    expect(progress.schedule(tape)!.interval, const Duration(days: 2));
    for (var i = 0; i < 10; i++) {
      progress = progress.assess(
        tape,
        ReviewRating.known,
        id: 'double_$i',
        at: progress.schedule(tape)!.due,
      );
    }
    expect(progress.schedule(tape)!.interval, const Duration(days: 180));
    progress = progress.assess(
      tape,
      ReviewRating.unsure,
      id: 'unsure',
      at: progress.schedule(tape)!.due,
    );
    expect(progress.schedule(tape)!.interval, const Duration(days: 1));
    progress = progress.assess(
      tape,
      ReviewRating.again,
      id: 'again',
      at: progress.schedule(tape)!.due,
    );
    final state = progress.schedule(tape)!;
    expect(state.interval, const Duration(minutes: 10));
    expect(
      state.isDue(state.due.subtract(const Duration(microseconds: 1))),
      isFalse,
    );
    expect(state.isDue(state.due), isTrue);
    expect(state.due.isUtc, isTrue);
    expect(
      jsonEncode(LearningProgress.fromJson(progress.toJson()).toJson()),
      jsonEncode(progress.toJson()),
    );
  });

  test(
    'concurrent assessments union without doubling intervals or losing history',
    () {
      final baseline = const LearningProgress.empty().assess(
        tape,
        ReviewRating.known,
        id: 'base',
        at: start,
      );
      final at = start.add(const Duration(days: 1));
      final a = baseline.assess(tape, ReviewRating.known, id: 'a', at: at);
      final b = baseline.assess(tape, ReviewRating.again, id: 'b', at: at);
      final merged = a.merge(b);
      expect(merged.events.length, 3);
      expect(merged.schedule(tape)!.concurrent, isTrue);
      expect(merged.schedule(tape)!.heads, ['a', 'b']);
      expect(merged.schedule(tape)!.due, at.add(const Duration(minutes: 10)));
      expect(merged.schedule(tape)!.interval, const Duration(minutes: 10));
      expect(jsonEncode(a.merge(b).toJson()), jsonEncode(b.merge(a).toJson()));
      expect(jsonEncode(merged.merge(a).toJson()), jsonEncode(merged.toJson()));
      final next = merged.assess(
        tape,
        ReviewRating.known,
        id: 'acknowledge',
        at: at.add(const Duration(hours: 1)),
      );
      expect(next.events.singleWhere((e) => e.id == 'acknowledge').parents, [
        'a',
        'b',
      ]);
      expect(next.schedule(tape)!.concurrent, isFalse);
      expect(next.schedule(tape)!.count, 4);
      expect(next.schedule(tape)!.interval, const Duration(days: 1));
    },
  );

  test('clock going backwards never predates known causal parents', () {
    final baseline = const LearningProgress.empty().assess(
      tape,
      ReviewRating.known,
      id: 'base',
      at: start,
    );
    final next = baseline.assess(
      tape,
      ReviewRating.again,
      id: 'next',
      at: start.subtract(const Duration(days: 1)),
    );
    expect(next.schedule(tape)!.due, start.add(const Duration(minutes: 10)));
    expect(
      next.events.singleWhere((e) => e.id == 'next').at,
      start.subtract(const Duration(days: 1)),
    );
  });

  test(
    'malformed, conflicting and incomplete histories fail rather than drop ratings',
    () {
      final event = ReviewEvent(
        id: 'same',
        tapeId: tape,
        at: start,
        rating: ReviewRating.known,
      );
      final progress = LearningProgress.fromEvents([event]);
      expect(
        () => progress.merge(
          LearningProgress.fromEvents([
            ReviewEvent(
              id: 'same',
              tapeId: tape,
              at: start,
              rating: ReviewRating.again,
            ),
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => LearningProgress.fromEvents([
          ReviewEvent(
            id: 'orphan',
            tapeId: tape,
            at: start,
            rating: ReviewRating.known,
            parents: ['missing'],
          ),
        ]),
        throwsFormatException,
      );
      expect(
        () => LearningProgress.fromEvents([
          ReviewEvent(
            id: 'a',
            tapeId: tape,
            at: start,
            rating: ReviewRating.known,
            parents: ['b'],
          ),
          ReviewEvent(
            id: 'b',
            tapeId: tape,
            at: start,
            rating: ReviewRating.known,
            parents: ['a'],
          ),
        ]),
        throwsFormatException,
      );
      expect(
        () => LearningProgress.fromEvents([
          event,
          ReviewEvent(
            id: 'different_card',
            tapeId: 'b' * 64,
            at: start,
            rating: ReviewRating.known,
            parents: ['same'],
          ),
        ]),
        throwsFormatException,
      );
      expect(
        () => ReviewEvent.fromJson(event.toJson()..['rating'] = 'unknown'),
        throwsFormatException,
      );
      expect(
        () => ReviewEvent.fromJson(
          event.toJson()..['at'] = '2026-01-01T12:00:00',
        ),
        throwsFormatException,
      );
      expect(
        () => LearningProgress.fromJson({'version': 2, 'events': []}),
        throwsFormatException,
      );
    },
  );
}
