import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'database.dart';
import 'scan_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShoppingCalcApp());
}

class ShoppingCalcApp extends StatelessWidget {
  const ShoppingCalcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shopping Calc',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CartPage(),
    );
  }
}

class CartItem {
  final int id;
  String name;
  double price;
  int quantity;

  CartItem({
    required this.id,
    required this.name,
    required this.price,
    this.quantity = 1,
  });

  double get subtotal => price * quantity;

  CartRow toRow() => CartRow(id: id, name: name, price: price, quantity: quantity);
  static CartItem fromRow(CartRow r) =>
      CartItem(id: r.id, name: r.name, price: r.price, quantity: r.quantity);
}

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  double _budget = 10000.0;
  String? _cartName;
  final List<CartItem> _items = [];
  bool _loading = true;
  bool _wasOverBudget = false;

  double get _total => _items.fold(0, (sum, item) => sum + item.subtotal);
  double get _remaining => _budget - _total;
  bool get _overBudget => _remaining < 0;

  void _checkBudgetAlert() {
    final over = _overBudget;
    if (over && !_wasOverBudget) {
      HapticFeedback.heavyImpact();
    }
    _wasOverBudget = over;
  }

  @override
  void initState() {
    super.initState();
    _loadFromDb();
  }

  Future<void> _loadFromDb() async {
    final budget = await SettingsRepo.loadBudget();
    final name = await SettingsRepo.loadCartName();
    final rows = await CartRepo.loadCart();
    if (!mounted) return;
    setState(() {
      _budget = budget;
      _cartName = name;
      _items
        ..clear()
        ..addAll(rows.map(CartItem.fromRow));
      _loading = false;
      _wasOverBudget = _overBudget;
    });
  }

  Future<void> _increment(CartItem item) async {
    setState(() {
      item.quantity++;
      _checkBudgetAlert();
    });
    await CartRepo.updateItem(item.toRow());
  }

  Future<void> _decrement(CartItem item) async {
    if (item.quantity > 1) {
      setState(() {
        item.quantity--;
        _checkBudgetAlert();
      });
      await CartRepo.updateItem(item.toRow());
    } else {
      await _remove(item);
    }
  }

  Future<void> _remove(CartItem item) async {
    setState(() => _items.remove(item));
    await CartRepo.deleteItem(item.id);
  }

  Future<void> _editBudget() async {
    final ctrl = TextEditingController(text: _moneyForEdit(_budget));
    final result = await showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Presupuesto'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: '\$ ',
            hintText: '10000,00',
            helperText: 'Usá coma para los decimales',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final v = _parseMoney(ctrl.text);
              if (v != null) Navigator.pop(context, v);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() {
        _budget = result;
        _checkBudgetAlert();
      });
      await SettingsRepo.saveBudget(result);
    }
  }

  Future<void> _editCartName() async {
    final ctrl = TextEditingController(text: _cartName ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nombre de la compra'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Ej: Delfin, Día, Jumbo…',
            helperText: 'Aparecerá al lado de la fecha en el historial',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Quitar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final normalized = result.isEmpty ? null : result;
    setState(() => _cartName = normalized);
    await SettingsRepo.saveCartName(normalized);
  }

  void _openHistory() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage()));
  }

  Future<void> _pagar() async {
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El carrito está vacío')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Compra pagada?'),
        content: Text('Se guardará la compra de ${_fmt(_total)} en el historial y se vaciará el carrito.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text('Pagado'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await HistoryRepo.saveTrip(
        budget: _budget,
        items: _items.map((it) => it.toRow()).toList(),
        name: _cartName,
      );
      await CartRepo.clearCart();
      await SettingsRepo.saveCartName(null);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _cartName = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ Compra guardada en historial')),
      );
    }
  }

  Future<void> _nuevaCompra() async {
    if (_items.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nueva compra'),
        content: const Text('Vas a vaciar el carrito actual SIN guardar. ¿Continuar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Vaciar'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await CartRepo.clearCart();
      await SettingsRepo.saveCartName(null);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _cartName = null;
      });
    }
  }

  Future<void> _editItem(CartItem item) async {
    final result = await showModalBottomSheet<_AddItemResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddItemSheet(initial: item),
    );
    if (result != null) {
      setState(() {
        item.name = result.name;
        item.price = result.price;
        item.quantity = result.quantity;
        _checkBudgetAlert();
      });
      await CartRepo.updateItem(item.toRow());
    }
  }

  Future<void> _openAddItemSheet() async {
    final result = await showModalBottomSheet<_AddItemResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AddItemSheet(),
    );
    if (result != null) {
      final id = await CartRepo.insertItem(
        name: result.name,
        price: result.price,
        quantity: result.quantity,
      );
      if (!mounted) return;
      setState(() {
        _items.add(CartItem(
          id: id,
          name: result.name,
          price: result.price,
          quantity: result.quantity,
        ));
        _checkBudgetAlert();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _editCartName,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _cartName ?? 'Mi Compra',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.edit, size: 14, color: Colors.grey.shade400),
              ],
            ),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Pagar compra',
            onPressed: _pagar,
            icon: const Icon(Icons.check_circle_outline),
            color: Colors.greenAccent,
          ),
          IconButton(
            tooltip: 'Nueva compra',
            onPressed: _nuevaCompra,
            icon: const Icon(Icons.add_shopping_cart),
          ),
          IconButton(
            tooltip: 'Historial',
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'budget') _editBudget();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'budget',
                child: ListTile(
                  leading: Icon(Icons.account_balance_wallet_outlined),
                  title: Text('Editar presupuesto'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _items.isEmpty
                      ? const _EmptyCart()
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _CartItemTile(
                            item: _items[i],
                            onIncrement: () => _increment(_items[i]),
                            onDecrement: () => _decrement(_items[i]),
                            onRemove: () => _remove(_items[i]),
                            onEdit: () => _editItem(_items[i]),
                          ),
                        ),
                ),
                _TotalsFooter(
                  total: _total,
                  budget: _budget,
                  remaining: _remaining,
                  overBudget: _overBudget,
                  onScan: _openAddItemSheet,
                  onEditBudget: _editBudget,
                ),
              ],
            ),
    );
  }
}

class _CartItemTile extends StatelessWidget {
  final CartItem item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;
  final VoidCallback onEdit;

  const _CartItemTile({
    required this.item,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        color: Colors.redAccent,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => onRemove(),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onEdit,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_fmt(item.price)} c/u',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade400,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _fmt(item.subtotal),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _QtyControl(
                quantity: item.quantity,
                onIncrement: onIncrement,
                onDecrement: onDecrement,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  final int quantity;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  const _QtyControl({
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.filledTonal(
          onPressed: onDecrement,
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$quantity',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton.filledTonal(
          onPressed: onIncrement,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _TotalsFooter extends StatelessWidget {
  final double total;
  final double budget;
  final double remaining;
  final bool overBudget;
  final VoidCallback onScan;
  final VoidCallback onEditBudget;

  const _TotalsFooter({
    required this.total,
    required this.budget,
    required this.remaining,
    required this.overBudget,
    required this.onScan,
    required this.onEditBudget,
  });

  @override
  Widget build(BuildContext context) {
    final totalColor = overBudget ? Colors.redAccent : Colors.amber;
    final remainingLabel = overBudget ? 'Te pasaste' : 'Te queda';
    final remainingValue = overBudget ? -remaining : remaining;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: Colors.grey.shade800),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'TOTAL',
                style: TextStyle(fontSize: 16, letterSpacing: 1.2),
              ),
              Text(
                _fmt(total),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: totalColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              InkWell(
                onTap: onEditBudget,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Presupuesto ${_fmt(budget)}',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.edit, size: 12, color: Colors.grey.shade500),
                    ],
                  ),
                ),
              ),
              Text(
                '$remainingLabel ${_fmt(remainingValue)}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: overBudget ? Colors.redAccent : Colors.greenAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.camera_alt),
              label: const Text(
                'Escanear producto',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shopping_cart_outlined, size: 72, color: Colors.grey.shade600),
          const SizedBox(height: 12),
          Text(
            'Carrito vacío',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 4),
          Text(
            'Tocá "Escanear" para agregar productos',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<HistoryRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = HistoryRepo.loadAll();
  }

  Future<void> _reload() async {
    setState(() => _future = HistoryRepo.loadAll());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de compras')),
      body: FutureBuilder<List<HistoryRow>>(
        future: _future,
        builder: (_, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return Center(
              child: Text(
                'Sin compras anteriores',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade400),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, i) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final h = list[i];
              final over = h.total > h.budget;
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => HistoryDetailPage(history: h)),
                    );
                    _reload();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: over ? Colors.redAccent : Colors.amber,
                          child: Icon(
                            over ? Icons.warning_amber : Icons.check,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.name != null && h.name!.isNotEmpty
                                    ? '${_formatDate(h.date)} — ${h.name}'
                                    : _formatDate(h.date),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${h.itemCount} productos · Presupuesto ${_fmt(h.budget)}',
                                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _fmt(h.total),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: over ? Colors.redAccent : null,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: Colors.grey.shade500),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class HistoryDetailPage extends StatelessWidget {
  final HistoryRow history;
  const HistoryDetailPage({super.key, required this.history});

  Future<void> _delete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar compra'),
        content: const Text('¿Eliminar esta compra del historial? No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await HistoryRepo.deleteTrip(history.id);
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final over = history.total > history.budget;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          history.name != null && history.name!.isNotEmpty
              ? '${_formatDate(history.date)} — ${history.name}'
              : _formatDate(history.date),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Eliminar',
            onPressed: () => _delete(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: history.items.length,
              itemBuilder: (_, i) {
                final item = history.items[i];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_fmt(item.price)} × ${item.quantity}',
                                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _fmt(item.price * item.quantity),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '×${item.quantity}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              border: Border(top: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('TOTAL', style: TextStyle(fontSize: 16, letterSpacing: 1.2)),
                    Text(
                      _fmt(history.total),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: over ? Colors.redAccent : Colors.amber,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Presupuesto ${_fmt(history.budget)}',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                    ),
                    Text(
                      '${history.itemCount} productos',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AddItemResult {
  final String name;
  final double price;
  final int quantity;
  _AddItemResult(this.name, this.price, this.quantity);
}

class _AddItemSheet extends StatefulWidget {
  final CartItem? initial;
  const _AddItemSheet({this.initial});

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _priceCtrl;
  late int _quantity;
  String? _error;
  List<double> _detectedPrices = [];

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initial?.name ?? '');
    _priceCtrl = TextEditingController(
      text: widget.initial != null ? _moneyForEdit(widget.initial!.price) : '',
    );
    _quantity = widget.initial?.quantity ?? 1;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanEtiqueta() async {
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;

    setState(() {
      if (result.detectedName != null && result.detectedName!.isNotEmpty) {
        _nameCtrl.text = result.detectedName!;
      }
      if (result.prices.isEmpty) {
        _priceCtrl.clear();
        _detectedPrices = [];
      } else if (result.prices.length == 1) {
        _priceCtrl.text = _moneyForEdit(result.prices.first);
        _detectedPrices = [];
      } else {
        // Prices come sorted by visual prominence (biggest font first).
        // Pre-fill the top candidate and offer the rest as chips.
        _priceCtrl.text = _moneyForEdit(result.prices.first);
        _detectedPrices = result.prices.skip(1).toList();
      }
    });

    final msg = result.prices.isEmpty
        ? 'No se detectó ningún precio, ingresalo manual'
        : result.prices.length == 1
            ? 'Precio detectado'
            : 'Se detectaron ${result.prices.length} precios, elegí el correcto';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _pickPrice(double price) {
    setState(() {
      _priceCtrl.text = _moneyForEdit(price);
      _detectedPrices = [];
    });
  }

  void _removePriceOption(double price) {
    setState(() => _detectedPrices.remove(price));
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final price = _parseMoney(_priceCtrl.text);

    if (name.isEmpty) {
      setState(() => _error = 'Ingresá el nombre del producto');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _error = 'Ingresá un precio válido');
      return;
    }
    Navigator.of(context).pop(_AddItemResult(name, price, _quantity));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isEdit ? 'Editar producto' : 'Agregar producto',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (!_isEdit) OutlinedButton.icon(
            onPressed: _scanEtiqueta,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 1.5,
              ),
            ),
            icon: const Icon(Icons.photo_camera_outlined, size: 22),
            label: const Text(
              'Escanear etiqueta con la cámara',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (!_isEdit) const SizedBox(height: 8),
          if (!_isEdit) Center(
            child: Text(
              'o completá los datos manualmente',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            autofocus: false,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 12),
          if (_detectedPrices.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 16, color: Colors.amber),
                const SizedBox(width: 6),
                Text(
                  'Elegí el precio correcto',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade300),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detectedPrices
                  .map((p) => InputChip(
                        label: Text(
                          _fmt(p),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: () => _pickPrice(p),
                        onDeleted: () => _removePriceOption(p),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _priceCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Precio',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
              hintText: '0',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Cantidad', style: TextStyle(fontSize: 16)),
              const Spacer(),
              IconButton.filledTonal(
                onPressed: _quantity > 1
                    ? () => setState(() => _quantity--)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '$_quantity',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton.filledTonal(
                onPressed: () => setState(() => _quantity++),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: Icon(_isEdit ? Icons.save : Icons.add_shopping_cart),
              label: Text(
                _isEdit ? 'Guardar cambios' : 'Agregar al carrito',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(double n) {
  final parts = n.toStringAsFixed(2).split('.');
  final intStr = parts[0];
  final negative = intStr.startsWith('-');
  final digits = negative ? intStr.substring(1) : intStr;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  final frac = parts[1];
  final sign = negative ? '-' : '';
  if (frac == '00') return '$sign\$$buf';
  return '$sign\$$buf,$frac';
}

double? _parseMoney(String text) {
  final cleaned = text.trim().replaceAll('.', '').replaceAll(',', '.');
  return double.tryParse(cleaned);
}

String _moneyForEdit(double n) {
  final parts = n.toStringAsFixed(2).split('.');
  final intStr = parts[0];
  final negative = intStr.startsWith('-');
  final digits = negative ? intStr.substring(1) : intStr;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  final sign = negative ? '-' : '';
  final frac = parts[1];
  if (frac == '00') return '$sign$buf';
  return '$sign$buf,$frac';
}

String _formatDate(DateTime d) {
  const months = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun',
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
  ];
  final dd = d.day.toString().padLeft(2, '0');
  return '$dd ${months[d.month - 1]} ${d.year}';
}
