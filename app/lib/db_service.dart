import 'package:sembast/sembast.dart';
import 'main.dart';

class UserAccount {
  String username;
  String password;
  String role;
  bool canRead;
  bool canWrite;
  bool canExecute;
  bool isTotpEnabled;
  String totpSecret;

  UserAccount({
    required this.username,
    required this.password,
    required this.role,
    required this.canRead,
    required this.canWrite,
    required this.canExecute,
    required this.isTotpEnabled,
    required this.totpSecret,
  });

  Map<String, dynamic> toMap() => {
        'username': username,
        'password': password,
        'role': role,
        'canRead': canRead,
        'canWrite': canWrite,
        'canExecute': canExecute,
        'isTotpEnabled': isTotpEnabled,
        'totpSecret': totpSecret,
      };

  factory UserAccount.fromMap(Map<String, dynamic> map) => UserAccount(
        username: map['username'] ?? '',
        password: map['password'] ?? '',
        role: map['role'] ?? 'User',
        canRead: map['canRead'] ?? true,
        canWrite: map['canWrite'] ?? false,
        canExecute: map['canExecute'] ?? false,
        isTotpEnabled: map['isTotpEnabled'] ?? false,
        totpSecret: map['totpSecret'] ?? '',
      );
}

class ActivityLog {
  final String username;
  final String action;
  final String details;
  final DateTime timestamp;

  ActivityLog({required this.username, required this.action, required this.details, required this.timestamp});

  factory ActivityLog.fromMap(Map<String, dynamic> map) => ActivityLog(
        username: map['username'] ?? '',
        action: map['action'] ?? '',
        details: map['details'] ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}

class FailedLogin {
  final String ip;
  final String username;
  final String password;
  final DateTime timestamp;

  FailedLogin({required this.ip, required this.username, required this.password, required this.timestamp});

  factory FailedLogin.fromMap(Map<String, dynamic> map) => FailedLogin(
        ip: map['ip'] ?? '',
        username: map['username'] ?? '',
        password: map['password'] ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}

class DbService {
  final _usersStore = StoreRef<String, dynamic>('users');
  final _logsStore = StoreRef<int, dynamic>('audit_logs');
  final _failsStore = StoreRef<int, dynamic>('failed_logins');

  Future<void> seedDefaultAdmin() async {
    final adminRecord = _usersStore.record('admin');
    final existing = await adminRecord.get(sembastDb);
    if (existing == null) {
      final defaultAdmin = UserAccount(
        username: 'admin',
        password: 'admin',
        role: 'Admin',
        canRead: true,
        canWrite: true,
        canExecute: true,
        isTotpEnabled: false,
        totpSecret: '',
      );
      await adminRecord.put(sembastDb, defaultAdmin.toMap());
    }
  }

  Future<UserAccount?> authenticate(String username, String password) async {
    await seedDefaultAdmin();
    final record = _usersStore.record(username.toLowerCase());
    final data = await record.get(sembastDb);
    if (data != null) {
      final user = UserAccount.fromMap(Map<String, dynamic>.from(data));
      if (user.password == password) {
        return user;
      }
    }
    return null;
  }

  Future<bool> verifyTotp(UserAccount user, String code) async {
    return code.length == 6;
  }

  Future<List<UserAccount>> getAllUsers() async {
    await seedDefaultAdmin();
    final snapshots = await _usersStore.find(sembastDb);
    return snapshots.map((snap) => UserAccount.fromMap(Map<String, dynamic>.from(snap.value))).toList();
  }

  Future<void> saveUser(UserAccount user) async {
    await _usersStore.record(user.username.toLowerCase()).put(sembastDb, user.toMap());
  }

  Future<void> deleteUser(String username) async {
    if (username.toLowerCase() == 'admin') return;
    await _usersStore.record(username.toLowerCase()).delete(sembastDb);
  }

  Future<void> logActivity({required String username, required String action, required String details}) async {
    await _logsStore.add(sembastDb, {
      'timestamp': DateTime.now().toIso8601String(),
      'username': username,
      'action': action,
      'details': details,
    });
  }

  Future<void> logFailedLogin({required String ip, required String username, required String password}) async {
    await _failsStore.add(sembastDb, {
      'timestamp': DateTime.now().toIso8601String(),
      'ip': ip,
      'username': username,
      'password': password,
    });
    await logActivity(username: username, action: 'Failed Login', details: 'IP: $ip');
  }

  Future<List<ActivityLog>> getLogs({String? usernameFilter}) async {
    final snapshots = await _logsStore.find(sembastDb);
    List<ActivityLog> logs = snapshots.map((snap) => ActivityLog.fromMap(Map<String, dynamic>.from(snap.value))).toList();
    if (usernameFilter != null) {
      logs = logs.where((l) => l.username.toLowerCase() == usernameFilter.toLowerCase()).toList();
    }
    logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return logs;
  }

  Future<List<FailedLogin>> getFailedLogins() async {
    final snapshots = await _failsStore.find(sembastDb);
    List<FailedLogin> fails = snapshots.map((snap) => FailedLogin.fromMap(Map<String, dynamic>.from(snap.value))).toList();
    fails.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return fails;
  }
}