enum OutboxStatus {
  pending('pending'),
  syncing('syncing'),
  succeeded('succeeded'),
  retryableFailed('retryable_failed'),
  conflict('conflict'),
  permanentlyFailed('permanently_failed');

  const OutboxStatus(this.wireValue);

  final String wireValue;

  static OutboxStatus fromWireValue(String value) {
    return values.firstWhere(
      (status) => status.wireValue == value,
      orElse: () => throw FormatException('Unknown outbox status: $value'),
    );
  }
}

final class OutboxTransitionException implements Exception {
  const OutboxTransitionException(this.from, this.to);

  final OutboxStatus from;
  final OutboxStatus to;

  @override
  String toString() =>
      'OutboxTransitionException(${from.wireValue} -> ${to.wireValue})';
}

abstract final class OutboxStateMachine {
  static const Map<OutboxStatus, Set<OutboxStatus>> _allowed =
      <OutboxStatus, Set<OutboxStatus>>{
        OutboxStatus.pending: <OutboxStatus>{OutboxStatus.syncing},
        OutboxStatus.syncing: <OutboxStatus>{
          OutboxStatus.succeeded,
          OutboxStatus.retryableFailed,
          OutboxStatus.conflict,
          OutboxStatus.permanentlyFailed,
        },
        OutboxStatus.retryableFailed: <OutboxStatus>{OutboxStatus.pending},
      };

  static OutboxStatus transition(OutboxStatus from, OutboxStatus to) {
    if (!(_allowed[from]?.contains(to) ?? false)) {
      throw OutboxTransitionException(from, to);
    }
    return to;
  }
}
