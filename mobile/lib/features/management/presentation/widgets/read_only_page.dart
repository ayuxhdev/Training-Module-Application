import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';

class ReadOnlyPage<T> extends StatelessWidget {
  final String title;
  final AsyncValue<T> value;
  final Future<void> Function() refresh;
  final List<Widget> Function(T) content;
  final List<Widget> actions;

  const ReadOnlyPage({
    super.key,
    required this.title,
    required this.value,
    required this.refresh,
    required this.content,
    this.actions = const [],
  });

  Future<void> _refresh() async {
    try {
      await refresh();
    } catch (_) {
      // The provider exposes the read failure and its explicit recovery action.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      actions: [
        ...actions,
        IconButton(
          tooltip: 'Refresh',
          onPressed: value.isLoading ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: value.when<List<Widget>>(
          // Never render an earlier account's data during reload or recovery.
          skipLoadingOnReload: false,
          skipLoadingOnRefresh: false,
          data: content,
          loading: () => [const LoadingView()],
          error: (error, _) => [ApiErrorView(error: error, onRetry: _refresh)],
        ),
      ),
    ),
  );
}

class InformationRow extends StatelessWidget {
  final String label, value;
  const InformationRow(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}
