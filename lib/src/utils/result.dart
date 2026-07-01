/// A lightweight `Result<T, E>` for operations that fail with a typed error
/// instead of throwing.
library;

import 'package:meta/meta.dart';

/// The outcome of an operation: either [Ok] or [Err]. Sealed for exhaustive
/// `switch` handling.
@immutable
sealed class Result<T, E> {
  const Result();

  /// Whether this is a success.
  bool get isOk => this is Ok<T, E>;

  /// The value, or null on failure.
  T? get valueOrNull => switch (this) {
        Ok<T, E>(:final value) => value,
        Err<T, E>() => null,
      };

  /// The error, or null on success.
  E? get errorOrNull => switch (this) {
        Ok<T, E>() => null,
        Err<T, E>(:final error) => error,
      };

  /// Transforms the success value, preserving errors.
  Result<R, E> map<R>(R Function(T value) f) => switch (this) {
        Ok<T, E>(:final value) => Ok<R, E>(f(value)),
        Err<T, E>(:final error) => Err<R, E>(error),
      };
}

/// A successful result.
@immutable
final class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);

  /// The success value.
  final T value;
}

/// A failed result.
@immutable
final class Err<T, E> extends Result<T, E> {
  const Err(this.error);

  /// The error value.
  final E error;
}
