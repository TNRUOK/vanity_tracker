import 'package:flutter/material.dart';
import '../services/product_lookup_service.dart';
import '../theme/app_theme.dart';

/// Search Open Beauty Facts by name/brand and let the user pick a product (nothing is
/// chosen automatically). Returns the chosen candidate, or null.
class ProductSearchDialog extends StatefulWidget {
  final String initialQuery;

  /// Test hook replacing the network search.
  static Future<ProductSearchResult> Function(String query)? debugSearch;

  const ProductSearchDialog({super.key, this.initialQuery = ''});

  static Future<ProductSearchCandidate?> show(BuildContext context, {String initialQuery = ''}) {
    return showDialog<ProductSearchCandidate>(
      context: context,
      builder: (_) => ProductSearchDialog(initialQuery: initialQuery),
    );
  }

  @override
  State<ProductSearchDialog> createState() => _ProductSearchDialogState();
}

class _ProductSearchDialogState extends State<ProductSearchDialog> {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery);
  ProductSearchResult? _result;
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching) return; // one search at a time (the service is rate limited)
    setState(() => _searching = true);
    final search = ProductSearchDialog.debugSearch ?? ProductLookupService.searchByName;
    final r = await search(_query.text);
    if (!mounted) return;
    setState(() {
      _result = r;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return AlertDialog(
      title: const Text('Search by name', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('product-search-query'),
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Brand and product name, e.g. CeraVe moisturising cream',
                suffixIcon: IconButton(
                  key: const ValueKey('product-search-go'),
                  icon: _searching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _searching ? null : _search,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Results come from Open Beauty Facts (ODbL). Pick the product that matches your pack exactly '
              '(same brand, name and size); you can edit everything afterwards.',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
            if (r?.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(r!.errorMessage!, key: const ValueKey('product-search-message'), style: const TextStyle(fontSize: 12.5)),
              ),
            if (r != null && r.candidates.isNotEmpty)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in r.candidates)
                      ListTile(
                        key: ValueKey('product-search-result-${c.barcode}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${c.brand} ${c.name}'.trim(), maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text([if (c.quantity != null) c.quantity!, 'barcode ${c.barcode}'].join(' · ')),
                        onTap: () => Navigator.of(context).pop(c),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}
