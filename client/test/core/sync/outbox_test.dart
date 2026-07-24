import 'package:c_biz_docs_manager/core/sync/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('outbox accepts the documented delivery state transitions', () {
    expect(
      OutboxStateMachine.transition(OutboxStatus.pending, OutboxStatus.syncing),
      OutboxStatus.syncing,
    );
    for (final target in <OutboxStatus>[
      OutboxStatus.succeeded,
      OutboxStatus.retryableFailed,
      OutboxStatus.conflict,
      OutboxStatus.permanentlyFailed,
    ]) {
      expect(
        OutboxStateMachine.transition(OutboxStatus.syncing, target),
        target,
      );
    }
    expect(
      OutboxStateMachine.transition(
        OutboxStatus.retryableFailed,
        OutboxStatus.pending,
      ),
      OutboxStatus.pending,
    );
  });

  test('outbox rejects skipped, repeated, and terminal transitions', () {
    for (final transition in <(OutboxStatus, OutboxStatus)>[
      (OutboxStatus.pending, OutboxStatus.succeeded),
      (OutboxStatus.pending, OutboxStatus.pending),
      (OutboxStatus.succeeded, OutboxStatus.pending),
      (OutboxStatus.conflict, OutboxStatus.syncing),
      (OutboxStatus.permanentlyFailed, OutboxStatus.pending),
    ]) {
      expect(
        () => OutboxStateMachine.transition(transition.$1, transition.$2),
        throwsA(isA<OutboxTransitionException>()),
      );
    }
  });
}
