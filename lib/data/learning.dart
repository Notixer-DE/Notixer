import 'dart:convert';

enum ReviewRating {
  known('Remembered'),
  unsure('Unsure'),
  again('Forgot');

  const ReviewRating(this.label);
  final String label;
}

/// One immutable assessment. Parents are the known tips for this card, not
/// device timestamps: concurrent offline assessments therefore remain distinct.
class ReviewEvent {
  ReviewEvent({
    required this.id,
    required this.tapeId,
    required DateTime at,
    required this.rating,
    List<String> parents = const [],
  }) : at = at.toUtc(),
       parents = List.unmodifiable(parents.toSet().toList()..sort());

  final String id, tapeId;
  final DateTime at;
  final ReviewRating rating;
  final List<String> parents;

  Map<String, Object?> toJson() => {
    'id': id,
    'tape': tapeId,
    'at': at.toIso8601String(),
    'rating': rating.name,
    'parents': parents,
  };

  factory ReviewEvent.fromJson(Map<String, dynamic> json) {
    final id = json['id'], tape = json['tape'], parents = json['parents'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        tape is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(tape) ||
        json['at'] is! String ||
        parents is! List ||
        parents.any((p) => p is! String) ||
        !ReviewRating.values.any((r) => r.name == json['rating'])) {
      throw const FormatException('Invalid study rating.');
    }
    final at = DateTime.tryParse(json['at']);
    if (at == null || !at.isUtc) {
      throw const FormatException('Study ratings require a UTC timestamp.');
    }
    return ReviewEvent(
      id: id,
      tapeId: tape,
      at: at,
      rating: ReviewRating.values.byName(json['rating']),
      parents: parents.cast<String>(),
    );
  }
}

class ReviewSchedule {
  const ReviewSchedule(
    this.interval,
    this.due,
    this.reviewedAt,
    this.heads,
    this.count,
  );
  final Duration interval;
  final DateTime due, reviewedAt;
  final List<String> heads;
  final int count;
  bool get concurrent => heads.length > 1;
  bool isDue(DateTime now) => !due.isAfter(now.toUtc());
}

/// Version 1: again = 10 minutes; unsure = 1 day; known = double the previous
/// interval in whole days (at least 1, at most 180). A new card is due now.
/// Concurrent tips use the earliest due date and shortest interval. A subsequent
/// assessment acknowledges all tips and resumes the ordinary schedule.
class LearningProgress {
  const LearningProgress.empty() : events = const [], _schedules = const {};
  LearningProgress._(this.events, this._schedules);
  final List<ReviewEvent> events;
  final Map<String, ReviewSchedule> _schedules;
  bool get isEmpty => events.isEmpty;
  ReviewSchedule? schedule(String tapeId) => _schedules[tapeId];

  factory LearningProgress.fromEvents(Iterable<ReviewEvent> source) {
    final byId = <String, ReviewEvent>{};
    for (final event in source) {
      final previous = byId[event.id];
      if (previous != null &&
          jsonEncode(previous.toJson()) != jsonEncode(event.toJson())) {
        throw const FormatException('Conflicting study rating ID.');
      }
      byId[event.id] = event;
    }
    final pending = <String, int>{};
    final children = <String, List<String>>{};
    for (final event in byId.values) {
      pending[event.id] = event.parents.length;
      for (final parent in event.parents) {
        if (byId[parent]?.tapeId != event.tapeId) {
          throw const FormatException('Incomplete study history.');
        }
        (children[parent] ??= []).add(event.id);
      }
    }
    final ready = pending.keys.where((id) => pending[id] == 0).toList();
    final states = <String, ReviewSchedule>{};
    final tips = <String, Set<String>>{};
    final counts = <String, int>{};
    for (var i = 0; i < ready.length; i++) {
      final event = byId[ready[i]]!;
      var at = event.at;
      Duration? previousInterval;
      final heads = tips.putIfAbsent(event.tapeId, () => {});
      for (final parent in event.parents) {
        final state = states[parent]!;
        if (state.reviewedAt.isAfter(at)) at = state.reviewedAt;
        if (previousInterval == null || state.interval < previousInterval) {
          previousInterval = state.interval;
        }
        heads.remove(parent);
      }
      final interval = switch (event.rating) {
        ReviewRating.again => const Duration(minutes: 10),
        ReviewRating.unsure => const Duration(days: 1),
        ReviewRating.known => Duration(
          days: ((previousInterval?.inDays ?? 0) * 2).clamp(1, 180),
        ),
      };
      states[event.id] = ReviewSchedule(interval, at.add(interval), at, [
        event.id,
      ], 1);
      heads.add(event.id);
      counts.update(event.tapeId, (n) => n + 1, ifAbsent: () => 1);
      for (final child in children[event.id] ?? const <String>[]) {
        pending[child] = pending[child]! - 1;
        if (pending[child] == 0) ready.add(child);
      }
    }
    if (states.length != byId.length) {
      throw const FormatException('Cyclic study history.');
    }
    final schedules = <String, ReviewSchedule>{};
    for (final entry in tips.entries) {
      final heads = entry.value.toList()..sort();
      final values = heads.map((id) => states[id]!);
      schedules[entry.key] = ReviewSchedule(
        values.map((s) => s.interval).reduce((a, b) => a < b ? a : b),
        values.map((s) => s.due).reduce((a, b) => a.isBefore(b) ? a : b),
        values.map((s) => s.reviewedAt).reduce((a, b) => a.isAfter(b) ? a : b),
        List.unmodifiable(heads),
        counts[entry.key]!,
      );
    }
    final events = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return LearningProgress._(
      List.unmodifiable(events),
      Map.unmodifiable(schedules),
    );
  }

  LearningProgress merge(LearningProgress other) =>
      LearningProgress.fromEvents([...events, ...other.events]);

  LearningProgress assess(
    String tapeId,
    ReviewRating rating, {
    required String id,
    required DateTime at,
  }) => LearningProgress.fromEvents([
    ...events,
    ReviewEvent(
      id: id,
      tapeId: tapeId,
      at: at,
      rating: rating,
      parents: schedule(tapeId)?.heads ?? const [],
    ),
  ]);

  Map<String, Object?> toJson() => {
    'version': 1,
    'events': events.map((event) => event.toJson()).toList(),
  };

  factory LearningProgress.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['events'] is! List) {
      throw const FormatException('Unknown study history.');
    }
    return LearningProgress.fromEvents(
      (json['events'] as List).map(
        (event) => ReviewEvent.fromJson(event as Map<String, dynamic>),
      ),
    );
  }
}
