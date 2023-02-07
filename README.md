# json_stream

A package for converting objects to JSON asynchronously to a byte stream.

This package is useful for encoding extremely large objects that would consume too much memory with a standard
[JsonEncoder](https://api.dart.dev/dart-convert/JsonEncoder-class.html).

Basic example:

```dart
import 'dart:async';
import 'dart:io';

import 'package:json_stream/writer.dart';

Future<void> main() async {
  await stdout.addStream(
    JsonStreamWriter.convert({
      'numbers': Stream.periodic(
        const Duration(milliseconds: 100),
            (i) => '$i',
      ).take(10),
      'letters': Stream.periodic(
        const Duration(milliseconds: 100),
            (i) => '${String.fromCharCode(i + 0x61)}',
      ).take(26),
    }),
  );
}
```
