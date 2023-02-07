import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class _ContainerState {
  _ContainerState(this.isMap);

  bool isMap;
  var hasKey = false;
  var needsComma = false;
}

/// Encodes JSON values to a stream asynchronously, this is useful for encoding
/// extremely large objects that would consume too much memory with a standard
/// [JsonEncoder].
class JsonStreamWriter {
  // Completer for when the stream is paused, such as when the stream is piped
  // to a socket and its buffer is full. We want to avoid buffering the entire
  // json in memory (that's the whole point of this library) so each write is
  // asynchronous.
  Completer<void>? _pause = Completer<void>();
  var _writing = false;
  var _hasRootValue = false;

  late final _stream = StreamController<List<int>>(onPause: () {
    _pause = Completer<void>();
  }, onResume: () {
    _pause?.complete();
    _pause = null;
  }, onListen: () {
    _pause?.complete();
    _pause = null;
  });
  late final Stream<List<int>> stream = _stream.stream;

  final _stack = <_ContainerState>[];

  void _checkWrite() {
    if (_writing) {
      throw AssertionError(
        'Concurrent writes detected, this usually means methods of '
        'JsonStreamWriter are not being awaited',
      );
    }
  }

  Future<void> _writeRawBuffer(List<int> data) async {
    _checkWrite();
    try {
      _writing = true;
      await _pause?.future;
      _stream.add(data);
    } finally {
      _writing = false;
    }
  }

  Future<void> _writeRawString(String json) =>
      _writeRawBuffer(utf8.encode(json));

  Future<void> _writeRawStream(Stream<List<int>> stream) async {
    _checkWrite();
    try {
      _writing = true;
      await _pause?.future;
      await _stream.addStream(stream);
    } finally {
      _writing = false;
    }
  }

  void _checkRootValue() {
    if (_stack.isEmpty) {
      if (_hasRootValue) {
        throw AssertionError(
          'Attempted to add a value past the end of the stream',
        );
      }
      _hasRootValue = true;
    }
  }

  bool _startContainer(String debugName) {
    _checkRootValue();
    _checkWrite();
    if (_stack.isEmpty) {
      return false;
    }
    final last = _stack.last;
    if (last.isMap) {
      if (last.hasKey) {
        last.hasKey = false;
      } else {
        throw AssertionError('$debugName was called when a key was expected');
      }
    }
    if (last.needsComma) {
      return true;
    } else {
      last.needsComma = true;
      return false;
    }
  }

  bool _startKey() {
    _checkWrite();
    if (_stack.isEmpty) {
      throw AssertionError('Attempted to write a key outside of a map');
    }
    final last = _stack.last;
    if (last.isMap) {
      if (last.hasKey) {
        throw AssertionError(
          'Attempted to write a key right after another key',
        );
      } else {
        last.hasKey = true;
      }
    } else {
      throw AssertionError('Attempted to write a key inside of a list');
    }
    if (last.needsComma) {
      last.needsComma = false;
      return true;
    } else {
      return false;
    }
  }

  bool _startValue() {
    _checkWrite();
    _checkRootValue();
    if (_stack.isEmpty) {
      return false;
    }
    final last = _stack.last;
    if (last.isMap) {
      if (last.hasKey) {
        last.hasKey = false;
      } else {
        throw AssertionError(
          'Attempted to write an object when a map entry was expected',
        );
      }
    }
    if (last.needsComma) {
      return true;
    } else {
      last.needsComma = true;
      return false;
    }
  }

  Future<void> _endValue() async {
    _checkWrite();
    if (_stack.isEmpty) {
      await _stream.close();
    }
  }

  /// Starts a JSON map, this is method should only be called when a value is
  /// expected.
  Future<void> startMap() {
    final comma = _startContainer('startMap');
    _stack.add(_ContainerState(true));
    return _writeRawString('${comma ? ',' : ''}{');
  }

  /// Starts a JSON list, this is method should only be called when a value is
  /// expected.
  Future<void> startList() {
    final comma = _startContainer('startList');
    _stack.add(_ContainerState(false));
    return _writeRawString('${comma ? ',' : ''}[');
  }

  /// Ends a map or list.
  Future<void> end() async {
    _checkWrite();
    if (_stack.isEmpty) {
      throw AssertionError('end was called before a list or map was started');
    }
    final last = _stack.removeLast();
    if (last.hasKey) {
      throw AssertionError(
        'end was called after a key was written without a value',
      );
    }
    await _writeRawString(last.isMap ? '}' : ']');
    if (_stack.isEmpty) {
      await _stream.close();
    }
  }

  /// Writes a simple key string, this should only be called inside of a map
  /// and the following write needs to be a value.
  Future<void> writeKey(String key) async {
    final comma = _startKey();
    await _writeRawString('${comma ? ',' : ''}');
    await _writeRawBuffer(encodeValue(key));
    await _writeRawString(':');
  }

  /// Writes a key from a stream of string parts, I feel bad for anyone that
  /// needs this.
  Future<void> writeKeyStream(Stream<String> stream) async {
    final comma = _startKey();
    await _writeRawString('${comma ? ',' : ''}"');
    await _writeRawStream(stream.map(encodeStringContents));
    await _writeRawString('":');
  }

  /// Writes a string value from a stream of string parts.
  Future<void> writeStringStream(Stream<String> stream) async {
    final comma = _startValue();
    await _writeRawString('${comma ? ',' : ''}"');
    await _writeRawStream(stream.map(encodeStringContents));
    await _writeRawString('"');
    await _endValue();
  }

  /// Writes a JSON value from a raw buffer of bytes, this buffer must contain
  /// a valid UTF-8 encoded json object.
  Future<void> writeRawBuffer(List<int> buffer) async {
    if (_startValue()) {
      await _writeRawString(',');
    }
    await _writeRawBuffer(buffer);
    await _endValue();
  }

  Future<Object?> _reduce(Object? value) async {
    for (;;) {
      if (value is Function) {
        value = await value();
        break;
      } else if (value is Future) {
        value = await value;
      } else {
        break;
      }
    }
    return value;
  }

  /// Encodes and writes an arbitrary JSON value, this is method should only be
  /// called when a value is expected.
  Future<void> write(Object? value) async {
    // We put the constant on the lhs of these comparisons so it doesn't invoke
    // operator overloads
    if (value is String ||
        value is num ||
        true == value ||
        false == value ||
        null == value) {
      await writeRawBuffer(encodeValue(value));
    } else if (value is List) {
      await startList();
      for (final element in value) {
        await write(element);
      }
      await end();
    } else if (value is Map) {
      await startMap();
      for (final entry in value.entries) {
        Object? key = entry.key;
        if (key is! String) {
          key = await _reduce(key);
        }
        if (key is String) {
          await writeKey(key);
        } else if (key is Stream<String>) {
          await writeKeyStream(key);
        } else {
          throw ArgumentError(
            'Invalid map key ${key.runtimeType}, only Strings are '
            'allowed in JSON',
          );
        }
        await write(entry.value);
      }
      await end();
    } else if (value is Stream<String>) {
      return writeStringStream(value);
    } else if (value is Future) {
      return write(await value);
    } else if (value is Function) {
      return write(await value());
    } else {
      final Object? newValue = await (value as dynamic).toJson();
      return write(newValue);
    }
  }

  /// Writes a raw JSON value from a string, this string must contain a valid
  /// json encoded object.
  Future<void> writeRawString(String json) => writeRawBuffer(utf8.encode(json));

  /// Writes a raw JSON value from a stream of bytes, this stream must contain
  /// a valid json encoded object.
  Future<void> writeRawStream(Stream<List<int>> stream) async {
    if (_startValue()) {
      await _writeRawString(',');
    }
    await _writeRawStream(stream);
    await _endValue();
  }

  /// Writes an entry to a map, this is equivalent to calling [writeKey]
  /// followed by [write].
  Future<void> writeEntry(String key, Object? value) async {
    await writeKey(key);
    await write(value);
  }

  /// Closes the writer and waits for listeners of [stream] to finish.
  Future<void> close() async {
    await _stream.close();
    _checkWrite();
    if (_stack.isNotEmpty) {
      throw AssertionError(
        'Attempted to close writer without ending the top-level list or map',
      );
    } else if (!_hasRootValue) {
      throw AssertionError(
        'Attempted to close the writer without actually writing a value',
      );
    }
  }

  /// Converts a single value to a json stream.
  static Stream<List<int>> convert(Object? value) {
    final writer = JsonStreamWriter();
    writer.write(value).then((_) => writer.close());
    return writer.stream;
  }

  /// Encodes and escapes the contents of a string so that it can be written to
  /// a json stream.
  static Uint8List encodeStringContents(String value) {
    // We can piggyback off the existing implementation with minimal overhead,
    // just encode the string and slice away the quotes.
    final encoded = encodeValue(value);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes + 1,
      encoded.lengthInBytes - 2,
    );
  }

  /// Converts a value to JSON.
  static Uint8List encodeValue(Object? value) {
    // JsonUtf8Encoder minimizes copying by doing both string escape and UTF-8
    // encoding at the same time.
    final encoded = JsonUtf8Encoder().convert(value);
    if (encoded is Uint8List) {
      return encoded;
    } else {
      // The current implementation of convert always returns Uint8List, but we
      // should copy it just in case that changes.
      return Uint8List.fromList(encoded);
    }
  }
}
