import 'dart:async';
import 'dart:convert';

import 'package:json_stream/writer.dart';
import 'package:test/test.dart';

void main() {
  Future<void> expectConvert(
    Object? value,
    String expected,
  ) async {
    expect(await utf8.decodeStream(JsonStreamWriter.encode(value)), expected);
  }

  test('Top-level string', () => expectConvert('hello', '"hello"'));

  test(
    'Streamed string',
    () => expectConvert(
      Stream.fromIterable(
        ['hello', '\n', 'world'],
      ),
      '"hello\\nworld"',
    ),
  );

  test('Empty map', () => expectConvert(<String, dynamic>{}, '{}'));

  test(
    'Single entry map',
    () => expectConvert({'hello': 'world'}, '{"hello":"world"}'),
  );

  test(
    'Primitives',
    () => expectConvert(
      {
        'string': 'hello',
        'int': 123,
        'double': 123.45,
        'true': true,
        'false': false,
        'null': null,
      },
      '{"string":"hello","int":123,"double":123.45,"true":true,"false":false,"null":null}',
    ),
  );

  test(
    'Stream key',
    () => expectConvert({
      Stream<String>.value('hello'): 'world',
    }, '{"hello":"world"}'),
  );

  test('Empty list', () => expectConvert(<dynamic>[], '[]'));

  test('Single element list', () => expectConvert(['hello'], '["hello"]'));

  test(
    'Futures',
    () => expectConvert([
      Future.value(123),
    ], '[123]'),
  );

  test(
    'Functions',
    () => expectConvert({
      'sync': () => 123,
      'async': () => Future.value(456),
    }, '{"sync":123,"async":456}'),
  );
}
