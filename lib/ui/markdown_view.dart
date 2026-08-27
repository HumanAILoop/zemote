import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import 'theme.dart';
import 'ui_settings.dart';

/// Markdown renderer matching the official client look:
/// selectable body text + code blocks with language tag and copy button.
class ZemoteMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;
  final double fontSize;

  const ZemoteMarkdown(
    this.data, {
    super.key,
    this.selectable = true,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final codeFont =
        UiSettingsProvider.of(context)?.codeFontSize ?? fontSize - 1.5;
    final styleSheet = MarkdownStyleSheet(
      p: TextStyle(fontSize: fontSize, height: 1.6, color: ZInk.solid(context)),
      h1: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.6,
          color: ZInk.solid(context)),
      h2: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          height: 1.6,
          color: ZInk.solid(context)),
      h3: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.6,
          color: ZInk.solid(context)),
      h4: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.6,
          color: ZInk.solid(context)),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: codeFont,
        backgroundColor: ZInk.codeInlineBg(context),
        color: ZInk.codeText(context),
      ),
      codeblockDecoration: const BoxDecoration(),
      blockquote:
          TextStyle(fontSize: fontSize, color: ZInk.soft(context), height: 1.6),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: ZColors.primary.withValues(alpha: 0.5), width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      listBullet: TextStyle(
          fontSize: fontSize, height: 1.6, color: ZInk.solid(context)),
      tableBody: TextStyle(fontSize: fontSize - 1, color: ZInk.solid(context)),
      tableHead: TextStyle(
          fontSize: fontSize - 1,
          fontWeight: FontWeight.w600,
          color: ZInk.solid(context)),
      tableBorder: TableBorder.all(color: ZInk.hairline(context), width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: ZInk.hairline(context))),
      ),
      a: const TextStyle(
          color: ZColors.running, decoration: TextDecoration.underline),
    );

    final body = MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      builders: {
        'code': _CodeBlockBuilder(codeFontSize: codeFont),
      },
      softLineBreak: true,
    );
    return body;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final double codeFontSize;

  _CodeBlockBuilder({required this.codeFontSize});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Language is encoded in the class attribute: `language-dart`.
    var language = '';
    final classAttr = element.attributes['class'];
    if (classAttr != null) {
      final match = RegExp(r'language-(\S+)').firstMatch(classAttr);
      if (match != null) language = match.group(1) ?? '';
    }
    final code = element.textContent;
    if (!code.contains('\n') && language.isEmpty) {
      // inline code: default styling
      return null;
    }
    return _CodeBlock(code: code, language: language, fontSize: codeFontSize);
  }
}

class _CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final double fontSize;

  const _CodeBlock({
    required this.code,
    required this.language,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: ZInk.codeBlockBg(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.tileBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ZInk.tile(context),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: ZInk.faint(context),
                      fontFamily: 'monospace'),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.copy_outlined,
                        size: 13, color: ZInk.faint(context)),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: fontSize - 1.5,
                height: 1.5,
                color: ZInk.codeText(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
