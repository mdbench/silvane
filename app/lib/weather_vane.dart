import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:http/http.dart' as http;
import 'main.dart';
import 'user.dart';
import 'db_service.dart';

class WeatherVaneNotification {
  final String id;
  final String title;
  final String message;
  final String author;
  final String deviceName;
  final DateTime timestamp;
  final String jwtSignature;

  WeatherVaneNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.author,
    required this.deviceName,
    required this.timestamp,
    required this.jwtSignature,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'message': message,
        'author': author,
        'deviceName': deviceName,
        'timestamp': timestamp.toIso8601String(),
        'jwtSignature': jwtSignature,
      };

  factory WeatherVaneNotification.fromMap(Map<String, dynamic> map) => WeatherVaneNotification(
        id: map['id'] ?? '',
        title: map['title'] ?? '',
        message: map['message'] ?? '',
        author: map['author'] ?? 'unknown',
        deviceName: map['deviceName'] ?? 'unknown-device',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
        jwtSignature: map['jwtSignature'] ?? '',
      );
}

class WeatherVaneServerNode {
  final String id;
  final String name;
  final String url;
  final String authType; // 'none', 'jwt', 'basic'
  final String authValue;
  DateTime lastUpdated;

  WeatherVaneServerNode({
    required this.id,
    required this.name,
    required this.url,
    required this.authType,
    required this.authValue,
    required this.lastUpdated,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'url': url,
        'authType': authType,
        'authValue': authValue,
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory WeatherVaneServerNode.fromMap(Map<String, dynamic> map) => WeatherVaneServerNode(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        url: map['url'] ?? '',
        authType: map['authType'] ?? 'none',
        authValue: map['authValue'] ?? '',
        lastUpdated: DateTime.tryParse(map['lastUpdated'] ?? '') ?? DateTime.now(),
      );
}

class WeatherVaneService {
  final _store = StoreRef<String, dynamic>('weather_vane_notifications');
  final _serversStore = StoreRef<String, dynamic>('weather_vane_servers');
  
  static Timer? _pollingTimer;

  static void initPollingDaemon() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(minutes: 30), (timer) async {
      await WeatherVaneService().pollExternalServers();
    });
  }

  Future<String> getDeviceName() async {
    final mainStore = StoreRef<String, dynamic>.main();
    return await mainStore.record('device_name').get(sembastDb) as String? ?? 'Silvane-Kiosk-01';
  }

  Future<void> publishNotification({
    required String title,
    required String message,
    required String currentUser,
    required String jwtToken,
  }) async {
    final deviceName = await getDeviceName();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final notif = WeatherVaneNotification(
      id: id,
      title: title,
      message: message,
      author: currentUser,
      deviceName: deviceName,
      timestamp: DateTime.now(),
      jwtSignature: 'JWT_${jwtToken.hashCode}_${DateTime.now().millisecondsSinceEpoch}',
    );

    await _store.record(id).put(sembastDb, notif.toMap());
    await archiveOldNotifications();
  }

  Future<void> archiveOldNotifications() async {
    final snapshots = await _store.find(sembastDb);
    final now = DateTime.now();
    List<WeatherVaneNotification> toArchive = [];

    for (var snap in snapshots) {
      final notif = WeatherVaneNotification.fromMap(Map<String, dynamic>.from(snap.value));
      if (now.difference(notif.timestamp).inDays > 30) {
        toArchive.add(notif);
        await _store.record(notif.id).delete(sembastDb);
      }
    }

    if (toArchive.isNotEmpty) {
      try {
        final historyFile = File(p.join(appDirectoryPath, 'weather_vane_history.jsonl'));
        final sink = historyFile.openWrite(mode: FileMode.append);
        for (var item in toArchive) {
          sink.writeln(jsonEncode(item.toMap()));
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        debugPrint('Failed to write WeatherVane history file: $e');
      }
    }
  }

  Future<List<WeatherVaneNotification>> getActiveNotifications() async {
    await archiveOldNotifications();
    final snapshots = await _store.find(sembastDb);
    return snapshots.map((s) => WeatherVaneNotification.fromMap(Map<String, dynamic>.from(s.value))).toList();
  }

  Future<List<WeatherVaneNotification>> getHistoricalNotifications() async {
    List<WeatherVaneNotification> historical = [];
    try {
      final historyFile = File(p.join(appDirectoryPath, 'weather_vane_history.jsonl'));
      if (await historyFile.exists()) {
        final lines = await historyFile.readAsLines();
        for (var line in lines) {
          if (line.trim().isNotEmpty) {
            historical.add(WeatherVaneNotification.fromMap(jsonDecode(line)));
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to read WeatherVane history file: $e');
    }
    return historical;
  }

  Future<List<WeatherVaneServerNode>> getExternalServers() async {
    final snapshots = await _serversStore.find(sembastDb);
    return snapshots.map((s) => WeatherVaneServerNode.fromMap(Map<String, dynamic>.from(s.value))).toList();
  }

  Future<void> addExternalServer({required String name, required String url, required String authType, required String authValue}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final server = WeatherVaneServerNode(
      id: id,
      name: name,
      url: url,
      authType: authType,
      authValue: authValue,
      lastUpdated: DateTime.now(),
    );
    await _serversStore.record(id).put(sembastDb, server.toMap());
    await pollServerNode(server);
  }

  Future<void> deleteExternalServer(String id) async {
    await _serversStore.record(id).delete(sembastDb);
  }

  Future<void> pollExternalServers() async {
    final servers = await getExternalServers();
    for (var srv in servers) {
      await pollServerNode(srv);
    }
  }

  Future<void> pollServerNode(WeatherVaneServerNode srv) async {
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (srv.authType == 'jwt' && srv.authValue.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${srv.authValue}';
      } else if (srv.authType == 'basic' && srv.authValue.isNotEmpty) {
        headers['Authorization'] = 'Basic ${base64Encode(utf8.encode(srv.authValue))}';
      }

      final response = await http.get(Uri.parse(srv.url), headers: headers).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          for (var item in decoded) {
            if (item is Map<String, dynamic> && item.containsKey('id') && item.containsKey('title')) {
              final notif = WeatherVaneNotification.fromMap(item);
              await _store.record(notif.id).put(sembastDb, notif.toMap());
            }
          }
        }
        srv.lastUpdated = DateTime.now();
        await _serversStore.record(srv.id).put(sembastDb, srv.toMap());
      }
    } catch (e) {
      debugPrint('Failed to poll WeatherVane server node ${srv.name}:$e');
    }
  }

  static String getWeatherVanePortalHtml() {
    return r'''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>SilvaneOS Weather Vane Notifications Portal</title>
    <style>
        body { background: #1c1a1a; color: #eceff1; font-family: monospace; margin: 0; padding: 0; height: 100vh; display: flex; flex-direction: column; }
        .login-container { max-width: 400px; margin: 100px auto; background: #222020; padding: 24px; border-radius: 8px; border: 1px solid #3a3636; }
        input, button { width: 100%; padding: 10px; margin: 8px 0; background: #1c1a1a; color: white; border: 1px solid #444; border-radius: 4px; box-sizing: border-box; font-family: monospace; }
        button { background: #00bcd4; color: black; border: none; font-weight: bold; cursor: pointer; }
        button:hover { background: #008ba3; }
        .hidden { display: none !important; }
        .app-view { display: flex; flex-direction: column; flex: 1; padding: 30px; max-width: 900px; margin: auto; width: 100%; box-sizing: border-box; }
        .notification-card { background: #262424; padding: 16px; margin-bottom: 12px; border-radius: 6px; border: 1px solid #333; border-left: 4px solid #00bcd4; }
    </style>
</head>
<body>
    <div id="login-form" class="login-container">
        <h2>Weather Vane ACL Login</h2>
        <input type="text" id="username" placeholder="ACL Username" />
        <input type="password" id="password" placeholder="Password" />
        <input type="text" id="totp" placeholder="TOTP 2FA Code (if enabled)" />
        <button onclick="login()">Authenticate & View</button>
        <p id="error-msg" style="color: #ff5252;"></p>
    </div>

    <div id="app-view" class="app-view hidden">
        <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #333; padding-bottom: 15px; margin-bottom: 20px;">
            <h1 style="color: #00bcd4; margin: 0;">🌪️ Weather Vane Notifications</h1>
            <div>
                <span id="user-display" style="color: #ffeb3b; font-weight: bold; margin-right: 15px;"></span>
                <button onclick="logout()" style="width: auto; padding: 6px 12px; background: #d32f2f; color: white;">Logout</button>
            </div>
        </div>
        <div id="notifications-container" style="flex: 1; overflow-y: auto;">
            <div style="text-align: center; color: #888; margin-top: 50px;">Loading notifications...</div>
        </div>
    </div>

    <script>
        let currentUser = localStorage.getItem('wv_user');
        let currentFingerprint = localStorage.getItem('wv_fp');

        if (currentUser && currentFingerprint) {
            loadFingerprintScript().then(() => showApp());
        }

        function loadFingerprintScript() {
            return new Promise((resolve, reject) => {
                if (typeof Fingerprint2 !== 'undefined') {
                    resolve();
                    return;
                }
                const script = document.createElement('script');
                script.src = '/fingerprint2.min.js';
                script.onload = () => resolve();
                script.onerror = () => reject(new Error('Failed to load fingerprint script'));
                document.head.appendChild(script);
            });
        }

        async function generateFingerprint() {
            await loadFingerprintScript();
            return new Promise((resolve) => {
                new Fingerprint2().get(function(result, components) {
                    document.cookie = `ta=${result}; Max-Age=3600; Path=/; SameSite=Strict; Secure`;
                    resolve(result);
                });
            });
        }

        async function login() {
            const u = document.getElementById('username').value;
            const p = document.getElementById('password').value;
            const t = document.getElementById('totp').value;
            
            try {
                const fp = await generateFingerprint();
                const res = await fetch('/api/weather-vane/auth/login', {
                    method: 'POST',
                    headers: {'content-type': 'application/json', 'x-trustless-fp': fp},
                    body: JSON.stringify({username: u, password: p, totp: t, fingerprint: fp})
                });
                const data = await res.json();
                if (res.ok) {
                    localStorage.setItem('wv_user', data.username);
                    localStorage.setItem('wv_fp', fp);
                    currentUser = data.username;
                    currentFingerprint = fp;
                    showApp();
                } else {
                    document.getElementById('error-msg').innerText = data.error || 'Login failed';
                }
            } catch (err) {
                document.getElementById('error-msg').innerText = 'Authentication error';
            }
        }

        function showApp() {
            document.getElementById('login-form').classList.add('hidden');
            document.getElementById('app-view').classList.remove('hidden');
            document.getElementById('user-display').innerText = 'User: ' + currentUser;
            loadNotifications();
        }

        async function loadNotifications() {
            try {
                const res = await fetch('/api/weather-vane/notifications', {
                    headers: { 'x-trustless-fp': currentFingerprint }
                });
                if (res.status === 401) {
                    alert('Session expired or invalid fingerprint. Please log in again.');
                    logout();
                    return;
                }
                const data = await res.json();
                const container = document.getElementById('notifications-container');
                const notifications = data.notifications || [];

                if (notifications.length === 0) {
                    container.innerHTML = '<div style="text-align: center; color: #888; margin-top: 50px;">No new Weather Vane notifications found.</div>';
                    return;
                }

                container.innerHTML = '';
                notifications.forEach(n => {
                    container.innerHTML += `
                        <div class="notification-card">
                            <div style="font-weight: bold; color: #ffeb3b; margin-bottom: 6px;">${n.title || 'Notification'} <span style="float: right; color: #888; font-size: 11px;">${n.timestamp || ''}</span></div>
                            <div style="color: #eceff1; font-size: 13px;">${n.message || JSON.stringify(n)}</div>
                        </div>
                    `;
                });
            } catch (e) {
                document.getElementById('notifications-container').innerHTML = '<div style="text-align: center; color: #ff5252; margin-top: 50px;">Failed to load notifications.</div>';
            }
        }

        function logout() {
            localStorage.clear();
            location.reload();
        }
    </script>
</body>
</html>
''';
  }

}

class WeatherVaneTopBarButton extends StatelessWidget {
  final UserAccount currentUser;
  const WeatherVaneTopBarButton({super.key, required this.currentUser});

  void _openDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => WeatherVanePopup(currentUser: currentUser),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openDialog(context),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF262424),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.amberAccent.withOpacity(0.4)),
        ),
        child: Row(
          children: const [
            Icon(Icons.radar, size: 16, color: Colors.amberAccent),
            SizedBox(width: 6),
            Text('WeatherVane', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class WeatherVanePopup extends StatefulWidget {
  final UserAccount currentUser;
  const WeatherVanePopup({super.key, required this.currentUser});

  @override
  State<WeatherVanePopup> createState() => _WeatherVanePopupState();
}

class _WeatherVanePopupState extends State<WeatherVanePopup> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final WeatherVaneService _service = WeatherVaneService();

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _jwtController = TextEditingController(text: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...');

  final TextEditingController _serverNameController = TextEditingController();
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _serverAuthValueController = TextEditingController();
  String _selectedAuthType = 'none';

  List<WeatherVaneNotification> _activeList = [];
  List<WeatherVaneNotification> _historyList = [];
  List<WeatherVaneServerNode> _serversList = [];
  bool _isLoading = true;

  bool get isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    WeatherVaneService.initPollingDaemon();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final active = await _service.getActiveNotifications();
    final history = await _service.getHistoricalNotifications();
    final servers = await _service.getExternalServers();
    if (mounted) {
      setState(() {
        _activeList = active.reversed.toList();
        _historyList = history.reversed.toList();
        _serversList = servers;
        _isLoading = false;
      });
    }
  }

  Future<void> _publish() async {
    if (!isAdmin) return;
    if (_titleController.text.trim().isEmpty || _messageController.text.trim().isEmpty) return;

    await _service.publishNotification(
      title: _titleController.text.trim(),
      message: _messageController.text.trim(),
      currentUser: widget.currentUser.username,
      jwtToken: _jwtController.text.trim(),
    );

    _titleController.clear();
    _messageController.clear();
    await _loadData();
    _tabController.index = 1;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification successfully published via WeatherVane server.')),
      );
    }
  }

  Future<void> _addServer() async {
    if (!isAdmin) return;
    if (_serverNameController.text.trim().isEmpty || _serverUrlController.text.trim().isEmpty) return;

    await _service.addExternalServer(
      name: _serverNameController.text.trim(),
      url: _serverUrlController.text.trim(),
      authType: _selectedAuthType,
      authValue: _serverAuthValueController.text.trim(),
    );

    _serverNameController.clear();
    _serverUrlController.clear();
    _serverAuthValueController.clear();
    setState(() => _selectedAuthType = 'none');
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('External WeatherVane server registered successfully.')),
      );
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _messageController.dispose();
    _jwtController.dispose();
    _serverNameController.dispose();
    _serverUrlController.dispose();
    _serverAuthValueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF262424),
      title: Row(
        children: const [
          Icon(Icons.radar, color: Colors.amberAccent),
          SizedBox(width: 8),
          Text('WeatherVane Notification Server', style: TextStyle(color: Colors.white, fontSize: 18)),
        ],
      ),
      content: SizedBox(
        width: 740,
        height: 520,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: Colors.amberAccent,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.amberAccent,
              tabs: const [
                Tab(text: 'Add Message'),
                Tab(text: 'New Feed'),
                Tab(text: 'History (>30d)'),
                Tab(text: 'Connected Servers'),
                Tab(text: 'Instructions'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Tab 1: Add Message
                  isAdmin
                      ? SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Publish Admin Notification', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _titleController,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  labelText: 'Notification Title',
                                  labelStyle: TextStyle(color: Colors.grey),
                                  filled: true,
                                  fillColor: Color(0xFF1C1A1A),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _messageController,
                                style: const TextStyle(color: Colors.white),
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: 'Message Body',
                                  labelStyle: TextStyle(color: Colors.grey),
                                  filled: true,
                                  fillColor: Color(0xFF1C1A1A),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _jwtController,
                                style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 11),
                                decoration: const InputDecoration(
                                  labelText: 'JWT Auth Token',
                                  labelStyle: TextStyle(color: Colors.grey),
                                  filled: true,
                                  fillColor: Color(0xFF1C1A1A),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _publish,
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                                  child: const Text('Publish to WeatherVane Server', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const Center(
                          child: Text('Administrator privileges required to publish notifications.', style: TextStyle(color: Colors.redAccent)),
                        ),

                  // Tab 2: New Feed
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _activeList.isEmpty
                          ? const Center(child: Text('No active notifications.', style: TextStyle(color: Colors.grey)))
                          : ListView.builder(
                              itemCount: _activeList.length,
                              itemBuilder: (context, index) {
                                final item = _activeList[index];
                                return Card(
                                  color: const Color(0xFF1C1A1A),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    title: Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        Text(item.message, style: const TextStyle(color: Colors.white70)),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Text('Author: ${item.author}', style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
                                            const SizedBox(width: 12),
                                            Text('Device: ${item.deviceName}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                                          ],
                                        ),
                                      ],
                                    ),
                                    trailing: Text(item.timestamp.toLocal().toString().split('.').first, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                  ),
                                );
                              },
                            ),

                  // Tab 3: History (>30d)
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _historyList.isEmpty
                          ? const Center(child: Text('No historical notifications older than 30 days.', style: TextStyle(color: Colors.grey)))
                          : ListView.builder(
                              itemCount: _historyList.length,
                              itemBuilder: (context, index) {
                                final item = _historyList[index];
                                return Card(
                                  color: const Color(0xFF1C1A1A),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    title: Text(item.title, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
                                    subtitle: Text('${item.message}\nAuthor: ${item.author} \vert{} Device:${item.deviceName}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                  ),
                                );
                              },
                            ),

                  // Tab 4: Connected Servers
                  SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.amberAccent.withOpacity(0.3)),
                          ),
                          child: const Text(
                            '⚠️ Notice: Only other WeatherVane notification servers can be added and polled.',
                            style: TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (isAdmin) ...[
                          const Text('Register New External WeatherVane Server', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _serverNameController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(labelText: 'Server Name', labelStyle: TextStyle(color: Colors.grey), filled: true, fillColor: Color(0xFF1C1A1A), border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _serverUrlController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(labelText: 'Server URL', labelStyle: TextStyle(color: Colors.grey), filled: true, fillColor: Color(0xFF1C1A1A), border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            dropdownColor: const Color(0xFF262424),
                            style: const TextStyle(color: Colors.white),
                            value: _selectedAuthType,
                            decoration: const InputDecoration(labelText: 'Authentication Type', labelStyle: TextStyle(color: Colors.grey), filled: true, fillColor: Color(0xFF1C1A1A), border: OutlineInputBorder()),
                            items: const [
                              DropdownMenuItem(value: 'none', child: Text('No Auth')),
                              DropdownMenuItem(value: 'jwt', child: Text('JWT Token')),
                              DropdownMenuItem(value: 'basic', child: Text('Basic Auth (user:pass)')),
                            ],
                            onChanged: (val) => setState(() => _selectedAuthType = val ?? 'none'),
                          ),
                          if (_selectedAuthType != 'none') ...[
                            const SizedBox(height: 8),
                            TextField(
                              controller: _serverAuthValueController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(labelText: _selectedAuthType == 'jwt' ? 'JWT Token String' : 'Username:Password', labelStyle: const TextStyle(color: Colors.grey), filled: true, fillColor: const Color(0xFF1C1A1A), border: const OutlineInputBorder()),
                            ),
                          ],
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _addServer,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                            icon: const Icon(Icons.add),
                            label: const Text('Add WeatherVane Server', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          const Divider(color: Colors.white24, height: 24),
                        ],
                        const Text('Registered External Servers & Polling Status', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        _serversList.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Text('No external WeatherVane servers added yet.', style: TextStyle(color: Colors.grey)),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _serversList.length,
                                itemBuilder: (context, index) {
                                  final srv = _serversList[index];
                                  return Card(
                                    color: const Color(0xFF1C1A1A),
                                    margin: const EdgeInsets.only(bottom: 8),
                                    child: ListTile(
                                      title: Text(srv.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                      subtitle: Text('URL: ${srv.url}\nAuth: ${srv.authType.toUpperCase()} \vert{} Last Updated:${srv.lastUpdated.toLocal().toString().split('.').first}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                      trailing: isAdmin
                                          ? IconButton(
                                              icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                                              onPressed: () async {
                                                await _service.deleteExternalServer(srv.id);
                                                await _loadData();
                                              },
                                            )
                                          : null,
                                    ),
                                  );
                                },
                              ),
                      ],
                    ),
                  ),

                  // Tab 5: Instructions
                  SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('WeatherVane Notification Server Specification', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                          SizedBox(height: 10),
                          Text(
                            '• Persistent Event Daemon: WeatherVane acts as a continuous notification bus integrated directly into Sembast metadata.\n\n'
                            '• JWT Authentication: All local publishing requests require a valid JSON Web Token header verification signature.\n\n'
                            '• 30-Day Archival Policy: Notifications older than 30 days are automatically migrated from Sembast to the local historical file `weather_vane_history.jsonl`.\n\n'
                            '• External Server Polling: Registered external WeatherVane servers are automatically polled every 30 minutes for new updates.\n\n'
                            '• Telemetry & Accountability: Every broadcast is permanently tagged with the publishing administrator username and the registered system device name.',
                            style: TextStyle(color: Colors.white70, height: 1.4, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
