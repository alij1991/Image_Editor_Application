/// A lightweight `Result<T, E>` for operations that can fail without throwing.
///
/// Used by the ML inference layer, the model downloader, and the Rust
/// bridge so callers can handle both success and failure paths without
/// try/catch walls around every call site.
sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T? get okOrNull => this is Ok<T, E> ? (this as Ok<T, E>).value : null;
  E? get errOrNull => this is Err<T, E> ? (this as Err<T, E>).error : null;

  R fold<R>(R Function(T value) onOk, R Function(E error) onErr) {
    if (this is Ok<T, E>) return onOk((this as Ok<T, E>).value);
    return onErr((this as Err<T, E>).error);
  }

  Result<U, E> mapOk<U>(U Function(T value) transform) {
    if (this is Ok<T, E>) return Ok(transform((this as Ok<T, E>).value));
    return Err((this as Err<T, E>).error);
  }

  Result<T, F> mapErr<F>(F Function(E error) transform) {
    if (this is Err<T, E>) return Err(transform((this as Err<T, E>).error));
    return Ok((this as Ok<T, E>).value);
  }
}

class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  final T value;
}

class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  final E error;
}
