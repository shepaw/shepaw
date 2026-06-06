import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pops a search page opened by [showShepawSearch].
void popShepawSearch<T>(BuildContext context, T? result) {
  Navigator.of(context).pop(result);
}

/// Opens a full-screen search page with the clear action inside the search field.
Future<T?> showShepawSearch<T>({
  required BuildContext context,
  required SearchDelegate<T> delegate,
  String? query = '',
}) {
  delegate.query = query ?? delegate.query;
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      builder: (context) => ShepawSearchPage<T>(delegate: delegate),
    ),
  );
}

/// Search page with a contained search field and in-field clear button.
class ShepawSearchPage<T> extends StatefulWidget {
  const ShepawSearchPage({super.key, required this.delegate});

  final SearchDelegate<T> delegate;

  @override
  State<ShepawSearchPage<T>> createState() => _ShepawSearchPageState<T>();
}

class _ShepawSearchPageState<T> extends State<ShepawSearchPage<T>> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  var _showResults = false;

  SearchDelegate<T> get delegate => widget.delegate;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: delegate.query);
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          popShepawSearch<T>(context, null);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    _controller.addListener(_onQueryChanged);
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (delegate.query != _controller.text) {
      delegate.query = _controller.text;
    }
    setState(() {});
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && _showResults) {
      setState(() => _showResults = false);
    }
  }

  void _clearQuery() {
    _controller.clear();
    delegate.query = '';
    setState(() => _showResults = false);
    _focusNode.requestFocus();
  }

  InputDecoration _buildSearchDecoration(
    BuildContext context,
    String hintText,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      prefixIcon: Icon(
        Icons.search,
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
      prefixIconConstraints: const BoxConstraints(
        minWidth: 40,
        minHeight: 32,
      ),
      suffixIcon: _controller.text.isNotEmpty
          ? IconButton(
              icon: Icon(
                Icons.clear,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              onPressed: _clearQuery,
            )
          : null,
      suffixIconConstraints: const BoxConstraints(
        minWidth: 36,
        minHeight: 32,
      ),
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: colorScheme.primary.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hintText = delegate.searchFieldLabel ??
        MaterialLocalizations.of(context).searchFieldLabel;

    final body = _showResults
        ? delegate.buildResults(context)
        : delegate.buildSuggestions(context);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: theme.scaffoldBackgroundColor,
        titleSpacing: 8,
        leading: delegate.buildLeading(context),
        automaticallyImplyLeading: delegate.automaticallyImplyLeading ?? true,
        leadingWidth: delegate.leadingWidth,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: delegate.searchFieldStyle ??
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          textInputAction: delegate.textInputAction,
          autocorrect: delegate.autocorrect,
          enableSuggestions: delegate.enableSuggestions,
          keyboardType: delegate.keyboardType,
          onSubmitted: (_) {
            _focusNode.unfocus();
            setState(() => _showResults = true);
          },
          decoration: _buildSearchDecoration(context, hintText),
        ),
        actions: delegate.buildActions(context),
        bottom: delegate.buildBottom(context),
        flexibleSpace: delegate.buildFlexibleSpace(context),
        systemOverlayStyle: colorScheme.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: KeyedSubtree(
          key: ValueKey<bool>(_showResults),
          child: body,
        ),
      ),
    );
  }
}
