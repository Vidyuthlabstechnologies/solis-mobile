import 'package:flutter/material.dart';

import '../models/provider_profile.dart';
import '../services/coding/service_catalog.dart';

/// A CPT (five characters, the last may be a letter for Category II/III) or
/// HCPCS Level II (a letter and four digits) code.
bool isServiceCodeFormat(String code) => RegExp(r'^([0-9]{4}[0-9A-Z]|[A-V][0-9]{4})$').hasMatch(code.trim().toUpperCase());

/// Reads a price typed as "140", "$140.00" or "1,250.5". Null when it is
/// not a non-negative amount with at most two decimals.
double? parseCharge(String text) {
  final t = text.trim().replaceAll(RegExp(r'[\$,\s]'), '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t)) return null;
  return double.parse(t);
}

/// The practice's charge master: its own price for each code. New claim
/// lines are priced from it; claims already built keep their charges.
///
/// Pops with the edited schedule, or null when nothing changed.
class ChargeMasterScreen extends StatefulWidget {
  final Map<String, double> fees;

  const ChargeMasterScreen({super.key, required this.fees});

  @override
  State<ChargeMasterScreen> createState() => _ChargeMasterScreenState();
}

class _ChargeMasterScreenState extends State<ChargeMasterScreen> {
  late Map<String, double> _fees = {...widget.fees};
  bool _changed = false;
  String _query = '';

  List<String> get _codes {
    final q = _query.trim().toUpperCase();
    final codes = _fees.keys.where((c) => q.isEmpty || c.contains(q) || (serviceDescription(c) ?? '').toUpperCase().contains(q)).toList()..sort();
    return codes;
  }

  Future<void> _edit({String? code}) async {
    final result = await showDialog<(String, double?)>(
      context: context,
      builder: (_) => _PriceDialog(code: code, price: code == null ? null : _fees[code], existing: _fees.keys.toSet()),
    );
    if (result == null) return;
    setState(() {
      _changed = true;
      if (result.$2 == null) {
        _fees.remove(result.$1);
      } else {
        _fees[result.$1] = result.$2!;
      }
    });
  }

  Future<void> _resetDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use the starting prices?'),
        content: const Text('Every price you set is replaced by the starting list. Claims already built keep their charges.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace prices')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _fees = {...ProviderProfile.defaultFees};
      _changed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = _codes;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed ? _fees : null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your prices'),
          actions: [
            PopupMenuButton<String>(
              onSelected: (_) => _resetDefaults(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'reset', child: Text('Use the starting prices'))],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('add_price'),
          onPressed: () => _edit(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add code'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Text(
              'New claim lines are priced from this list. Claims already built keep their charges. Bill your usual charge, not the payer\'s allowed amount.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('price_search'),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Find a code'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            if (codes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(_fees.isEmpty ? 'No prices yet. Add the codes you bill.' : 'No code matches.', textAlign: TextAlign.center),
              ),
            for (final c in codes)
              ListTile(
                key: Key('price_$c'),
                contentPadding: EdgeInsets.zero,
                title: Text(c, style: theme.textTheme.titleMedium),
                subtitle: serviceDescription(c) == null ? null : Text(serviceDescription(c)!, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text('\$${_fees[c]!.toStringAsFixed(2)}', style: theme.textTheme.titleMedium),
                onTap: () => _edit(code: c),
              ),
          ],
        ),
      ),
    );
  }
}

class _PriceDialog extends StatefulWidget {
  final String? code;
  final double? price;
  final Set<String> existing;

  const _PriceDialog({this.code, this.price, required this.existing});

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  late final _code = TextEditingController(text: widget.code ?? '');
  late final _price = TextEditingController(text: widget.price?.toStringAsFixed(2) ?? '');
  String? _codeError;
  String? _priceError;

  @override
  void dispose() {
    _code.dispose();
    _price.dispose();
    super.dispose();
  }

  void _save() {
    final code = _code.text.trim().toUpperCase();
    final price = parseCharge(_price.text);
    setState(() {
      _codeError = !isServiceCodeFormat(code)
          ? 'Enter a CPT or HCPCS code, like 99213 or G2211'
          : (widget.code == null && widget.existing.contains(code) ? 'This code already has a price' : null);
      _priceError = price == null ? 'Enter an amount, like 140 or 140.50' : null;
    });
    if (_codeError != null || _priceError != null) return;
    Navigator.pop(context, (code, price));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.code == null ? 'Add a price' : 'Price for ${widget.code}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.code == null)
              TextField(
                key: const Key('price_code'),
                controller: _code,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: 'Code', errorText: _codeError),
              ),
            TextField(
              key: const Key('price_amount'),
              controller: _price,
              autofocus: widget.code != null,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Your charge', prefixText: '\$', errorText: _priceError),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
        actions: [
          if (widget.code != null)
            TextButton(onPressed: () => Navigator.pop(context, (widget.code!, null)), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('price_save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}
