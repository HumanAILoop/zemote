import 'package:flutter/material.dart';

/// Diff view for tool calls (Edit/Write/MultiEdit), replicating the web
/// client's extraction logic (`Gfe`/`Jfe`/`Qfe`):
/// old/new text pairs are searched in input/output/raw with alias keys,
/// or taken from `structuredPatch`.
class DiffData {
  final String? filePath;
  final List<DiffLine> lines;

  DiffData({this.filePath, required this.lines});
}

enum DiffLineType { context, added, removed }

class DiffLine {
  final DiffLineType type;
  final String text;

  const DiffLine(this.type, this.text);
}

const _oldKeys = [
  'oldText',
  'old_string',
  'oldString',
  'before',
  'old_content',
  'oldContent',
];
const _newKeys = [
  'newText',
  'new_string',
  'newString',
  'after',
  'new_content',
  'newContent',
  'content',
];
const _pathKeys = ['filePath', 'file_path', 'path', 'file'];

Object? _firstKey(Map<String, dynamic> map, List<String> keys) {
  for (final k in keys) {
    if (map[k] != null) return map[k];
  }
  return null;
}

/// Tries to extract a diff from a toolCall row. Returns null when the row
/// is not a file edit.
DiffData? extractDiff(Map<String, dynamic> row) {
  // display.kind === 'file_diff' with patch info
  final display = row['display'];
  final candidates = <Object?>[
    row['input'],
    row['output'],
    if (row['raw'] is Map) (row['raw'] as Map)['rawOutput'],
    row['raw'],
    if (display is Map && display['kind'] == 'file_diff') display,
  ];

  for (final c in candidates) {
    if (c is! Map) continue;
    final map = c.cast<String, dynamic>();
    final oldText = _firstKey(map, _oldKeys);
    final newText = _firstKey(map, _newKeys);
    if (oldText is String && newText is String) {
      return DiffData(
        filePath: _firstKey(map, _pathKeys) as String?,
        lines: _buildLines(oldText, newText),
      );
    }
  }

  // structuredPatch: [{oldStart, oldLines, newStart, lines:[...]}]
  final patch = row['structuredPatch'];
  if (patch is List) {
    final lines = <DiffLine>[];
    String? filePath;
    for (final hunk in patch) {
      if (hunk is! Map) continue;
      final hunkMap = hunk.cast<String, dynamic>();
      filePath ??= _firstKey(hunkMap, _pathKeys) as String?;
      final hunkLines = hunk['lines'];
      if (hunkLines is! List) continue;
      for (final line in hunkLines) {
        if (line is String) {
          lines.add(_classify(line));
        } else if (line is Map) {
          final type = '${line['type'] ?? ''}';
          final text = '${line['content'] ?? line['text'] ?? ''}';
          lines.add(DiffLine(
            type == 'add' || type == 'added' || type == '+'
                ? DiffLineType.added
                : type == 'remove' ||
                        type == 'removed' ||
                        type == 'del' ||
                        type == '-'
                    ? DiffLineType.removed
                    : DiffLineType.context,
            text,
          ));
        }
      }
    }
    if (lines.isNotEmpty) {
      return DiffData(filePath: filePath, lines: lines);
    }
  }
  return null;
}

DiffLine _classify(String line) {
  if (line.startsWith('+')) return DiffLine(DiffLineType.added, line);
  if (line.startsWith('-')) return DiffLine(DiffLineType.removed, line);
  return DiffLine(DiffLineType.context, line);
}

/// Side-by-side-ish stacked diff: old text lines removed, new added,
/// with a small shared-prefix context (simple LCS-free heuristic).
List<DiffLine> _buildLines(String oldText, String newText) {
  final oldLines = oldText.split('\n');
  final newLines = newText.split('\n');

  // common prefix / suffix
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }

  final lines = <DiffLine>[];
  const contextKeep = 2;
  void addContext(List<String> src, int from, int to) {
    if (to - from > contextKeep * 2 + 1) {
      for (var i = from; i < from + contextKeep; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
      lines.add(const DiffLine(
          DiffLineType.context, ' ⋯'));
      for (var i = to - contextKeep; i < to; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
    } else {
      for (var i = from; i < to; i++) {
        lines.add(DiffLine(DiffLineType.context, ' ${src[i]}'));
      }
    }
  }

  addContext(oldLines, 0, prefix > contextKeep ? contextKeep : prefix);
  for (var i = prefix; i < oldLines.length - suffix; i++) {
    lines.add(DiffLine(DiffLineType.removed, '-${oldLines[i]}'));
  }
  for (var i = prefix; i < newLines.length - suffix; i++) {
    lines.add(DiffLine(DiffLineType.added, '+${newLines[i]}'));
  }
  if (suffix > 0) {
    addContext(oldLines, oldLines.length - suffix, oldLines.length);
  }
  return lines;
}

class DiffView extends StatelessWidget {
  final DiffData diff;

  const DiffView({super.key, required this.diff});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (diff.filePath != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10)),
              ),
              child: Text(
                diff.filePath!,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: Colors.white54),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in diff.lines.take(400))
                  Container(
                    color: switch (line.type) {
                      DiffLineType.added => const Color(0xFF22C55E)
                          .withValues(alpha: 0.12),
                      DiffLineType.removed => const Color(0xFFEF4444)
                          .withValues(alpha: 0.12),
                      DiffLineType.context => Colors.transparent,
                    },
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 1),
                    child: Text(
                      line.text.isEmpty ? ' ' : line.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.45,
                        color: switch (line.type) {
                          DiffLineType.added =>
                            const Color(0xFF86EFAC),
                          DiffLineType.removed =>
                            const Color(0xFFFCA5A5),
                          DiffLineType.context => Colors.white60,
                        },
                      ),
                    ),
                  ),
                if (diff.lines.length > 400)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('…（diff 过长已截断）',
                        style: TextStyle(
                            fontSize: 10, color: Colors.white38)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
