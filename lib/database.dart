import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDb {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'shoppingcalc.db');
    _db = await openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE cart_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            price REAL NOT NULL,
            quantity INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE shopping_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date_iso TEXT NOT NULL,
            budget REAL NOT NULL,
            name TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE history_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            history_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            price REAL NOT NULL,
            quantity INTEGER NOT NULL,
            FOREIGN KEY (history_id) REFERENCES shopping_history(id) ON DELETE CASCADE
          )
        ''');
        await db.insert('settings', {'key': 'budget', 'value': '10000'});
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE shopping_history ADD COLUMN name TEXT');
        }
      },
    );
    return _db!;
  }
}

class CartRow {
  final int id;
  final String name;
  final double price;
  final int quantity;
  CartRow({required this.id, required this.name, required this.price, required this.quantity});
}

class HistoryRow {
  final int id;
  final DateTime date;
  final double budget;
  final String? name;
  final List<CartRow> items;
  HistoryRow({
    required this.id,
    required this.date,
    required this.budget,
    required this.name,
    required this.items,
  });

  int get itemCount => items.fold(0, (s, it) => s + it.quantity);
  double get total => items.fold(0, (s, it) => s + it.price * it.quantity);
}

class CartRepo {
  static Future<List<CartRow>> loadCart() async {
    final db = await AppDb.instance;
    final rows = await db.query('cart_items', orderBy: 'id ASC');
    return rows.map(_toCartRow).toList();
  }

  static Future<int> insertItem({required String name, required double price, required int quantity}) async {
    final db = await AppDb.instance;
    return db.insert('cart_items', {'name': name, 'price': price, 'quantity': quantity});
  }

  static Future<void> updateItem(CartRow row) async {
    final db = await AppDb.instance;
    await db.update(
      'cart_items',
      {'name': row.name, 'price': row.price, 'quantity': row.quantity},
      where: 'id = ?',
      whereArgs: [row.id],
    );
  }

  static Future<void> deleteItem(int id) async {
    final db = await AppDb.instance;
    await db.delete('cart_items', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> clearCart() async {
    final db = await AppDb.instance;
    await db.delete('cart_items');
  }
}

class SettingsRepo {
  static Future<double> loadBudget() async {
    final db = await AppDb.instance;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: ['budget']);
    if (rows.isEmpty) return 10000.0;
    return double.tryParse(rows.first['value'] as String) ?? 10000.0;
  }

  static Future<void> saveBudget(double value) async {
    final db = await AppDb.instance;
    await db.insert(
      'settings',
      {'key': 'budget', 'value': value.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> loadCartName() async {
    final db = await AppDb.instance;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: ['cart_name']);
    if (rows.isEmpty) return null;
    final v = rows.first['value'] as String;
    return v.isEmpty ? null : v;
  }

  static Future<void> saveCartName(String? value) async {
    final db = await AppDb.instance;
    await db.insert(
      'settings',
      {'key': 'cart_name', 'value': value ?? ''},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

class HistoryRepo {
  static Future<int> saveTrip({
    required double budget,
    required List<CartRow> items,
    String? name,
    DateTime? date,
  }) async {
    final db = await AppDb.instance;
    final d = date ?? DateTime.now();
    return await db.transaction<int>((txn) async {
      final historyId = await txn.insert('shopping_history', {
        'date_iso': d.toIso8601String(),
        'budget': budget,
        'name': name,
      });
      for (final it in items) {
        await txn.insert('history_items', {
          'history_id': historyId,
          'name': it.name,
          'price': it.price,
          'quantity': it.quantity,
        });
      }
      return historyId;
    });
  }

  static Future<List<HistoryRow>> loadAll() async {
    final db = await AppDb.instance;
    final trips = await db.query('shopping_history', orderBy: 'date_iso DESC');
    final result = <HistoryRow>[];
    for (final t in trips) {
      final id = t['id'] as int;
      final items = await db.query(
        'history_items',
        where: 'history_id = ?',
        whereArgs: [id],
        orderBy: 'id ASC',
      );
      result.add(HistoryRow(
        id: id,
        date: DateTime.parse(t['date_iso'] as String),
        budget: (t['budget'] as num).toDouble(),
        name: t['name'] as String?,
        items: items.map(_toCartRow).toList(),
      ));
    }
    return result;
  }

  static Future<void> deleteTrip(int id) async {
    final db = await AppDb.instance;
    await db.delete('shopping_history', where: 'id = ?', whereArgs: [id]);
  }
}

CartRow _toCartRow(Map<String, Object?> r) => CartRow(
      id: r['id'] as int,
      name: r['name'] as String,
      price: (r['price'] as num).toDouble(),
      quantity: r['quantity'] as int,
    );
