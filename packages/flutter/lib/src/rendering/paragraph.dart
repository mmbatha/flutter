// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui show BoxHeightStyle, BoxWidthStyle, Gradient, LineMetrics, PlaceholderAlignment, Shader, TextBox, TextHeightBehavior;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'box.dart';
import 'debug.dart';
import 'layer.dart';
import 'layout_helper.dart';
import 'object.dart';
import 'selection.dart';

/// The start and end positions for a word.
typedef _WordBoundaryRecord = ({TextPosition wordStart, TextPosition wordEnd});

const String _kEllipsis = '\u2026';

/// Used by the [RenderParagraph] to map its rendering children to their
/// corresponding semantics nodes.
///
/// The [RichText] uses this to tag the relation between its placeholder spans
/// and their semantics nodes.
@immutable
class PlaceholderSpanIndexSemanticsTag extends SemanticsTag {
  /// Creates a semantics tag with the input `index`.
  ///
  /// Different [PlaceholderSpanIndexSemanticsTag]s with the same `index` are
  /// consider the same.
  const PlaceholderSpanIndexSemanticsTag(this.index) : super('PlaceholderSpanIndexSemanticsTag($index)');

  /// The index of this tag.
  final int index;

  @override
  bool operator ==(Object other) {
    return other is PlaceholderSpanIndexSemanticsTag
        && other.index == index;
  }

  @override
  int get hashCode => Object.hash(PlaceholderSpanIndexSemanticsTag, index);
}

/// Parent data used by [RenderParagraph] and [RenderEditable] to annotate
/// inline contents (such as [WidgetSpan]s) with.
class TextParentData extends ParentData with ContainerParentDataMixin<RenderBox> {
  /// The offset at which to paint the child in the parent's coordinate system.
  ///
  /// A `null` value indicates this inline widget is not laid out. For instance,
  /// when the inline widget has never been laid out, or the inline widget is
  /// ellipsized away.
  Offset? get offset => _offset;
  Offset? _offset;

  /// The [PlaceholderSpan] associated with this render child.
  ///
  /// This field is usually set by a [ParentDataWidget], and is typically not
  /// null when `performLayout` is called.
  PlaceholderSpan? span;

  @override
  void detach() {
    span = null;
    _offset = null;
    super.detach();
  }

  @override
  String toString() => 'widget: $span, ${offset == null ? "not laid out" : "offset: $offset"}';
}

/// A mixin that provides useful default behaviors for text [RenderBox]es
/// ([RenderParagraph] and [RenderEditable] for example) with inline content
/// children managed by the [ContainerRenderObjectMixin] mixin.
///
/// This mixin assumes every child managed by the [ContainerRenderObjectMixin]
/// mixin corresponds to a [PlaceholderSpan], and they are organized in logical
/// order of the text (the order each [PlaceholderSpan] is encountered when the
/// user reads the text).
///
/// To use this mixin in a [RenderBox] class:
///
///  * Call [layoutInlineChildren] in the `performLayout` and `computeDryLayout`
///    implementation, and during intrinsic size calculations, to get the size
///    information of the inline widgets as a `List` of `PlaceholderDimensions`.
///    Determine the positioning of the inline widgets (which is usually done by
///    a [TextPainter] using its line break algorithm).
///
///  * Call [positionInlineChildren] with the positioning information of the
///    inline widgets.
///
///  * Implement [RenderBox.applyPaintTransform], optionally with
///    [defaultApplyPaintTransform].
///
///  * Call [paintInlineChildren] in [RenderBox.paint] to paint the inline widgets.
///
///  * Call [hitTestInlineChildren] in [RenderBox.hitTestChildren] to hit test the
///    inline widgets.
///
/// See also:
///
///  * [WidgetSpan.extractFromInlineSpan], a helper function for extracting
///    [WidgetSpan]s from an [InlineSpan] tree.
mixin RenderInlineChildrenContainerDefaults on RenderBox, ContainerRenderObjectMixin<RenderBox, TextParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! TextParentData) {
      child.parentData = TextParentData();
    }
  }

  static PlaceholderDimensions _layoutChild(RenderBox child, double maxWidth, ChildLayouter layoutChild) {
    final TextParentData parentData = child.parentData! as TextParentData;
    final PlaceholderSpan? span = parentData.span;
    assert(span != null);
    return span == null
      ? PlaceholderDimensions.empty
      : PlaceholderDimensions(
          size: layoutChild(child, BoxConstraints(maxWidth: maxWidth)),
          alignment: span.alignment,
          baseline: span.baseline,
          baselineOffset: switch (span.alignment) {
            ui.PlaceholderAlignment.aboveBaseline ||
            ui.PlaceholderAlignment.belowBaseline ||
            ui.PlaceholderAlignment.bottom ||
            ui.PlaceholderAlignment.middle ||
            ui.PlaceholderAlignment.top      => null,
            ui.PlaceholderAlignment.baseline => child.getDistanceToBaseline(span.baseline!),
          },
        );
  }

  /// Computes the layout for every inline child using the given `layoutChild`
  /// function and the `maxWidth` constraint.
  ///
  /// Returns a list of [PlaceholderDimensions], representing the layout results
  /// for each child managed by the [ContainerRenderObjectMixin] mixin.
  ///
  /// Since this method does not impose a maximum height constraint on the
  /// inline children, some children may become taller than this [RenderBox].
  ///
  /// See also:
  ///
  ///  * [TextPainter.setPlaceholderDimensions], the method that usually takes
  ///    the layout results from this method as the input.
  @protected
  List<PlaceholderDimensions> layoutInlineChildren(double maxWidth, ChildLayouter layoutChild) {
    return <PlaceholderDimensions>[
      for (RenderBox? child = firstChild; child != null; child = childAfter(child))
        _layoutChild(child, maxWidth, layoutChild),
    ];
  }

  /// Positions each inline child according to the coordinates provided in the
  /// `boxes` list.
  ///
  /// The `boxes` list must be in logical order, which is the order each child
  /// is encountered when the user reads the text. Usually the length of the
  /// list equals [childCount], but it can be less than that, when some children
  /// are ommitted due to ellipsing. It never exceeds [childCount].
  ///
  /// See also:
  ///
  ///  * [TextPainter.inlinePlaceholderBoxes], the method that can be used to
  ///    get the input `boxes`.
  @protected
  void positionInlineChildren(List<ui.TextBox> boxes) {
    RenderBox? child = firstChild;
    for (final ui.TextBox box in boxes) {
      if (child == null) {
        assert(false, 'The length of boxes (${boxes.length}) should be greater than childCount ($childCount)');
        return;
      }
      final TextParentData textParentData = child.parentData! as TextParentData;
      textParentData._offset = Offset(box.left, box.top);
      child = childAfter(child);
    }
    while (child != null) {
      final TextParentData textParentData = child.parentData! as TextParentData;
      textParentData._offset = null;
      child = childAfter(child);
    }
  }

  /// Applies the transform that would be applied when painting the given child
  /// to the given matrix.
  ///
  /// Render children whose [TextParentData.offset] is null zeros out the
  /// `transform` to indicate they're invisible thus should not be painted.
  @protected
  void defaultApplyPaintTransform(RenderBox child, Matrix4 transform) {
    final TextParentData childParentData = child.parentData! as TextParentData;
    final Offset? offset = childParentData.offset;
    if (offset == null) {
      transform.setZero();
    } else {
      transform.translate(offset.dx, offset.dy);
    }
  }

  /// Paints each inline child.
  ///
  /// Render children whose [TextParentData.offset] is null will be skipped by
  /// this method.
  @protected
  void paintInlineChildren(PaintingContext context, Offset offset) {
    RenderBox? child = firstChild;
    while (child != null) {
      final TextParentData childParentData = child.parentData! as TextParentData;
      final Offset? childOffset = childParentData.offset;
      if (childOffset == null) {
        return;
      }
      context.paintChild(child, childOffset + offset);
      child = childAfter(child);
    }
  }

  /// Performs a hit test on each inline child.
  ///
  /// Render children whose [TextParentData.offset] is null will be skipped by
  /// this method.
  @protected
  bool hitTestInlineChildren(BoxHitTestResult result, Offset position) {
    RenderBox? child = firstChild;
    while (child != null) {
      final TextParentData childParentData = child.parentData! as TextParentData;
      final Offset? childOffset = childParentData.offset;
      if (childOffset == null) {
        return false;
      }
      final bool isHit = result.addWithPaintOffset(
        offset: childOffset,
        position: position,
        hitTest: (BoxHitTestResult result, Offset transformed) => child!.hitTest(result, position: transformed),
      );
      if (isHit) {
        return true;
      }
      child = childAfter(child);
    }
    return false;
  }
}

/// A render object that displays a paragraph of text.
class RenderParagraph extends RenderBox with ContainerRenderObjectMixin<RenderBox, TextParentData>, RenderInlineChildrenContainerDefaults, RelayoutWhenSystemFontsChangeMixin {
  /// Creates a paragraph render object.
  ///
  /// The [text], [textAlign], [textDirection], [overflow], [softWrap], and
  /// [textScaler] arguments must not be null.
  ///
  /// The [maxLines] property may be null (and indeed defaults to null), but if
  /// it is not null, it must be greater than zero.
  RenderParagraph(InlineSpan text, {
    TextAlign textAlign = TextAlign.start,
    required TextDirection textDirection,
    bool softWrap = true,
    TextOverflow overflow = TextOverflow.clip,
    @Deprecated(
      'Use textScaler instead. '
      'Use of textScaleFactor was deprecated in preparation for the upcoming nonlinear text scaling support. '
      'This feature was deprecated after v3.12.0-2.0.pre.',
    )
    double textScaleFactor = 1.0,
    TextScaler textScaler = TextScaler.noScaling,
    int? maxLines,
    Locale? locale,
    StrutStyle? strutStyle,
    TextWidthBasis textWidthBasis = TextWidthBasis.parent,
    ui.TextHeightBehavior? textHeightBehavior,
    List<RenderBox>? children,
    Color? selectionColor,
    SelectionRegistrar? registrar,
  }) : assert(text.debugAssertIsValid()),
       assert(maxLines == null || maxLines > 0),
       assert(
         identical(textScaler, TextScaler.noScaling) || textScaleFactor == 1.0,
         'textScaleFactor is deprecated and cannot be specified when textScaler is specified.',
       ),
       _softWrap = softWrap,
       _overflow = overflow,
       _selectionColor = selectionColor,
       _textPainter = TextPainter(
         text: text,
         textAlign: textAlign,
         textDirection: textDirection,
         textScaler: textScaler == TextScaler.noScaling ? TextScaler.linear(textScaleFactor) : textScaler,
         maxLines: maxLines,
         ellipsis: overflow == TextOverflow.ellipsis ? _kEllipsis : null,
         locale: locale,
         strutStyle: strutStyle,
         textWidthBasis: textWidthBasis,
         textHeightBehavior: textHeightBehavior,
       ) {
    addAll(children);
    this.registrar = registrar;
  }

  static final String _placeholderCharacter = String.fromCharCode(PlaceholderSpan.placeholderCodeUnit);
  final TextPainter _textPainter;

  List<AttributedString>? _cachedAttributedLabels;

  List<InlineSpanSemanticsInformation>? _cachedCombinedSemanticsInfos;

  /// The text to display.
  InlineSpan get text => _textPainter.text!;
  set text(InlineSpan value) {
    switch (_textPainter.text!.compareTo(value)) {
      case RenderComparison.identical:
        return;
      case RenderComparison.metadata:
        _textPainter.text = value;
        _cachedCombinedSemanticsInfos = null;
        markNeedsSemanticsUpdate();
      case RenderComparison.paint:
        _textPainter.text = value;
        _cachedAttributedLabels = null;
        _canComputeIntrinsicsCached = null;
        _cachedCombinedSemanticsInfos = null;
        markNeedsPaint();
        markNeedsSemanticsUpdate();
      case RenderComparison.layout:
        _textPainter.text = value;
        _overflowShader = null;
        _cachedAttributedLabels = null;
        _cachedCombinedSemanticsInfos = null;
        _canComputeIntrinsicsCached = null;
        markNeedsLayout();
        _removeSelectionRegistrarSubscription();
        _disposeSelectableFragments();
        _updateSelectionRegistrarSubscription();
    }
  }

  /// The ongoing selections in this paragraph.
  ///
  /// The selection does not include selections in [PlaceholderSpan] if there
  /// are any.
  @visibleForTesting
  List<TextSelection> get selections {
    if (_lastSelectableFragments == null) {
      return const <TextSelection>[];
    }
    final List<TextSelection> results = <TextSelection>[];
    for (final _SelectableFragment fragment in _lastSelectableFragments!) {
      if (fragment._textSelectionStart != null &&
          fragment._textSelectionEnd != null &&
          fragment._textSelectionStart!.offset != fragment._textSelectionEnd!.offset) {
        results.add(
          TextSelection(
            baseOffset: fragment._textSelectionStart!.offset,
            extentOffset: fragment._textSelectionEnd!.offset
          )
        );
      }
    }
    return results;
  }

  // Should be null if selection is not enabled, i.e. _registrar = null. The
  // paragraph splits on [PlaceholderSpan.placeholderCodeUnit], and stores each
  // fragment in this list.
  List<_SelectableFragment>? _lastSelectableFragments;

  /// The [SelectionRegistrar] this paragraph will be, or is, registered to.
  SelectionRegistrar? get registrar => _registrar;
  SelectionRegistrar? _registrar;
  set registrar(SelectionRegistrar? value) {
    if (value == _registrar) {
      return;
    }
    _removeSelectionRegistrarSubscription();
    _disposeSelectableFragments();
    _registrar = value;
    _updateSelectionRegistrarSubscription();
  }

  void _updateSelectionRegistrarSubscription() {
    if (_registrar == null) {
      return;
    }
    _lastSelectableFragments ??= _getSelectableFragments();
    _lastSelectableFragments!.forEach(_registrar!.add);
  }

  void _removeSelectionRegistrarSubscription() {
    if (_registrar == null || _lastSelectableFragments == null) {
      return;
    }
    _lastSelectableFragments!.forEach(_registrar!.remove);
  }

  List<_SelectableFragment> _getSelectableFragments() {
    final String plainText = text.toPlainText(includeSemanticsLabels: false);
    final List<_SelectableFragment> result = <_SelectableFragment>[];
    int start = 0;
    while (start < plainText.length) {
      int end = plainText.indexOf(_placeholderCharacter, start);
      if (start != end) {
        if (end == -1) {
          end = plainText.length;
        }
        result.add(_SelectableFragment(paragraph: this, range: TextRange(start: start, end: end), fullText: plainText));
        start = end;
      }
      start += 1;
    }
    return result;
  }

  void _disposeSelectableFragments() {
    if (_lastSelectableFragments == null) {
      return;
    }
    for (final _SelectableFragment fragment in _lastSelectableFragments!) {
      fragment.dispose();
    }
    _lastSelectableFragments = null;
  }

  @override
  void markNeedsLayout() {
    _lastSelectableFragments?.forEach((_SelectableFragment element) => element.didChangeParagraphLayout());
    super.markNeedsLayout();
  }

  @override
  void dispose() {
    _removeSelectionRegistrarSubscription();
    _disposeSelectableFragments();
    _textPainter.dispose();
    super.dispose();
  }

  /// How the text should be aligned horizontally.
  TextAlign get textAlign => _textPainter.textAlign;
  set textAlign(TextAlign value) {
    if (_textPainter.textAlign == value) {
      return;
    }
    _textPainter.textAlign = value;
    markNeedsPaint();
  }

  /// The directionality of the text.
  ///
  /// This decides how the [TextAlign.start], [TextAlign.end], and
  /// [TextAlign.justify] values of [textAlign] are interpreted.
  ///
  /// This is also used to disambiguate how to render bidirectional text. For
  /// example, if the [text] is an English phrase followed by a Hebrew phrase,
  /// in a [TextDirection.ltr] context the English phrase will be on the left
  /// and the Hebrew phrase to its right, while in a [TextDirection.rtl]
  /// context, the English phrase will be on the right and the Hebrew phrase on
  /// its left.
  ///
  /// This must not be null.
  TextDirection get textDirection => _textPainter.textDirection!;
  set textDirection(TextDirection value) {
    if (_textPainter.textDirection == value) {
      return;
    }
    _textPainter.textDirection = value;
    markNeedsLayout();
  }

  /// Whether the text should break at soft line breaks.
  ///
  /// If false, the glyphs in the text will be positioned as if there was
  /// unlimited horizontal space.
  ///
  /// If [softWrap] is false, [overflow] and [textAlign] may have unexpected
  /// effects.
  bool get softWrap => _softWrap;
  bool _softWrap;
  set softWrap(bool value) {
    if (_softWrap == value) {
      return;
    }
    _softWrap = value;
    markNeedsLayout();
  }

  /// How visual overflow should be handled.
  TextOverflow get overflow => _overflow;
  TextOverflow _overflow;
  set overflow(TextOverflow value) {
    if (_overflow == value) {
      return;
    }
    _overflow = value;
    _textPainter.ellipsis = value == TextOverflow.ellipsis ? _kEllipsis : null;
    markNeedsLayout();
  }

  /// Deprecated. Will be removed in a future version of Flutter. Use
  /// [textScaler] instead.
  ///
  /// The number of font pixels for each logical pixel.
  ///
  /// For example, if the text scale factor is 1.5, text will be 50% larger than
  /// the specified font size.
  @Deprecated(
    'Use textScaler instead. '
    'Use of textScaleFactor was deprecated in preparation for the upcoming nonlinear text scaling support. '
    'This feature was deprecated after v3.12.0-2.0.pre.',
  )
  double get textScaleFactor => _textPainter.textScaleFactor;
  @Deprecated(
    'Use textScaler instead. '
    'Use of textScaleFactor was deprecated in preparation for the upcoming nonlinear text scaling support. '
    'This feature was deprecated after v3.12.0-2.0.pre.',
  )
  set textScaleFactor(double value) {
    textScaler = TextScaler.linear(value);
  }

  /// {@macro flutter.painting.textPainter.textScaler}
  TextScaler get textScaler => _textPainter.textScaler;
  set textScaler(TextScaler value) {
    if (_textPainter.textScaler == value) {
      return;
    }
    _textPainter.textScaler = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// An optional maximum number of lines for the text to span, wrapping if
  /// necessary. If the text exceeds the given number of lines, it will be
  /// truncated according to [overflow] and [softWrap].
  int? get maxLines => _textPainter.maxLines;
  /// The value may be null. If it is not null, then it must be greater than
  /// zero.
  set maxLines(int? value) {
    assert(value == null || value > 0);
    if (_textPainter.maxLines == value) {
      return;
    }
    _textPainter.maxLines = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// Used by this paragraph's internal [TextPainter] to select a
  /// locale-specific font.
  ///
  /// In some cases, the same Unicode character may be rendered differently
  /// depending on the locale. For example, the '骨' character is rendered
  /// differently in the Chinese and Japanese locales. In these cases, the
  /// [locale] may be used to select a locale-specific font.
  Locale? get locale => _textPainter.locale;
  /// The value may be null.
  set locale(Locale? value) {
    if (_textPainter.locale == value) {
      return;
    }
    _textPainter.locale = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// {@macro flutter.painting.textPainter.strutStyle}
  StrutStyle? get strutStyle => _textPainter.strutStyle;
  /// The value may be null.
  set strutStyle(StrutStyle? value) {
    if (_textPainter.strutStyle == value) {
      return;
    }
    _textPainter.strutStyle = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// {@macro flutter.painting.textPainter.textWidthBasis}
  TextWidthBasis get textWidthBasis => _textPainter.textWidthBasis;
  set textWidthBasis(TextWidthBasis value) {
    if (_textPainter.textWidthBasis == value) {
      return;
    }
    _textPainter.textWidthBasis = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// {@macro dart.ui.textHeightBehavior}
  ui.TextHeightBehavior? get textHeightBehavior => _textPainter.textHeightBehavior;
  set textHeightBehavior(ui.TextHeightBehavior? value) {
    if (_textPainter.textHeightBehavior == value) {
      return;
    }
    _textPainter.textHeightBehavior = value;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// The color to use when painting the selection.
  ///
  /// Ignored if the text is not selectable (e.g. if [registrar] is null).
  Color? get selectionColor => _selectionColor;
  Color? _selectionColor;
  set selectionColor(Color? value) {
    if (_selectionColor == value) {
      return;
    }
    _selectionColor = value;
    if (_lastSelectableFragments?.any((_SelectableFragment fragment) => fragment.value.hasSelection) ?? false) {
      markNeedsPaint();
    }
  }

  Offset _getOffsetForPosition(TextPosition position) {
    return getOffsetForCaret(position, Rect.zero) + Offset(0, getFullHeightForCaret(position) ?? 0.0);
  }

  List<ui.LineMetrics> _computeLineMetrics() {
    return _textPainter.computeLineMetrics();
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    if (!_canComputeIntrinsics()) {
      return 0.0;
    }
    _textPainter.setPlaceholderDimensions(layoutInlineChildren(
      double.infinity,
      (RenderBox child, BoxConstraints constraints) => Size(child.getMinIntrinsicWidth(double.infinity), 0.0),
    ));
    _layoutText(); // layout with infinite width.
    return _textPainter.minIntrinsicWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    if (!_canComputeIntrinsics()) {
      return 0.0;
    }
    _textPainter.setPlaceholderDimensions(layoutInlineChildren(
      double.infinity,
      // Height and baseline is irrelevant as all text will be laid
      // out in a single line. Therefore, using 0.0 as a dummy for the height.
      (RenderBox child, BoxConstraints constraints) => Size(child.getMaxIntrinsicWidth(double.infinity), 0.0),
    ));
    _layoutText(); // layout with infinite width.
    return _textPainter.maxIntrinsicWidth;
  }

  double _computeIntrinsicHeight(double width) {
    if (!_canComputeIntrinsics()) {
      return 0.0;
    }
    _textPainter.setPlaceholderDimensions(layoutInlineChildren(width, ChildLayoutHelper.dryLayoutChild));
    _layoutText(minWidth: width, maxWidth: width);
    return _textPainter.height;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    return _computeIntrinsicHeight(width);
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return _computeIntrinsicHeight(width);
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    assert(!debugNeedsLayout);
    assert(constraints.debugAssertIsValid());
    _layoutTextWithConstraints(constraints);
    // TODO(garyq): Since our metric for ideographic baseline is currently
    // inaccurate and the non-alphabetic baselines are based off of the
    // alphabetic baseline, we use the alphabetic for now to produce correct
    // layouts. We should eventually change this back to pass the `baseline`
    // property when the ideographic baseline is properly implemented
    // (https://github.com/flutter/flutter/issues/22625).
    return _textPainter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  }

  /// Whether all inline widget children of this [RenderBox] support dry layout
  /// calculation.
  bool _canComputeDryLayoutForInlineWidgets() {
    // Dry layout cannot be calculated without a full layout for
    // alignments that require the baseline (baseline, aboveBaseline,
    // belowBaseline).
    return text.visitChildren((InlineSpan span) {
      return (span is! PlaceholderSpan) || switch (span.alignment) {
        ui.PlaceholderAlignment.baseline ||
        ui.PlaceholderAlignment.aboveBaseline ||
        ui.PlaceholderAlignment.belowBaseline => false,
        ui.PlaceholderAlignment.top ||
        ui.PlaceholderAlignment.middle ||
        ui.PlaceholderAlignment.bottom => true,
      };
    });
  }

  bool? _canComputeIntrinsicsCached;
  // Intrinsics cannot be calculated without a full layout for
  // alignments that require the baseline (baseline, aboveBaseline,
  // belowBaseline).
  bool _canComputeIntrinsics() {
    final bool returnValue = _canComputeIntrinsicsCached ??= _canComputeDryLayoutForInlineWidgets();
    assert(
        returnValue || RenderObject.debugCheckingIntrinsics,
        'Intrinsics are not available for PlaceholderAlignment.baseline, '
        'PlaceholderAlignment.aboveBaseline, or PlaceholderAlignment.belowBaseline.',
      );
    return returnValue;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, { required Offset position }) {
    final TextPosition textPosition = _textPainter.getPositionForOffset(position);
    switch (_textPainter.text!.getSpanForPosition(textPosition)) {
      case final HitTestTarget span:
        result.add(HitTestEntry(span));
        return true;
      case _:
        return hitTestInlineChildren(result, position);
    }
  }

  bool _needsClipping = false;
  ui.Shader? _overflowShader;

  /// Whether this paragraph currently has a [dart:ui.Shader] for its overflow
  /// effect.
  ///
  /// Used to test this object. Not for use in production.
  @visibleForTesting
  bool get debugHasOverflowShader => _overflowShader != null;

  void _layoutText({ double minWidth = 0.0, double maxWidth = double.infinity }) {
    final bool widthMatters = softWrap || overflow == TextOverflow.ellipsis;
    _textPainter.layout(
      minWidth: minWidth,
      maxWidth: widthMatters ? maxWidth : double.infinity,
    );
  }

  @override
  void systemFontsDidChange() {
    super.systemFontsDidChange();
    _textPainter.markNeedsLayout();
  }

  // Placeholder dimensions representing the sizes of child inline widgets.
  //
  // These need to be cached because the text painter's placeholder dimensions
  // will be overwritten during intrinsic width/height calculations and must be
  // restored to the original values before final layout and painting.
  List<PlaceholderDimensions>? _placeholderDimensions;

  void _layoutTextWithConstraints(BoxConstraints constraints) {
    _textPainter.setPlaceholderDimensions(_placeholderDimensions);
    _layoutText(minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (!_canComputeIntrinsics()) {
      assert(debugCannotComputeDryLayout(
        reason: 'Dry layout not available for alignments that require baseline.',
      ));
      return Size.zero;
    }
    _textPainter.setPlaceholderDimensions(layoutInlineChildren(constraints.maxWidth, ChildLayoutHelper.dryLayoutChild));
    _layoutText(minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
    return constraints.constrain(_textPainter.size);
  }

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    _placeholderDimensions = layoutInlineChildren(constraints.maxWidth, ChildLayoutHelper.layoutChild);
    _layoutTextWithConstraints(constraints);
    positionInlineChildren(_textPainter.inlinePlaceholderBoxes!);

    // We grab _textPainter.size and _textPainter.didExceedMaxLines here because
    // assigning to `size` will trigger us to validate our intrinsic sizes,
    // which will change _textPainter's layout because the intrinsic size
    // calculations are destructive. Other _textPainter state will also be
    // affected. See also RenderEditable which has a similar issue.
    final Size textSize = _textPainter.size;
    final bool textDidExceedMaxLines = _textPainter.didExceedMaxLines;
    size = constraints.constrain(textSize);

    final bool didOverflowHeight = size.height < textSize.height || textDidExceedMaxLines;
    final bool didOverflowWidth = size.width < textSize.width;
    // TODO(abarth): We're only measuring the sizes of the line boxes here. If
    // the glyphs draw outside the line boxes, we might think that there isn't
    // visual overflow when there actually is visual overflow. This can become
    // a problem if we start having horizontal overflow and introduce a clip
    // that affects the actual (but undetected) vertical overflow.
    final bool hasVisualOverflow = didOverflowWidth || didOverflowHeight;
    if (hasVisualOverflow) {
      switch (_overflow) {
        case TextOverflow.visible:
          _needsClipping = false;
          _overflowShader = null;
        case TextOverflow.clip:
        case TextOverflow.ellipsis:
          _needsClipping = true;
          _overflowShader = null;
        case TextOverflow.fade:
          _needsClipping = true;
          final TextPainter fadeSizePainter = TextPainter(
            text: TextSpan(style: _textPainter.text!.style, text: '\u2026'),
            textDirection: textDirection,
            textScaler: textScaler,
            locale: locale,
          )..layout();
          if (didOverflowWidth) {
            double fadeEnd, fadeStart;
            switch (textDirection) {
              case TextDirection.rtl:
                fadeEnd = 0.0;
                fadeStart = fadeSizePainter.width;
              case TextDirection.ltr:
                fadeEnd = size.width;
                fadeStart = fadeEnd - fadeSizePainter.width;
            }
            _overflowShader = ui.Gradient.linear(
              Offset(fadeStart, 0.0),
              Offset(fadeEnd, 0.0),
              <Color>[const Color(0xFFFFFFFF), const Color(0x00FFFFFF)],
            );
          } else {
            final double fadeEnd = size.height;
            final double fadeStart = fadeEnd - fadeSizePainter.height / 2.0;
            _overflowShader = ui.Gradient.linear(
              Offset(0.0, fadeStart),
              Offset(0.0, fadeEnd),
              <Color>[const Color(0xFFFFFFFF), const Color(0x00FFFFFF)],
            );
          }
          fadeSizePainter.dispose();
      }
    } else {
      _needsClipping = false;
      _overflowShader = null;
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    defaultApplyPaintTransform(child, transform);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Ideally we could compute the min/max intrinsic width/height with a
    // non-destructive operation. However, currently, computing these values
    // will destroy state inside the painter. If that happens, we need to get
    // back the correct state by calling _layout again.
    //
    // TODO(abarth): Make computing the min/max intrinsic width/height a
    //  non-destructive operation.
    //
    // If you remove this call, make sure that changing the textAlign still
    // works properly.
    _layoutTextWithConstraints(constraints);

    assert(() {
      if (debugRepaintTextRainbowEnabled) {
        final Paint paint = Paint()
          ..color = debugCurrentRepaintColor.toColor();
        context.canvas.drawRect(offset & size, paint);
      }
      return true;
    }());

    if (_needsClipping) {
      final Rect bounds = offset & size;
      if (_overflowShader != null) {
        // This layer limits what the shader below blends with to be just the
        // text (as opposed to the text and its background).
        context.canvas.saveLayer(bounds, Paint());
      } else {
        context.canvas.save();
      }
      context.canvas.clipRect(bounds);
    }

    if (_lastSelectableFragments != null) {
      for (final _SelectableFragment fragment in _lastSelectableFragments!) {
        fragment.paint(context, offset);
      }
    }

    _textPainter.paint(context.canvas, offset);

    paintInlineChildren(context, offset);

    if (_needsClipping) {
      if (_overflowShader != null) {
        context.canvas.translate(offset.dx, offset.dy);
        final Paint paint = Paint()
          ..blendMode = BlendMode.modulate
          ..shader = _overflowShader;
        context.canvas.drawRect(Offset.zero & size, paint);
      }
      context.canvas.restore();
    }
  }

  /// Returns the offset at which to paint the caret.
  ///
  /// Valid only after [layout].
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    assert(!debugNeedsLayout);
    _layoutTextWithConstraints(constraints);
    return _textPainter.getOffsetForCaret(position, caretPrototype);
  }

  /// {@macro flutter.painting.textPainter.getFullHeightForCaret}
  ///
  /// Valid only after [layout].
  double? getFullHeightForCaret(TextPosition position) {
    assert(!debugNeedsLayout);
    _layoutTextWithConstraints(constraints);
    return _textPainter.getFullHeightForCaret(position, Rect.zero);
  }

  /// Returns a list of rects that bound the given selection.
  ///
  /// The [boxHeightStyle] and [boxWidthStyle] arguments may be used to select
  /// the shape of the [TextBox]es. These properties default to
  /// [ui.BoxHeightStyle.tight] and [ui.BoxWidthStyle.tight] respectively and
  /// must not be null.
  ///
  /// A given selection might have more than one rect if the [RenderParagraph]
  /// contains multiple [InlineSpan]s or bidirectional text, because logically
  /// contiguous text might not be visually contiguous.
  ///
  /// Valid only after [layout].
  ///
  /// See also:
  ///
  ///  * [TextPainter.getBoxesForSelection], the method in TextPainter to get
  ///    the equivalent boxes.
  List<ui.TextBox> getBoxesForSelection(
    TextSelection selection, {
    ui.BoxHeightStyle boxHeightStyle = ui.BoxHeightStyle.tight,
    ui.BoxWidthStyle boxWidthStyle = ui.BoxWidthStyle.tight,
  }) {
    assert(!debugNeedsLayout);
    _layoutTextWithConstraints(constraints);
    return _textPainter.getBoxesForSelection(
      selection,
      boxHeightStyle: boxHeightStyle,
      boxWidthStyle: boxWidthStyle,
    );
  }

  /// Returns the position within the text for the given pixel offset.
  ///
  /// Valid only after [layout].
  TextPosition getPositionForOffset(Offset offset) {
    assert(!debugNeedsLayout);
    _layoutTextWithConstraints(constraints);
    return _textPainter.getPositionForOffset(offset);
  }

  /// Returns the text range of the word at the given offset. Characters not
  /// part of a word, such as spaces, symbols, and punctuation, have word breaks
  /// on both sides. In such cases, this method will return a text range that
  /// contains the given text position.
  ///
  /// Word boundaries are defined more precisely in Unicode Standard Annex #29
  /// <http://www.unicode.org/reports/tr29/#Word_Boundaries>.
  ///
  /// Valid only after [layout].
  TextRange getWordBoundary(TextPosition position) {
    assert(!debugNeedsLayout);
    _layoutTextWithConstraints(constraints);
    return _textPainter.getWordBoundary(position);
  }

  TextRange _getLineAtOffset(TextPosition position) => _textPainter.getLineBoundary(position);

  TextPosition _getTextPositionAbove(TextPosition position) {
    // -0.5 of preferredLineHeight points to the middle of the line above.
    final double preferredLineHeight = _textPainter.preferredLineHeight;
    final double verticalOffset = -0.5 * preferredLineHeight;
    return _getTextPositionVertical(position, verticalOffset);
  }

  TextPosition _getTextPositionBelow(TextPosition position) {
    // 1.5 of preferredLineHeight points to the middle of the line below.
    final double preferredLineHeight = _textPainter.preferredLineHeight;
    final double verticalOffset = 1.5 * preferredLineHeight;
    return _getTextPositionVertical(position, verticalOffset);
  }

  TextPosition _getTextPositionVertical(TextPosition position, double verticalOffset) {
    final Offset caretOffset = _textPainter.getOffsetForCaret(position, Rect.zero);
    final Offset caretOffsetTranslated = caretOffset.translate(0.0, verticalOffset);
    return _textPainter.getPositionForOffset(caretOffsetTranslated);
  }

  /// Returns the size of the text as laid out.
  ///
  /// This can differ from [size] if the text overflowed or if the [constraints]
  /// provided by the parent [RenderObject] forced the layout to be bigger than
  /// necessary for the given [text].
  ///
  /// This returns the [TextPainter.size] of the underlying [TextPainter].
  ///
  /// Valid only after [layout].
  Size get textSize {
    assert(!debugNeedsLayout);
    return _textPainter.size;
  }

  /// Collected during [describeSemanticsConfiguration], used by
  /// [assembleSemanticsNode] and [_combineSemanticsInfo].
  List<InlineSpanSemanticsInformation>? _semanticsInfo;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    _semanticsInfo = text.getSemanticsInformation();
    bool needsAssembleSemanticsNode = false;
    bool needsChildConfigrationsDelegate = false;
    for (final InlineSpanSemanticsInformation info in _semanticsInfo!) {
      if (info.recognizer != null) {
        needsAssembleSemanticsNode = true;
        break;
      }
      needsChildConfigrationsDelegate = needsChildConfigrationsDelegate || info.isPlaceholder;
    }

    if (needsAssembleSemanticsNode) {
      config.explicitChildNodes = true;
      config.isSemanticBoundary = true;
    } else if (needsChildConfigrationsDelegate) {
      config.childConfigurationsDelegate = _childSemanticsConfigurationsDelegate;
    } else {
      if (_cachedAttributedLabels == null) {
        final StringBuffer buffer = StringBuffer();
        int offset = 0;
        final List<StringAttribute> attributes = <StringAttribute>[];
        for (final InlineSpanSemanticsInformation info in _semanticsInfo!) {
          final String label = info.semanticsLabel ?? info.text;
          for (final StringAttribute infoAttribute in info.stringAttributes) {
            final TextRange originalRange = infoAttribute.range;
            attributes.add(
              infoAttribute.copy(
                range: TextRange(
                  start: offset + originalRange.start,
                  end: offset + originalRange.end,
                ),
              ),
            );
          }
          buffer.write(label);
          offset += label.length;
        }
        _cachedAttributedLabels = <AttributedString>[AttributedString(buffer.toString(), attributes: attributes)];
      }
      config.attributedLabel = _cachedAttributedLabels![0];
      config.textDirection = textDirection;
    }
  }

  ChildSemanticsConfigurationsResult _childSemanticsConfigurationsDelegate(List<SemanticsConfiguration> childConfigs) {
    final ChildSemanticsConfigurationsResultBuilder builder = ChildSemanticsConfigurationsResultBuilder();
    int placeholderIndex = 0;
    int childConfigsIndex = 0;
    int attributedLabelCacheIndex = 0;
    InlineSpanSemanticsInformation? seenTextInfo;
    _cachedCombinedSemanticsInfos ??= combineSemanticsInfo(_semanticsInfo!);
    for (final InlineSpanSemanticsInformation info in _cachedCombinedSemanticsInfos!) {
      if (info.isPlaceholder) {
        if (seenTextInfo != null) {
          builder.markAsMergeUp(_createSemanticsConfigForTextInfo(seenTextInfo, attributedLabelCacheIndex));
          attributedLabelCacheIndex += 1;
        }
        // Mark every childConfig belongs to this placeholder to merge up group.
        while (childConfigsIndex < childConfigs.length &&
            childConfigs[childConfigsIndex].tagsChildrenWith(PlaceholderSpanIndexSemanticsTag(placeholderIndex))) {
          builder.markAsMergeUp(childConfigs[childConfigsIndex]);
          childConfigsIndex += 1;
        }
        placeholderIndex += 1;
      } else {
        seenTextInfo = info;
      }
    }

    // Handle plain text info at the end.
    if (seenTextInfo != null) {
      builder.markAsMergeUp(_createSemanticsConfigForTextInfo(seenTextInfo, attributedLabelCacheIndex));
    }
    return builder.build();
  }

  SemanticsConfiguration _createSemanticsConfigForTextInfo(InlineSpanSemanticsInformation textInfo, int cacheIndex) {
    assert(!textInfo.requiresOwnNode);
    final List<AttributedString> cachedStrings = _cachedAttributedLabels ??= <AttributedString>[];
    assert(cacheIndex <= cachedStrings.length);
    final bool hasCache = cacheIndex < cachedStrings.length;

    late AttributedString attributedLabel;
    if (hasCache) {
      attributedLabel = cachedStrings[cacheIndex];
    } else {
      assert(cachedStrings.length == cacheIndex);
      attributedLabel = AttributedString(
        textInfo.semanticsLabel ?? textInfo.text,
        attributes: textInfo.stringAttributes,
      );
      cachedStrings.add(attributedLabel);
    }
    return SemanticsConfiguration()
      ..textDirection = textDirection
      ..attributedLabel = attributedLabel;
  }

  // Caches [SemanticsNode]s created during [assembleSemanticsNode] so they
  // can be re-used when [assembleSemanticsNode] is called again. This ensures
  // stable ids for the [SemanticsNode]s of [TextSpan]s across
  // [assembleSemanticsNode] invocations.
  LinkedHashMap<Key, SemanticsNode>? _cachedChildNodes;

  @override
  void assembleSemanticsNode(SemanticsNode node, SemanticsConfiguration config, Iterable<SemanticsNode> children) {
    assert(_semanticsInfo != null && _semanticsInfo!.isNotEmpty);
    final List<SemanticsNode> newChildren = <SemanticsNode>[];
    TextDirection currentDirection = textDirection;
    Rect currentRect;
    double ordinal = 0.0;
    int start = 0;
    int placeholderIndex = 0;
    int childIndex = 0;
    RenderBox? child = firstChild;
    final LinkedHashMap<Key, SemanticsNode> newChildCache = LinkedHashMap<Key, SemanticsNode>();
    _cachedCombinedSemanticsInfos ??= combineSemanticsInfo(_semanticsInfo!);
    for (final InlineSpanSemanticsInformation info in _cachedCombinedSemanticsInfos!) {
      final TextSelection selection = TextSelection(
        baseOffset: start,
        extentOffset: start + info.text.length,
      );
      start += info.text.length;

      if (info.isPlaceholder) {
        // A placeholder span may have 0 to multiple semantics nodes, we need
        // to annotate all of the semantics nodes belong to this span.
        while (children.length > childIndex &&
               children.elementAt(childIndex).isTagged(PlaceholderSpanIndexSemanticsTag(placeholderIndex))) {
          final SemanticsNode childNode = children.elementAt(childIndex);
          final TextParentData parentData = child!.parentData! as TextParentData;
          // parentData.scale may be null if the render object is truncated.
          if (parentData.offset != null) {
            newChildren.add(childNode);
          }
          childIndex += 1;
        }
        child = childAfter(child!);
        placeholderIndex += 1;
      } else {
        final TextDirection initialDirection = currentDirection;
        final List<ui.TextBox> rects = getBoxesForSelection(selection);
        if (rects.isEmpty) {
          continue;
        }
        Rect rect = rects.first.toRect();
        currentDirection = rects.first.direction;
        for (final ui.TextBox textBox in rects.skip(1)) {
          rect = rect.expandToInclude(textBox.toRect());
          currentDirection = textBox.direction;
        }
        // Any of the text boxes may have had infinite dimensions.
        // We shouldn't pass infinite dimensions up to the bridges.
        rect = Rect.fromLTWH(
          math.max(0.0, rect.left),
          math.max(0.0, rect.top),
          math.min(rect.width, constraints.maxWidth),
          math.min(rect.height, constraints.maxHeight),
        );
        // round the current rectangle to make this API testable and add some
        // padding so that the accessibility rects do not overlap with the text.
        currentRect = Rect.fromLTRB(
          rect.left.floorToDouble() - 4.0,
          rect.top.floorToDouble() - 4.0,
          rect.right.ceilToDouble() + 4.0,
          rect.bottom.ceilToDouble() + 4.0,
        );
        final SemanticsConfiguration configuration = SemanticsConfiguration()
          ..sortKey = OrdinalSortKey(ordinal++)
          ..textDirection = initialDirection
          ..attributedLabel = AttributedString(info.semanticsLabel ?? info.text, attributes: info.stringAttributes);
        final GestureRecognizer? recognizer = info.recognizer;
        if (recognizer != null) {
          if (recognizer is TapGestureRecognizer) {
            if (recognizer.onTap != null) {
              configuration.onTap = recognizer.onTap;
              configuration.isLink = true;
            }
          } else if (recognizer is DoubleTapGestureRecognizer) {
            if (recognizer.onDoubleTap != null) {
              configuration.onTap = recognizer.onDoubleTap;
              configuration.isLink = true;
            }
          } else if (recognizer is LongPressGestureRecognizer) {
            if (recognizer.onLongPress != null) {
              configuration.onLongPress = recognizer.onLongPress;
            }
          } else {
            assert(false, '${recognizer.runtimeType} is not supported.');
          }
        }
        if (node.parentPaintClipRect != null) {
          final Rect paintRect = node.parentPaintClipRect!.intersect(currentRect);
          configuration.isHidden = paintRect.isEmpty && !currentRect.isEmpty;
        }
        late final SemanticsNode newChild;
        if (_cachedChildNodes?.isNotEmpty ?? false) {
          newChild = _cachedChildNodes!.remove(_cachedChildNodes!.keys.first)!;
        } else {
          final UniqueKey key = UniqueKey();
          newChild = SemanticsNode(
            key: key,
            showOnScreen: _createShowOnScreenFor(key),
          );
        }
        newChild
          ..updateWith(config: configuration)
          ..rect = currentRect;
        newChildCache[newChild.key!] = newChild;
        newChildren.add(newChild);
      }
    }
    // Makes sure we annotated all of the semantics children.
    assert(childIndex == children.length);
    assert(child == null);

    _cachedChildNodes = newChildCache;
    node.updateWith(config: config, childrenInInversePaintOrder: newChildren);
  }

  VoidCallback? _createShowOnScreenFor(Key key) {
    return () {
      final SemanticsNode node = _cachedChildNodes![key]!;
      showOnScreen(descendant: this, rect: node.rect);
    };
  }

  @override
  void clearSemantics() {
    super.clearSemantics();
    _cachedChildNodes = null;
  }

  @override
  List<DiagnosticsNode> debugDescribeChildren() {
    return <DiagnosticsNode>[
      text.toDiagnosticsNode(
        name: 'text',
        style: DiagnosticsTreeStyle.transition,
      ),
    ];
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(EnumProperty<TextAlign>('textAlign', textAlign));
    properties.add(EnumProperty<TextDirection>('textDirection', textDirection));
    properties.add(
      FlagProperty(
        'softWrap',
        value: softWrap,
        ifTrue: 'wrapping at box width',
        ifFalse: 'no wrapping except at line break characters',
        showName: true,
      ),
    );
    properties.add(EnumProperty<TextOverflow>('overflow', overflow));
    properties.add(
      DiagnosticsProperty<TextScaler>('textScaler', textScaler, defaultValue: TextScaler.noScaling),
    );
    properties.add(
      DiagnosticsProperty<Locale>(
        'locale',
        locale,
        defaultValue: null,
      ),
    );
    properties.add(IntProperty('maxLines', maxLines, ifNull: 'unlimited'));
  }
}

/// A continuous, selectable piece of paragraph.
///
/// Since the selections in [PlaceHolderSpan] are handled independently in its
/// subtree, a selection in [RenderParagraph] can't continue across a
/// [PlaceHolderSpan]. The [RenderParagraph] splits itself on [PlaceHolderSpan]
/// to create multiple `_SelectableFragment`s so that they can be selected
/// separately.
class _SelectableFragment with Selectable, ChangeNotifier implements TextLayoutMetrics {
  _SelectableFragment({
    required this.paragraph,
    required this.fullText,
    required this.range,
  }) : assert(range.isValid && !range.isCollapsed && range.isNormalized) {
    if (kFlutterMemoryAllocationsEnabled) {
      maybeDispatchObjectCreation();
    }
    _selectionGeometry = _getSelectionGeometry();
  }

  final TextRange range;
  final RenderParagraph paragraph;
  final String fullText;

  TextPosition? _textSelectionStart;
  TextPosition? _textSelectionEnd;

  bool _selectableContainsOriginWord = false;

  LayerLink? _startHandleLayerLink;
  LayerLink? _endHandleLayerLink;

  @override
  SelectionGeometry get value => _selectionGeometry;
  late SelectionGeometry _selectionGeometry;
  void _updateSelectionGeometry() {
    final SelectionGeometry newValue = _getSelectionGeometry();
    if (_selectionGeometry == newValue) {
      return;
    }
    _selectionGeometry = newValue;
    notifyListeners();
  }

  SelectionGeometry _getSelectionGeometry() {
    if (_textSelectionStart == null || _textSelectionEnd == null) {
      return const SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: true,
      );
    }

    final int selectionStart = _textSelectionStart!.offset;
    final int selectionEnd = _textSelectionEnd!.offset;
    final bool isReversed = selectionStart > selectionEnd;
    final Offset startOffsetInParagraphCoordinates = paragraph._getOffsetForPosition(TextPosition(offset: selectionStart));
    final Offset endOffsetInParagraphCoordinates = selectionStart == selectionEnd
      ? startOffsetInParagraphCoordinates
      : paragraph._getOffsetForPosition(TextPosition(offset: selectionEnd));
    final bool flipHandles = isReversed != (TextDirection.rtl == paragraph.textDirection);
    final Matrix4 paragraphToFragmentTransform = getTransformToParagraph()..invert();
    final TextSelection selection = TextSelection(
      baseOffset: selectionStart,
      extentOffset: selectionEnd,
    );
    final List<Rect> selectionRects = <Rect>[];
    for (final TextBox textBox in paragraph.getBoxesForSelection(selection)) {
      selectionRects.add(textBox.toRect());
    }
    return SelectionGeometry(
      startSelectionPoint: SelectionPoint(
        localPosition: MatrixUtils.transformPoint(paragraphToFragmentTransform, startOffsetInParagraphCoordinates),
        lineHeight: paragraph._textPainter.preferredLineHeight,
        handleType: flipHandles ? TextSelectionHandleType.right : TextSelectionHandleType.left
      ),
      endSelectionPoint: SelectionPoint(
        localPosition: MatrixUtils.transformPoint(paragraphToFragmentTransform, endOffsetInParagraphCoordinates),
        lineHeight: paragraph._textPainter.preferredLineHeight,
        handleType: flipHandles ? TextSelectionHandleType.left : TextSelectionHandleType.right,
      ),
      selectionRects: selectionRects,
      status: _textSelectionStart!.offset == _textSelectionEnd!.offset
        ? SelectionStatus.collapsed
        : SelectionStatus.uncollapsed,
      hasContent: true,
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    late final SelectionResult result;
    final TextPosition? existingSelectionStart = _textSelectionStart;
    final TextPosition? existingSelectionEnd = _textSelectionEnd;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        final SelectionEdgeUpdateEvent edgeUpdate = event as SelectionEdgeUpdateEvent;
        final TextGranularity granularity = event.granularity;

        switch (granularity) {
          case TextGranularity.character:
            result = _updateSelectionEdge(edgeUpdate.globalPosition, isEnd: edgeUpdate.type == SelectionEventType.endEdgeUpdate);
          case TextGranularity.word:
            result = _updateSelectionEdgeByWord(edgeUpdate.globalPosition, isEnd: edgeUpdate.type == SelectionEventType.endEdgeUpdate);
          case TextGranularity.document:
          case TextGranularity.line:
            assert(false, 'Moving the selection edge by line or document is not supported.');
        }
      case SelectionEventType.clear:
        result = _handleClearSelection();
      case SelectionEventType.selectAll:
        result = _handleSelectAll();
      case SelectionEventType.selectWord:
        final SelectWordSelectionEvent selectWord = event as SelectWordSelectionEvent;
        result = _handleSelectWord(selectWord.globalPosition);
      case SelectionEventType.granularlyExtendSelection:
        final GranularlyExtendSelectionEvent granularlyExtendSelection = event as GranularlyExtendSelectionEvent;
        result = _handleGranularlyExtendSelection(
          granularlyExtendSelection.forward,
          granularlyExtendSelection.isEnd,
          granularlyExtendSelection.granularity,
        );
      case SelectionEventType.directionallyExtendSelection:
        final DirectionallyExtendSelectionEvent directionallyExtendSelection = event as DirectionallyExtendSelectionEvent;
        result = _handleDirectionallyExtendSelection(
          directionallyExtendSelection.dx,
          directionallyExtendSelection.isEnd,
          directionallyExtendSelection.direction,
        );
    }

    if (existingSelectionStart != _textSelectionStart ||
        existingSelectionEnd != _textSelectionEnd) {
      _didChangeSelection();
    }
    return result;
  }

  @override
  SelectedContent? getSelectedContent() {
    if (_textSelectionStart == null || _textSelectionEnd == null) {
      return null;
    }
    final int start = math.min(_textSelectionStart!.offset, _textSelectionEnd!.offset);
    final int end = math.max(_textSelectionStart!.offset, _textSelectionEnd!.offset);
    return SelectedContent(
      plainText: fullText.substring(start, end),
    );
  }

  void _didChangeSelection() {
    paragraph.markNeedsPaint();
    _updateSelectionGeometry();
  }

  SelectionResult _updateSelectionEdge(Offset globalPosition, {required bool isEnd}) {
    _setSelectionPosition(null, isEnd: isEnd);
    final Matrix4 transform = paragraph.getTransformTo(null);
    transform.invert();
    final Offset localPosition = MatrixUtils.transformPoint(transform, globalPosition);
    if (_rect.isEmpty) {
      return SelectionUtils.getResultBasedOnRect(_rect, localPosition);
    }
    final Offset adjustedOffset = SelectionUtils.adjustDragOffset(
      _rect,
      localPosition,
      direction: paragraph.textDirection,
    );

    final TextPosition position = _clampTextPosition(paragraph.getPositionForOffset(adjustedOffset));
    _setSelectionPosition(position, isEnd: isEnd);
    if (position.offset == range.end) {
      return SelectionResult.next;
    }
    if (position.offset == range.start) {
      return SelectionResult.previous;
    }
    // TODO(chunhtai): The geometry information should not be used to determine
    // selection result. This is a workaround to RenderParagraph, where it does
    // not have a way to get accurate text length if its text is truncated due to
    // layout constraint.
    return SelectionUtils.getResultBasedOnRect(_rect, localPosition);
  }

  TextPosition _closestWordBoundary(
    _WordBoundaryRecord wordBoundary,
    TextPosition position,
  ) {
    final int differenceA = (position.offset - wordBoundary.wordStart.offset).abs();
    final int differenceB = (position.offset - wordBoundary.wordEnd.offset).abs();
    return differenceA < differenceB ? wordBoundary.wordStart : wordBoundary.wordEnd;
  }

  TextPosition _updateSelectionStartEdgeByWord(
    _WordBoundaryRecord? wordBoundary,
    TextPosition position,
    TextPosition? existingSelectionStart,
    TextPosition? existingSelectionEnd,
  ) {
    TextPosition? targetPosition;
    if (wordBoundary != null) {
      assert(wordBoundary.wordStart.offset >= range.start && wordBoundary.wordEnd.offset <= range.end);
      if (_selectableContainsOriginWord && existingSelectionStart != null && existingSelectionEnd != null) {
        final bool isSamePosition = position.offset == existingSelectionEnd.offset;
        final bool isSelectionInverted = existingSelectionStart.offset > existingSelectionEnd.offset;
        final bool shouldSwapEdges = !isSamePosition && (isSelectionInverted != (position.offset > existingSelectionEnd.offset));
        if (shouldSwapEdges) {
          if (position.offset < existingSelectionEnd.offset) {
            targetPosition = wordBoundary.wordStart;
          } else {
            targetPosition = wordBoundary.wordEnd;
          }
          // When the selection is inverted by the new position it is necessary to
          // swap the start edge (moving edge) with the end edge (static edge) to
          // maintain the origin word within the selection.
          final _WordBoundaryRecord localWordBoundary = _getWordBoundaryAtPosition(existingSelectionEnd);
          assert(localWordBoundary.wordStart.offset >= range.start && localWordBoundary.wordEnd.offset <= range.end);
          _setSelectionPosition(existingSelectionEnd.offset == localWordBoundary.wordStart.offset ? localWordBoundary.wordEnd : localWordBoundary.wordStart, isEnd: true);
        } else {
          if (position.offset < existingSelectionEnd.offset) {
            targetPosition = wordBoundary.wordStart;
          } else if (position.offset > existingSelectionEnd.offset) {
            targetPosition = wordBoundary.wordEnd;
          } else {
            // Keep the origin word in bounds when position is at the static edge.
            targetPosition = existingSelectionStart;
          }
        }
      } else {
        if (existingSelectionEnd != null) {
          // If the end edge exists and the start edge is being moved, then the
          // start edge is moved to encompass the entire word at the new position.
          if (position.offset < existingSelectionEnd.offset) {
            targetPosition = wordBoundary.wordStart;
          } else {
            targetPosition = wordBoundary.wordEnd;
          }
        } else {
          // Move the start edge to the closest word boundary.
          targetPosition = _closestWordBoundary(wordBoundary, position);
        }
      }
    } else {
      // The position is not contained within the current rect. The targetPosition
      // will either be at the end or beginning of the current rect. See [SelectionUtils.adjustDragOffset]
      // for a more in depth explanation on this adjustment.
      if (_selectableContainsOriginWord && existingSelectionStart != null && existingSelectionEnd != null) {
        // When the selection is inverted by the new position it is necessary to
        // swap the start edge (moving edge) with the end edge (static edge) to
        // maintain the origin word within the selection.
        final bool isSamePosition = position.offset == existingSelectionEnd.offset;
        final bool isSelectionInverted = existingSelectionStart.offset > existingSelectionEnd.offset;
        final bool shouldSwapEdges = !isSamePosition && (isSelectionInverted != (position.offset > existingSelectionEnd.offset));

        if (shouldSwapEdges) {
          final _WordBoundaryRecord localWordBoundary = _getWordBoundaryAtPosition(existingSelectionEnd);
          assert(localWordBoundary.wordStart.offset >= range.start && localWordBoundary.wordEnd.offset <= range.end);
          _setSelectionPosition(isSelectionInverted ? localWordBoundary.wordEnd : localWordBoundary.wordStart, isEnd: true);
        }
      }
    }
    return targetPosition ?? position;
  }

  TextPosition _updateSelectionEndEdgeByWord(
    _WordBoundaryRecord? wordBoundary,
    TextPosition position,
    TextPosition? existingSelectionStart,
    TextPosition? existingSelectionEnd,
  ) {
    TextPosition? targetPosition;
    if (wordBoundary != null) {
      assert(wordBoundary.wordStart.offset >= range.start && wordBoundary.wordEnd.offset <= range.end);
      if (_selectableContainsOriginWord && existingSelectionStart != null && existingSelectionEnd != null) {
        final bool isSamePosition = position.offset == existingSelectionStart.offset;
        final bool isSelectionInverted = existingSelectionStart.offset > existingSelectionEnd.offset;
        final bool shouldSwapEdges = !isSamePosition && (isSelectionInverted != (position.offset < existingSelectionStart.offset));
        if (shouldSwapEdges) {
          if (position.offset < existingSelectionStart.offset) {
            targetPosition = wordBoundary.wordStart;
          } else {
            targetPosition = wordBoundary.wordEnd;
          }
          // When the selection is inverted by the new position it is necessary to
          // swap the end edge (moving edge) with the start edge (static edge) to
          // maintain the origin word within the selection.
          final _WordBoundaryRecord localWordBoundary = _getWordBoundaryAtPosition(existingSelectionStart);
          assert(localWordBoundary.wordStart.offset >= range.start && localWordBoundary.wordEnd.offset <= range.end);
          _setSelectionPosition(existingSelectionStart.offset == localWordBoundary.wordStart.offset ? localWordBoundary.wordEnd : localWordBoundary.wordStart, isEnd: false);
        } else {
          if (position.offset < existingSelectionStart.offset) {
            targetPosition = wordBoundary.wordStart;
          } else if (position.offset > existingSelectionStart.offset) {
            targetPosition = wordBoundary.wordEnd;
          } else {
            // Keep the origin word in bounds when position is at the static edge.
            targetPosition = existingSelectionEnd;
          }
        }
      } else {
        if (existingSelectionStart != null) {
          // If the start edge exists and the end edge is being moved, then the
          // end edge is moved to encompass the entire word at the new position.
          if (position.offset < existingSelectionStart.offset) {
            targetPosition = wordBoundary.wordStart;
          } else {
            targetPosition = wordBoundary.wordEnd;
          }
        } else {
          // Move the end edge to the closest word boundary.
          targetPosition = _closestWordBoundary(wordBoundary, position);
        }
      }
    } else {
      // The position is not contained within the current rect. The targetPosition
      // will either be at the end or beginning of the current rect. See [SelectionUtils.adjustDragOffset]
      // for a more in depth explanation on this adjustment.
      if (_selectableContainsOriginWord && existingSelectionStart != null && existingSelectionEnd != null) {
        // When the selection is inverted by the new position it is necessary to
        // swap the end edge (moving edge) with the start edge (static edge) to
        // maintain the origin word within the selection.
        final bool isSamePosition = position.offset == existingSelectionStart.offset;
        final bool isSelectionInverted = existingSelectionStart.offset > existingSelectionEnd.offset;
        final bool shouldSwapEdges = isSelectionInverted != (position.offset < existingSelectionStart.offset) || isSamePosition;
        if (shouldSwapEdges) {
          final _WordBoundaryRecord localWordBoundary = _getWordBoundaryAtPosition(existingSelectionStart);
          assert(localWordBoundary.wordStart.offset >= range.start && localWordBoundary.wordEnd.offset <= range.end);
          _setSelectionPosition(isSelectionInverted ? localWordBoundary.wordStart : localWordBoundary.wordEnd, isEnd: false);
        }
      }
    }
    return targetPosition ?? position;
  }

  SelectionResult _updateSelectionEdgeByWord(Offset globalPosition, {required bool isEnd}) {
    // When the start/end edges are swapped, i.e. the start is after the end, and
    // the scrollable synthesizes an event for the opposite edge, this will potentially
    // move the opposite edge outside of the origin word boundary and we are unable to recover.
    final TextPosition? existingSelectionStart = _textSelectionStart;
    final TextPosition? existingSelectionEnd = _textSelectionEnd;

    _setSelectionPosition(null, isEnd: isEnd);
    final Matrix4 transform = paragraph.getTransformTo(null);
    transform.invert();
    final Offset localPosition = MatrixUtils.transformPoint(transform, globalPosition);
    if (_rect.isEmpty) {
      return SelectionUtils.getResultBasedOnRect(_rect, localPosition);
    }
    final Offset adjustedOffset = SelectionUtils.adjustDragOffset(
      _rect,
      localPosition,
      direction: paragraph.textDirection,
    );

    final TextPosition position = paragraph.getPositionForOffset(adjustedOffset);
    // Check if the original local position is within the rect, if it is not then
    // we do not need to look up the word boundary for that position. This is to
    // maintain a selectables selection collapsed at 0 when the local position is
    // not located inside its rect.
    final _WordBoundaryRecord? wordBoundary = !_rect.contains(localPosition) ? null : _getWordBoundaryAtPosition(position);
    final TextPosition targetPosition = _clampTextPosition(isEnd ? _updateSelectionEndEdgeByWord(wordBoundary, position, existingSelectionStart, existingSelectionEnd) : _updateSelectionStartEdgeByWord(wordBoundary, position, existingSelectionStart, existingSelectionEnd));

    _setSelectionPosition(targetPosition, isEnd: isEnd);
    if (targetPosition.offset == range.end) {
      return SelectionResult.next;
    }

    if (targetPosition.offset == range.start) {
      return SelectionResult.previous;
    }
    // TODO(chunhtai): The geometry information should not be used to determine
    // selection result. This is a workaround to RenderParagraph, where it does
    // not have a way to get accurate text length if its text is truncated due to
    // layout constraint.
    return SelectionUtils.getResultBasedOnRect(_rect, localPosition);
  }

  TextPosition _clampTextPosition(TextPosition position) {
    // Affinity of range.end is upstream.
    if (position.offset > range.end ||
        (position.offset == range.end && position.affinity == TextAffinity.downstream)) {
      return TextPosition(offset: range.end, affinity: TextAffinity.upstream);
    }
    if (position.offset < range.start) {
      return TextPosition(offset: range.start);
    }
    return position;
  }

  void _setSelectionPosition(TextPosition? position, {required bool isEnd}) {
    if (isEnd) {
      _textSelectionEnd = position;
    } else {
      _textSelectionStart = position;
    }
  }

  SelectionResult _handleClearSelection() {
    _textSelectionStart = null;
    _textSelectionEnd = null;
    _selectableContainsOriginWord = false;
    return SelectionResult.none;
  }

  SelectionResult _handleSelectAll() {
    _textSelectionStart = TextPosition(offset: range.start);
    _textSelectionEnd = TextPosition(offset: range.end, affinity: TextAffinity.upstream);
    return SelectionResult.none;
  }

  SelectionResult _handleSelectWord(Offset globalPosition) {
    _selectableContainsOriginWord = true;

    final TextPosition position = paragraph.getPositionForOffset(paragraph.globalToLocal(globalPosition));
    if (_positionIsWithinCurrentSelection(position)) {
      return SelectionResult.end;
    }
    final _WordBoundaryRecord wordBoundary = _getWordBoundaryAtPosition(position);
    if (wordBoundary.wordStart.offset < range.start && wordBoundary.wordEnd.offset < range.start) {
      return SelectionResult.previous;
    } else if (wordBoundary.wordStart.offset > range.end && wordBoundary.wordEnd.offset > range.end) {
      return SelectionResult.next;
    }
    // Fragments are separated by placeholder span, the word boundary shouldn't
    // expand across fragments.
    assert(wordBoundary.wordStart.offset >= range.start && wordBoundary.wordEnd.offset <= range.end);
    _textSelectionStart = wordBoundary.wordStart;
    _textSelectionEnd = wordBoundary.wordEnd;
    return SelectionResult.end;
  }

  _WordBoundaryRecord _getWordBoundaryAtPosition(TextPosition position) {
    final TextRange word = paragraph.getWordBoundary(position);
    assert(word.isNormalized);
    late TextPosition start;
    late TextPosition end;
    if (position.offset > word.end) {
      start = end = TextPosition(offset: position.offset);
    } else {
      start = TextPosition(offset: word.start);
      end = TextPosition(offset: word.end, affinity: TextAffinity.upstream);
    }
    return (wordStart: start, wordEnd: end);
  }

  SelectionResult _handleDirectionallyExtendSelection(double horizontalBaseline, bool isExtent, SelectionExtendDirection movement) {
    final Matrix4 transform = paragraph.getTransformTo(null);
    if (transform.invert() == 0.0) {
      switch (movement) {
        case SelectionExtendDirection.previousLine:
        case SelectionExtendDirection.backward:
          return SelectionResult.previous;
        case SelectionExtendDirection.nextLine:
        case SelectionExtendDirection.forward:
          return SelectionResult.next;
      }
    }
    final double baselineInParagraphCoordinates = MatrixUtils.transformPoint(transform, Offset(horizontalBaseline, 0)).dx;
    assert(!baselineInParagraphCoordinates.isNaN);
    final TextPosition newPosition;
    final SelectionResult result;
    switch (movement) {
      case SelectionExtendDirection.previousLine:
      case SelectionExtendDirection.nextLine:
        assert(_textSelectionEnd != null && _textSelectionStart != null);
        final TextPosition targetedEdge = isExtent ? _textSelectionEnd! : _textSelectionStart!;
        final MapEntry<TextPosition, SelectionResult> moveResult = _handleVerticalMovement(
          targetedEdge,
          horizontalBaselineInParagraphCoordinates: baselineInParagraphCoordinates,
          below: movement == SelectionExtendDirection.nextLine,
        );
        newPosition = moveResult.key;
        result = moveResult.value;
      case SelectionExtendDirection.forward:
      case SelectionExtendDirection.backward:
        _textSelectionEnd ??= movement == SelectionExtendDirection.forward
          ? TextPosition(offset: range.start)
          : TextPosition(offset: range.end, affinity: TextAffinity.upstream);
        _textSelectionStart ??= _textSelectionEnd;
        final TextPosition targetedEdge = isExtent ? _textSelectionEnd! : _textSelectionStart!;
        final Offset edgeOffsetInParagraphCoordinates = paragraph._getOffsetForPosition(targetedEdge);
        final Offset baselineOffsetInParagraphCoordinates = Offset(
          baselineInParagraphCoordinates,
          // Use half of line height to point to the middle of the line.
          edgeOffsetInParagraphCoordinates.dy - paragraph._textPainter.preferredLineHeight / 2,
        );
        newPosition = paragraph.getPositionForOffset(baselineOffsetInParagraphCoordinates);
        result = SelectionResult.end;
    }
    if (isExtent) {
      _textSelectionEnd = newPosition;
    } else {
      _textSelectionStart = newPosition;
    }
    return result;
  }

  SelectionResult _handleGranularlyExtendSelection(bool forward, bool isExtent, TextGranularity granularity) {
    _textSelectionEnd ??= forward
        ? TextPosition(offset: range.start)
        : TextPosition(offset: range.end, affinity: TextAffinity.upstream);
    _textSelectionStart ??= _textSelectionEnd;
    final TextPosition targetedEdge = isExtent ? _textSelectionEnd! : _textSelectionStart!;
    if (forward && (targetedEdge.offset == range.end)) {
      return SelectionResult.next;
    }
    if (!forward && (targetedEdge.offset == range.start)) {
      return SelectionResult.previous;
    }
    final SelectionResult result;
    final TextPosition newPosition;
    switch (granularity) {
      case TextGranularity.character:
        final String text = range.textInside(fullText);
        newPosition = _moveBeyondTextBoundaryAtDirection(targetedEdge, forward, CharacterBoundary(text));
        result = SelectionResult.end;
      case TextGranularity.word:
        final TextBoundary textBoundary = paragraph._textPainter.wordBoundaries.moveByWordBoundary;
        newPosition = _moveBeyondTextBoundaryAtDirection(targetedEdge, forward, textBoundary);
        result = SelectionResult.end;
      case TextGranularity.line:
        newPosition = _moveToTextBoundaryAtDirection(targetedEdge, forward, LineBoundary(this));
        result = SelectionResult.end;
      case TextGranularity.document:
        final String text = range.textInside(fullText);
        newPosition = _moveBeyondTextBoundaryAtDirection(targetedEdge, forward, DocumentBoundary(text));
        if (forward && newPosition.offset == range.end) {
          result = SelectionResult.next;
        } else if (!forward && newPosition.offset == range.start) {
          result = SelectionResult.previous;
        } else {
          result = SelectionResult.end;
        }
    }

    if (isExtent) {
      _textSelectionEnd = newPosition;
    } else {
      _textSelectionStart = newPosition;
    }
    return result;
  }

  // Move **beyond** the local boundary of the given type (unless range.start or
  // range.end is reached). Used for most TextGranularity types except for
  // TextGranularity.line, to ensure the selection movement doesn't get stuck at
  // a local fixed point.
  TextPosition _moveBeyondTextBoundaryAtDirection(TextPosition end, bool forward, TextBoundary textBoundary) {
    final int newOffset = forward
      ? textBoundary.getTrailingTextBoundaryAt(end.offset) ?? range.end
      : textBoundary.getLeadingTextBoundaryAt(end.offset - 1) ?? range.start;
    return TextPosition(offset: newOffset);
  }

  // Move **to** the local boundary of the given type. Typically used for line
  // boundaries, such that performing "move to line start" more than once never
  // moves the selection to the previous line.
  TextPosition _moveToTextBoundaryAtDirection(TextPosition end, bool forward, TextBoundary textBoundary) {
    assert(end.offset >= 0);
    final int caretOffset;
    switch (end.affinity) {
      case TextAffinity.upstream:
        if (end.offset < 1 && !forward) {
          assert (end.offset == 0);
          return const TextPosition(offset: 0);
        }
        final CharacterBoundary characterBoundary = CharacterBoundary(fullText);
        caretOffset = math.max(
          0,
          characterBoundary.getLeadingTextBoundaryAt(range.start + end.offset) ?? range.start,
        ) - 1;
      case TextAffinity.downstream:
        caretOffset = end.offset;
    }
    final int offset = forward
      ? textBoundary.getTrailingTextBoundaryAt(caretOffset) ?? range.end
      : textBoundary.getLeadingTextBoundaryAt(caretOffset) ?? range.start;
    return TextPosition(offset: offset);
  }

  MapEntry<TextPosition, SelectionResult> _handleVerticalMovement(TextPosition position, {required double horizontalBaselineInParagraphCoordinates, required bool below}) {
    final List<ui.LineMetrics> lines = paragraph._computeLineMetrics();
    final Offset offset = paragraph.getOffsetForCaret(position, Rect.zero);
    int currentLine = lines.length - 1;
    for (final ui.LineMetrics lineMetrics in lines) {
      if (lineMetrics.baseline > offset.dy) {
        currentLine = lineMetrics.lineNumber;
        break;
      }
    }
    final TextPosition newPosition;
    if (below && currentLine == lines.length - 1) {
      newPosition = TextPosition(offset: range.end, affinity: TextAffinity.upstream);
    } else if (!below && currentLine == 0) {
      newPosition = TextPosition(offset: range.start);
    } else {
      final int newLine = below ? currentLine + 1 : currentLine - 1;
      newPosition = _clampTextPosition(
        paragraph.getPositionForOffset(Offset(horizontalBaselineInParagraphCoordinates, lines[newLine].baseline))
      );
    }
    final SelectionResult result;
    if (newPosition.offset == range.start) {
      result = SelectionResult.previous;
    } else if (newPosition.offset == range.end) {
      result = SelectionResult.next;
    } else {
      result = SelectionResult.end;
    }
    assert(result != SelectionResult.next || below);
    assert(result != SelectionResult.previous || !below);
    return MapEntry<TextPosition, SelectionResult>(newPosition, result);
  }

  /// Whether the given text position is contained in current selection
  /// range.
  ///
  /// The parameter `start` must be smaller than `end`.
  bool _positionIsWithinCurrentSelection(TextPosition position) {
    if (_textSelectionStart == null || _textSelectionEnd == null) {
      return false;
    }
    // Normalize current selection.
    late TextPosition currentStart;
    late TextPosition currentEnd;
    if (_compareTextPositions(_textSelectionStart!, _textSelectionEnd!) > 0) {
      currentStart = _textSelectionStart!;
      currentEnd = _textSelectionEnd!;
    } else {
      currentStart = _textSelectionEnd!;
      currentEnd = _textSelectionStart!;
    }
    return _compareTextPositions(currentStart, position) >= 0 && _compareTextPositions(currentEnd, position) <= 0;
  }

  /// Compares two text positions.
  ///
  /// Returns 1 if `position` < `otherPosition`, -1 if `position` > `otherPosition`,
  /// or 0 if they are equal.
  static int _compareTextPositions(TextPosition position, TextPosition otherPosition) {
    if (position.offset < otherPosition.offset) {
      return 1;
    } else if (position.offset > otherPosition.offset) {
      return -1;
    } else if (position.affinity == otherPosition.affinity){
      return 0;
    } else {
      return position.affinity == TextAffinity.upstream ? 1 : -1;
    }
  }

  Matrix4 getTransformToParagraph() {
    return Matrix4.translationValues(_rect.left, _rect.top, 0.0);
  }

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) {
    return getTransformToParagraph()..multiply(paragraph.getTransformTo(ancestor));
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (!paragraph.attached) {
      assert(startHandle == null && endHandle == null, 'Only clean up can be called.');
      return;
    }
    if (_startHandleLayerLink != startHandle) {
      _startHandleLayerLink = startHandle;
      paragraph.markNeedsPaint();
    }
    if (_endHandleLayerLink != endHandle) {
      _endHandleLayerLink = endHandle;
      paragraph.markNeedsPaint();
    }
  }

  Rect get _rect {
    if (_cachedRect == null) {
      final List<TextBox> boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: range.start, extentOffset: range.end),
      );
      if (boxes.isNotEmpty) {
        Rect result = boxes.first.toRect();
        for (int index = 1; index < boxes.length; index += 1) {
          result = result.expandToInclude(boxes[index].toRect());
        }
        _cachedRect = result;
      } else {
        final Offset offset = paragraph._getOffsetForPosition(TextPosition(offset: range.start));
        _cachedRect = Rect.fromPoints(offset, offset.translate(0, - paragraph._textPainter.preferredLineHeight));
      }
    }
    return _cachedRect!;
  }
  Rect? _cachedRect;

  void didChangeParagraphLayout() {
    _cachedRect = null;
  }

  @override
  Size get size {
    return _rect.size;
  }

  void paint(PaintingContext context, Offset offset) {
    if (_textSelectionStart == null || _textSelectionEnd == null) {
      return;
    }
    if (paragraph.selectionColor != null) {
      final TextSelection selection = TextSelection(
        baseOffset: _textSelectionStart!.offset,
        extentOffset: _textSelectionEnd!.offset,
      );
      final Paint selectionPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = paragraph.selectionColor!;
      for (final TextBox textBox in paragraph.getBoxesForSelection(selection)) {
        context.canvas.drawRect(
            textBox.toRect().shift(offset), selectionPaint);
      }
    }
    final Matrix4 transform = getTransformToParagraph();
    if (_startHandleLayerLink != null && value.startSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _startHandleLayerLink!,
          offset: offset + MatrixUtils.transformPoint(transform, value.startSelectionPoint!.localPosition),
        ),
        (PaintingContext context, Offset offset) { },
        Offset.zero,
      );
    }
    if (_endHandleLayerLink != null && value.endSelectionPoint != null) {
      context.pushLayer(
        LeaderLayer(
          link: _endHandleLayerLink!,
          offset: offset + MatrixUtils.transformPoint(transform, value.endSelectionPoint!.localPosition),
        ),
        (PaintingContext context, Offset offset) { },
        Offset.zero,
      );
    }
  }

  @override
  TextSelection getLineAtOffset(TextPosition position) {
    final TextRange line = paragraph._getLineAtOffset(position);
    final int start = line.start.clamp(range.start, range.end); // ignore_clamp_double_lint
    final int end = line.end.clamp(range.start, range.end); // ignore_clamp_double_lint
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  @override
  TextPosition getTextPositionAbove(TextPosition position) {
    return _clampTextPosition(paragraph._getTextPositionAbove(position));
  }

  @override
  TextPosition getTextPositionBelow(TextPosition position) {
    return _clampTextPosition(paragraph._getTextPositionBelow(position));
  }

  @override
  TextRange getWordBoundary(TextPosition position) => paragraph.getWordBoundary(position);
}
