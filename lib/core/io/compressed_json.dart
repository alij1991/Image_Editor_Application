import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Threshold in bytes at which [encodeCompressedJson] switches from
/// plain UTF-8 to gzip. The value matches the plan's "compress BLOB
/// > 64 KB" rule — beneath it the overhead of deflate wins against the
/// JSON's natural redundancy.
const int kCompressedJsonGzipThreshold = 64 * 1024;

/// Encodes [json] to a byte buffer with a single-byte marker prefix:
///
///   0x00 → plain UTF-8 JSON
///   0x01 → gzip-compressed UTF-8 JSON
///
/// Gzip kicks in when the UTF-8 length is at least [threshold] bytes
/// (default [kCompressedJsonGzipThreshold]). The marker lets readers
/// branch without a content-sniff and keeps the format
/// self-describing.
///
/// Shared primitive for pipeline and wrapper persistence — used by
/// [PipelineSerializer.encode] for raw pipeline BLOBs and by
/// [ProjectStore.save] for the auto-save envelope.
Uint8List encodeCompressedJson(
  String json, {
  int threshold = kCompressedJsonGzipThreshold,
}) {
  final bytes = utf8.encode(json);
  if (bytes.length < threshold) {
    return Uint8List.fromList([0x00, ...bytes]);
  }
  return Uint8List.fromList([0x01, ...gzip.encode(bytes)]);
}

/// Decodes a buffer produced by [encodeCompressedJson] back to its
/// UTF-8 JSON string. Strips the marker byte; gunzips on `0x01`.
///
/// Accepts **legacy un-marked** buffers: if the first byte is neither
/// `0x00` nor `0x01`, the whole buffer is decoded as UTF-8 unchanged.
/// This lets Phase IV.2 replace a plain `writeAsString(jsonEncode(...))`
/// store with the marker-byte format without an on-disk migration —
/// every project file saved before the cutover still loads because
/// JSON objects start with `{` (0x7B) or `[` (0x5B), never with the
/// reserved markers.
String decodeCompressedJson(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const FormatException('decodeCompressedJson: empty buffer');
  }
  final marker = bytes.first;
  return switch (marker) {
    0x00 => utf8.decode(bytes.sublist(1)),
    0x01 => utf8.decode(gzip.decode(bytes.sublist(1))),
    _ => utf8.decode(bytes), // Legacy — no marker byte; whole buffer is JSON.
  };
}
