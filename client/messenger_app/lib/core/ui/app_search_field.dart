import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

/// Themed search field.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.hintText = 'Поиск',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
      style: text.body,
      cursorColor: colors.primary,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: text.body.copyWith(color: colors.textMuted),
        filled: true,
        fillColor: colors.card,
        prefixIcon: Icon(Icons.search_outlined, color: colors.textMuted, size: 20),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
    );
  }
}

/// General text field — alias for forms outside search.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.hintText,
    this.onSubmitted,
    this.textInputAction,
    this.obscureText = false,
    this.leading,
    this.trailing,
    this.autofocus = false,
    this.keyboardType,
    this.maxLines = 1,
  });

  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final Widget? leading;
  final Widget? trailing;
  final bool autofocus;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return TextField(
      controller: controller,
      onSubmitted: onSubmitted,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autofocus: autofocus,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: text.body,
      cursorColor: colors.primary,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: text.body.copyWith(color: colors.textMuted),
        filled: true,
        fillColor: colors.card,
        prefixIcon: leading,
        suffixIcon: trailing,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
    );
  }
}
