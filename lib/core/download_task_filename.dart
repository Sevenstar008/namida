import 'dart:io';

import 'package:namida/core/extensions.dart';

class DownloadTaskFilename {
  static final int _fullPathLimit = Platform.isWindows
      ? 258
      : Platform.isMacOS
      ? 1024
      : 4096;

  static final RegExp cleanupFilenameRegex = RegExp(r'[*#\$|/\\!^:"\?%<>\u2F38\u2044\u29F8]', caseSensitive: false);
  static String cleanupFilename(String filename, {required String parentDirPath}) {
    final cleaned = filename.replaceAll(cleanupFilenameRegex, '_');
    final maxLength = 255.withMaximum(_fullPathLimit - parentDirPath.length);
    if (cleaned.length <= maxLength) return cleaned;
    final dotIndex = cleaned.lastIndexOf('.');
    final ext = dotIndex > 0 ? cleaned.substring(dotIndex) : '';
    if (ext.length >= maxLength) return cleaned.substring(0, maxLength);
    return '${cleaned.substring(0, maxLength - ext.length)}$ext';
  }

  static int _numberKey = 0;

  String filename;
  final String key;

  static DownloadTaskFilename create({
    required String initialFilename,
  }) =>
      DownloadTaskFilename._(
        filename: initialFilename,
        key: _createKey(),
      );

  DownloadTaskFilename._({
    required this.filename,
    required String? key,
  }) : key = key ?? _createKey();

  static String _createKey() => ((_numberKey++).hashCode ^ DateTime.now().microsecondsSinceEpoch.hashCode).toString();

  @override
  String toString() => filename;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'filename': filename,
      'key': key,
    };
  }

  factory DownloadTaskFilename.fromMap(dynamic value) {
    if (value is Map) {
      return DownloadTaskFilename._(
        filename: value['filename'] as String? ?? 'UNKNOWN_FILENAME',
        key: value['key'] as String?,
      );
    }
    // -- old string only
    return DownloadTaskFilename._(
      filename: value as String,
      key: null,
    );
  }

  @override
  bool operator ==(other) {
    return other is DownloadTaskFilename && filename == other.filename && key == other.key;
  }

  @override
  int get hashCode => filename.hashCode ^ key.hashCode;
}
