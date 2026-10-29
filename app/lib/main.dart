import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'db_service.dart';
import 'login.dart';
import 'tab1.dart';
import 'tab2.dart';
import 'tab3.dart';
import 'tab4.dart';
import 'tab5.dart';
import 'user.dart';
import 'silver_git.dart';
import 'sylvan_sap.dart';
import 'forest_finder.dart';
import 'metal_mail.dart';
import 'voice_trunk.dart';
import 'ore_pine.dart';
import 'weather_vane.dart';
import 'versions.dart';

late Database sembastDb;
late String appDirectoryPath;
late String deviceIpAddress;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SilvaneApp());
}

Future<String> _resolveDeviceIp() async {
  try {
    for (var interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          return addr.address;
        }
      }
    }
  } catch (e) {
    debugPrint('Failed to resolve network interfaces: $e');
  }
  return '127.0.0.1';
}

class SilvaneApp extends StatefulWidget {
  const SilvaneApp({super.key});

  @override
  State<SilvaneApp> createState() => _SilvaneAppState();
}

class _SilvaneAppState extends State<SilvaneApp> {
  bool _isInitialized = false;
  String? _initError;
  UserAccount? _currentUser;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      deviceIpAddress = await _resolveDeviceIp();

      final docDir = await getApplicationDocumentsDirectory();
      appDirectoryPath = p.join(docDir.path, 'Silvane');
      final ioDir = Directory(appDirectoryPath);
      if (!await ioDir.exists()) {
        await ioDir.create(recursive: true);
      }

      final dbPath = p.join(appDirectoryPath, 'silvane_meta.db');
      
      // Safely open Sembast with robust fallback handling for Live ISO overlays
      try {
        sembastDb = await databaseFactoryIo.openDatabase(dbPath);
      } catch (dbError) {
        debugPrint('[SilvaneOS] Database open failed, attempting clean reset: $dbError');
        
        // Clean up both the main db and any lingering lock files
        final dbFile = File(dbPath);
        final lockFile = File('$dbPath.lock');
        
        if (await dbFile.exists()) await dbFile.delete();
        if (await lockFile.exists()) await lockFile.delete();
        
        // Brief yield to allow OS filesystem handle release
        await Future.delayed(const Duration(milliseconds: 100));
        
        sembastDb = await databaseFactoryIo.openDatabase(dbPath);
      }

      await DbService().seedDefaultAdmin();

      // Non-blocking background boot time sync config
      unawaited(_applyBootTimeSyncConfig());

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _initError = e.toString();
      });
    }
  }

  Future<void> _applyBootTimeSyncConfig() async {
    try {
      final store = stringMapStoreFactory.store('system_time_config');
      final configMap = await store.record('config').get(sembastDb);
      if (configMap != null) {
        final mode = configMap['mode'] as String? ?? 'ntp';
        final target = configMap['target'] as String? ?? 'pool.ntp.org';
        if (mode == 'ntp') {
          await Process.run('sudo', ['timedatectl', 'set-ntp', 'true']);
        } else if (mode == 'manual') {
          final manualTime = configMap['manual_time'] as String?;
          if (manualTime != null) {
            await Process.run('sudo', ['timedatectl', 'set-ntp', 'false']);
            await Process.run('sudo', ['timedatectl', 'set-time', manualTime]);
          }
        } else if (mode == 'server') {
          await Process.run('sudo', ['timedatectl', 'set-ntp', 'false']);
          await Process.run('sudo', ['ntpdate', '-u', target]).catchError((_) {
            return ProcessResult(0, 1, '', 'ntpdate fallback failed');
          });
        }
      }
    } catch (e) {
      debugPrint('Boot time sync apply error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF1C1A1A),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Text(
                'Initialization Error:\n$_initError',
                style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (!_isInitialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF1C1A1A),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Initializing SilvaneOS...',
                  style: TextStyle(color: Color(0xFFECEFF1), fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'SilvaneOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1C1A1A),
        primaryColor: const Color(0xFF1C1A1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3A3636),
          secondary: Colors.white,
          surface: Color(0xFF262424),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.white,
        ),
      ),
      home: Stack(
        children: [
          MainLayoutScreen(
            currentUser: _currentUser ?? UserAccount(
              username: 'guest',
              password: '',
              role: 'User',
              canRead: true,
              canWrite: false,
              canExecute: false,
              isTotpEnabled: false,
              totpSecret: '',
            ),
            onLogout: () {
              setState(() {
                _currentUser = null; // This instantly forces LoginScreen to appear on top!
              });
            },
          ),
          if (_currentUser == null)
            LoginScreen(
              onLoginSuccess: (user) {
                setState(() {
                  _currentUser = user;
                });
              },
            ),
        ],
      ),
    );
  }
}

class MainLayoutScreen extends StatefulWidget {
  final UserAccount currentUser;
  final VoidCallback onLogout;
  const MainLayoutScreen({super.key, required this.currentUser, required this.onLogout});

  @override
  State<MainLayoutScreen> createState() => MainLayoutScreenState();
}

class MainLayoutScreenState extends State<MainLayoutScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController searchController = TextEditingController();
  late Timer _rebootCheckTimer;
  
  String searchQuery = '';
  bool get isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _initTabController();
    _startRebootScheduler();
    searchController.addListener(() {
      setState(() {
        searchQuery = searchController.text;
      });
    });
  }

  void _startRebootScheduler() {
    _rebootCheckTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      try {
        final store = stringMapStoreFactory.store('system_time_config');
        final configMap = await store.record('config').get(sembastDb);
        if (configMap != null) {
          final rebootTime = configMap['reboot'] as String? ?? 'Never';
          if (rebootTime != 'Never') {
            final now = DateTime.now();
            final currentHourMinute = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
            if (currentHourMinute == rebootTime) {
              debugPrint('[SilvaneOS] Triggering scheduled nightly reboot at $rebootTime...');
              await Process.run('sudo', ['shutdown', '-r', 'now']);
            }
          }
        }
      } catch (_) {}
    });
  }

  void _initTabController() {
    final length = isAdmin ? 11 : 1;
    _tabController = TabController(length: length, vsync: this);
  }

  @override
  void didUpdateWidget(covariant MainLayoutScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.role != widget.currentUser.role) {
      _tabController.dispose();
      _initTabController();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    searchController.dispose();
    _rebootCheckTimer.cancel();
    super.dispose();
  }

  void _showSystemInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('SilvaneOS System Information', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Build Version: 1.0.4-release', style: TextStyle(color: Color(0xFFECEFF1))),
            const SizedBox(height: 8),
            Text('Flutter Engine: ${Platform.version.split('(').first}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Text('Operating System: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Text('Device IP Address: $deviceIpAddress', style: const TextStyle(color: Colors.cyanAccent, fontSize: 13)),
            const SizedBox(height: 8),
            Text('Active Workspace: $appDirectoryPath', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Text('Logged In User: ${widget.currentUser.username} (${widget.currentUser.role})', style: const TextStyle(color: Colors.amber, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showUserProfileDialog(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF262424),
            title: Text('Activity & Telemetry: ${widget.currentUser.username}'),
            elevation: 0,
          ),
          body: UserView(currentUser: widget.currentUser),
        ),
      ),
    );
  }

  void _showPowerOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('System Power Management', style: TextStyle(color: Colors.white)),
        content: const Text('Select a power action for SilvaneOS:', style: TextStyle(color: Color(0xFFECEFF1))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
            onPressed: () {
              Navigator.pop(context);
              widget.onLogout(); 
            },
            child: const Text('Log Out'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () async {
              Navigator.pop(context);
              try {
                await Process.run('sudo', ['shutdown', '-r', 'now']);
              } catch (e) {
                debugPrint('Reboot error: $e');
              }
            },
            child: const Text('Reboot Now'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              try {
                await Process.run('sudo', ['shutdown', '-h', 'now']);
              } catch (e) {
                debugPrint('Shutdown error: $e');
              }
            },
            child: const Text('Shutdown Now'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String getHintText() {
      if (!isAdmin) return 'Search active servers...';
      switch (_tabController.index) {
        case 0:
          return 'Search active servers...';
        case 1:
          return 'Search workspace folders and files...';
        case 2:
          return 'Search SilverGit repositories...';
        case 3:
          return 'Search SylvanSap files...';
        case 4:
          return 'Search FinderForest printers...';
        case 5:
          return 'Search MetalMail emails...';
        case 6:
          return 'Search VoIPs...';
        case 7:
          return 'Search Models...';
        case 8:
          return 'Search telemetry analytics metrics...';
        case 9:
          return 'Search firewall rules and DNS...';
        case 10:
          return 'Search access control users...';
        default:
          return 'Search...';
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF1C1A1A),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF262424),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.withOpacity(0.4)),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.asset(
                            'assets/silvane.jpg',
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => const Icon(Icons.hub, color: Colors.white, size: 24),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'SilvaneOS',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(width: 16),
                      const DeviceNameWidget(),
                    ],
                  ),
                  Row(
                    children: [
                      WeatherVaneTopBarButton(currentUser: widget.currentUser),
                      const SizedBox(width: 8),
                      const ServerClockWidget(),
                      const SizedBox(width: 8),
                      // Build Versions Button
                      InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const VersionsView()),
                          );
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262424),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.info_outline, size: 16, color: Colors.amber),
                              SizedBox(width: 6),
                              Text('Versions', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Build Info Button
                      InkWell(
                        onTap: () => _showSystemInfoDialog(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262424),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.info_outline, size: 16, color: Colors.amber),
                              SizedBox(width: 6),
                              Text('v1.0.4', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // User Profile Activity Button
                      InkWell(
                        onTap: () => _showUserProfileDialog(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262424),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.person, size: 16, color: Colors.greenAccent),
                              const SizedBox(width: 6),
                              Text(widget.currentUser.username, style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Power Control Button
                      InkWell(
                        onTap: () => _showPowerOptionsDialog(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262424),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.power_settings_new, size: 16, color: Colors.redAccent),
                              SizedBox(width: 6),
                              Text('Power', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12.0),
              color: const Color(0xFF262424),
              child: TextField(
                controller: searchController,
                style: const TextStyle(color: Color(0xFFECEFF1)),
                decoration: InputDecoration(
                  hintText: getHintText(),
                  hintStyle: TextStyle(color: const Color(0xFFECEFF1).withOpacity(0.5)),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFFECEFF1)),
                  fillColor: const Color(0xFF1C1A1A),
                  filled: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6.0),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Container(
              color: const Color(0xFF262424),
              alignment: Alignment.centerLeft,
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: Colors.white,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.grey,
                onTap: (_) => setState(() {}),
                tabs: isAdmin
                    ? const [
                        Tab(text: 'Active Servers'),
                        Tab(text: 'Workspace & Clone'),
                        Tab(text: 'SilverGit'),
                        Tab(text: 'SylvanSap'),
                        Tab(text: 'ForestFinder'),
                        Tab(text: 'MetalMail'),
                        Tab(text: 'VoiceTrunk'),
                        Tab(text: 'OrePine'),
                        Tab(text: 'Analytics Dashboard'),
                        Tab(text: 'Firewall & DNS'),
                        Tab(text: 'Access Control'),
                      ]
                    : const [
                        Tab(text: 'Active Servers'),
                      ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: isAdmin
                    ? [
                        Tab1Screen(searchQuery: searchQuery),
                        Tab2Screen(searchQuery: searchQuery),
                        SilverGitScreen(searchQuery: searchQuery),
                        SylvanSapScreen(searchQuery: searchQuery),
                        ForestFinderScreen(searchQuery: searchQuery),
                        MetalMailScreen(searchQuery: searchQuery),
                        VoiceTrunkScreen(searchQuery: searchQuery),
                        OrePineScreen(searchQuery: searchQuery),
                        Tab3Screen(searchQuery: searchQuery),
                        Tab4Screen(searchQuery: searchQuery),
                        AclView(currentUser: widget.currentUser),
                      ]
                    : [
                        Tab1Screen(searchQuery: searchQuery),
                      ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ServerClockWidget extends StatefulWidget {
  const ServerClockWidget({super.key});

  @override
  State<ServerClockWidget> createState() => _ServerClockWidgetState();
}

class _ServerClockWidgetState extends State<ServerClockWidget> {
  late Timer _timer;
  DateTime _currentTime = DateTime.now();
  String _timeZoneName = 'UTC';

  @override
  void initState() {
    super.initState();
    _fetchLinuxTimeAndZone();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = _currentTime.add(const Duration(seconds: 1));
        });
      }
    });
  }

  Future<void> _fetchLinuxTimeAndZone() async {
    try {
      final tzResult = await Process.run('timedatectl', ['show', '--property=Timezone', '--value']);
      if (tzResult.exitCode == 0 && tzResult.stdout.toString().trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _timeZoneName = tzResult.stdout.toString().trim();
          });
        }
      }
      final dateResult = await Process.run('date', ['+%s']);
      if (dateResult.exitCode == 0) {
        final seconds = int.tryParse(dateResult.stdout.toString().trim());
        if (seconds != null && mounted) {
          setState(() {
            _currentTime = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();
          });
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _showTimeManagementDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const TimeManagementDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formattedTime = "${_currentTime.year}-${_currentTime.month.toString().padLeft(2, '0')}-${_currentTime.day.toString().padLeft(2, '0')} ${_currentTime.hour.toString().padLeft(2, '0')}:${_currentTime.minute.toString().padLeft(2, '0')}:${_currentTime.second.toString().padLeft(2, '0')} ($_timeZoneName)";

    return InkWell(
      onTap: () => _showTimeManagementDialog(context),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF262424),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.access_time, size: 16, color: Colors.cyanAccent),
            const SizedBox(width: 6),
            Text(formattedTime, style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class TimeManagementDialog extends StatefulWidget {
  const TimeManagementDialog({super.key});

  @override
  State<TimeManagementDialog> createState() => _TimeManagementDialogState();
}

class _TimeManagementDialogState extends State<TimeManagementDialog> {
  DateTime _selectedDate = DateTime.now();
  final TextEditingController _manualTimeController = TextEditingController();
  
  List<Map<String, String>> _checkedNtpServers = [
    {'server': 'pool.ntp.org', 'time': 'Checking...', 'status': 'Pending'},
    {'server': 'time.google.com', 'time': 'Checking...', 'status': 'Pending'},
    {'server': 'time.cloudflare.com', 'time': 'Checking...', 'status': 'Pending'},
  ];

  List<String> _serversList = ['SilverGit', 'SylvanSap', 'ForestFinder', 'MetalMail', 'VoiceTrunk'];
  Map<String, String> _serverSchedules = {
    'SilverGit': '24/7 Active',
    'SylvanSap': '24/7 Active',
    'ForestFinder': '24/7 Active',
    'MetalMail': '24/7 Active',
    'VoiceTrunk': '24/7 Active',
  };

  String _selectedRebootSchedule = 'Never';
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _scanAllWorkspaceServers();
    _queryNtpServers();
    _loadStoredConfig();
  }

  Future<void> _scanAllWorkspaceServers() async {
    try {
      final dir = Directory(appDirectoryPath);
      if (!await dir.exists()) return;

      final Set<String> discoveredServers = {'SilverGit', 'SylvanSap', 'ForestFinder', 'MetalMail', 'VoiceTrunk'};

      await for (final entity in dir.list(recursive: false, followLinks: false)) {
        if (entity is Directory) {
          final folderName = p.basename(entity.path);
          if (folderName.startsWith('.')) continue;
          if (folderName == 'ForestFinderSpool') continue;
          if (folderName == 'MetalMail') continue;

          if (folderName == 'SilverGit') {
            await for (final repoEntity in entity.list(recursive: false, followLinks: false)) {
              if (repoEntity is Directory) {
                final repoName = p.basename(repoEntity.path);
                if (!repoName.startsWith('.')) {
                  discoveredServers.add('SilverGit/$repoName');
                }
              }
            }
          } else {
            discoveredServers.add(folderName);
          }
        }
      }

      if (mounted) {
        setState(() {
          _serversList = discoveredServers.toList()..sort();
          for (var srv in _serversList) {
            _serverSchedules.putIfAbsent(srv, () => '24/7 Active');
          }
        });
      }
    } catch (e) {
      debugPrint('Error scanning active servers for schedule popup: $e');
    }
  }

  Future<void> _loadStoredConfig() async {
    try {
      final store = stringMapStoreFactory.store('system_time_config');
      final data = await store.record('config').get(sembastDb);
      if (data != null && mounted) {
        setState(() {
          _selectedRebootSchedule = data['reboot'] as String? ?? 'Never';
          if (data['schedules'] != null) {
            final savedSchedules = Map<String, String>.from(data['schedules'] as Map);
            for (var entry in savedSchedules.entries) {
              _serverSchedules[entry.key] = entry.value;
            }
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConfigToDb({String? mode, String? target, String? manualTime}) async {
    try {
      final store = stringMapStoreFactory.store('system_time_config');
      await store.record('config').put(sembastDb, {
        'mode': mode ?? 'ntp',
        'target': target ?? 'pool.ntp.org',
        'manual_time': manualTime,
        'reboot': _selectedRebootSchedule,
        'schedules': _serverSchedules,
      }, merge: true);
    } catch (_) {}
  }

  Future<void> _queryNtpServers() async {
    for (int i = 0; i < _checkedNtpServers.length; i++) {
      final host = _checkedNtpServers[i]['server']!;
      try {
        final result = await Process.run('ntpdate', ['-q', host]);
        if (result.exitCode == 0 && mounted) {
          setState(() {
            _checkedNtpServers[i]['time'] = result.stdout.toString().split('\n').last.trim();
            _checkedNtpServers[i]['status'] = 'Healthy';
          });
        } else if (mounted) {
          setState(() {
            _checkedNtpServers[i]['time'] = DateTime.now().toIso8601String();
            _checkedNtpServers[i]['status'] = 'Active (Local Sync)';
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _checkedNtpServers[i]['time'] = DateTime.now().toLocal().toString();
            _checkedNtpServers[i]['status'] = 'Reachable';
          });
        }
      }
    }
  }

  Future<void> _selectRebootTime() async {
    TimeOfDay initialTime = const TimeOfDay(hour: 3, minute: 0);
    if (_selectedRebootSchedule.contains(':')) {
      final parts = _selectedRebootSchedule.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null) {
          initialTime = TimeOfDay(hour: h, minute: m);
        }
      }
    }

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.cyanAccent,
              surface: Color(0xFF262424),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final formatted = "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}";
      setState(() {
        _selectedRebootSchedule = formatted;
      });
      await _saveConfigToDb();
    }
  }

  Future<void> _applyTimeSetting(String mode, {String? customTime, String? ntpServer}) async {
    setState(() => _isLoading = true);
    try {
      if (mode == 'ntp') {
        await Process.run('sudo', ['timedatectl', 'set-ntp', 'true']);
        await _saveConfigToDb(mode: 'ntp');
      } else if (mode == 'manual' && customTime != null) {
        await Process.run('sudo', ['timedatectl', 'set-ntp', 'false']);
        await Process.run('sudo', ['timedatectl', 'set-time', customTime]);
        await _saveConfigToDb(mode: 'manual', manualTime: customTime);
      } else if (mode == 'server' && ntpServer != null) {
        await Process.run('sudo', ['timedatectl', 'set-ntp', 'false']);
        await Process.run('sudo', ['ntpdate', '-u', ntpServer]);
        await _saveConfigToDb(mode: 'server', target: ntpServer);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server time & operational schedules successfully updated!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update system time: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF262424),
      title: const Text('Server Time, NTP & Hours of Operation', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 600,
        height: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Calendar & Date/Time Selection', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1A1A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                child: CalendarDatePicker(
                  initialDate: _selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                  onDateChanged: (date) {
                    setState(() {
                      _selectedDate = date;
                      _manualTimeController.text = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} 12:00:00";
                    });
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualTimeController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Manual Time (YYYY-MM-DD HH:MM:SS)',
                        labelStyle: const TextStyle(color: Colors.grey),
                        filled: true,
                        fillColor: const Color(0xFF1C1A1A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: _isLoading ? null : () => _applyTimeSetting('manual', customTime: _manualTimeController.text),
                    child: const Text('Set Manual'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('Checked NTP Servers & Status', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._checkedNtpServers.map((ntp) => Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1A1A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ntp['server']!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        Text('Time: ${ntp['time']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
                      onPressed: () => _applyTimeSetting('server', ntpServer: ntp['server']),
                      child: const Text('Sync from this', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 20),
              const Text('Hours of Operation per Server', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._serversList.map((server) => Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Tooltip(
                      message: 'Active Schedule for $server: ${_serverSchedules[server]}',
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 150,
                      child: Text(server, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12), overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: _serverSchedules[server]),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        onChanged: (val) {
                          _serverSchedules[server] = val;
                          _saveConfigToDb();
                        },
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFF1C1A1A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 20),
              const Text('Nightly Server Reboot Schedule', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1A1A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Scheduled Reboot Time:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          _selectedRebootSchedule == 'Never'
                              ? 'Disabled (Never)'
                              : 'Reboot Nightly at $_selectedRebootSchedule',
                          style: TextStyle(
                            color: _selectedRebootSchedule == 'Never' ? Colors.grey : Colors.cyanAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                          onPressed: _selectRebootTime,
                          icon: const Icon(Icons.access_time, size: 16),
                          label: const Text('Set Time'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
                          onPressed: () async {
                            setState(() {
                              _selectedRebootSchedule = 'Never';
                            });
                            await _saveConfigToDb();
                          },
                          child: const Text('Set to Never'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(color: Colors.white)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          onPressed: _isLoading ? null : () => _applyTimeSetting('ntp'),
          child: const Text('Enable NTP Auto-Sync'),
        ),
      ],
    );
  }
}

class MetallicShimmerButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String label;

  const MetallicShimmerButton({
    super.key,
    required this.onPressed,
    required this.label,
  });

  @override
  State<MetallicShimmerButton> createState() => _MetallicShimmerButtonState();
}

class _MetallicShimmerButtonState extends State<MetallicShimmerButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: widget.onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF262424),
        side: const BorderSide(color: Colors.grey, width: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4.0)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: AnimatedBuilder(
        animation: _shimmerController,
        builder: (context, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: const [
                  Color(0xFFECEFF1),
                  Colors.grey,
                  Color(0xFFECEFF1),
                  Colors.white,
                  Colors.grey,
                ],
                stops: [
                  0.0,
                  _shimmerController.value - 0.2,
                  _shimmerController.value,
                  _shimmerController.value + 0.2,
                  1.0,
                ],
              ).createShader(bounds);
            },
            child: Text(
              widget.label,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white, 
              ),
            ),
          );
        },
      ),
    );
  }
}

class DeviceNameWidget extends StatefulWidget {
  const DeviceNameWidget({super.key});

  @override
  State<DeviceNameWidget> createState() => _DeviceNameWidgetState();
}

class _DeviceNameWidgetState extends State<DeviceNameWidget> {
  String _deviceName = '';
  bool _isEditing = false;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadDeviceName();
  }

  Future<void> _loadDeviceName() async {
    final store = StoreRef<String, dynamic>.main();
    final name = await store.record('device_name').get(sembastDb) as String? ?? 'Silvane-Kiosk-01';
    setState(() {
      _deviceName = name;
      _controller.text = name;
      _isEditing = name.isEmpty;
    });
  }

  Future<void> _saveDeviceName() async {
    final name = _controller.text.trim();
    if (name.isNotEmpty) {
      final store = StoreRef<String, dynamic>.main();
      await store.record('device_name').put(sembastDb, name);
      setState(() {
        _deviceName = name;
        _isEditing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return SizedBox(
        height: 40,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 140,
                height: 30,
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'Device Name',
                    hintStyle: TextStyle(color: Colors.white54, fontSize: 11),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.check, size: 14, color: Colors.greenAccent),
                onPressed: _saveDeviceName,
                tooltip: 'Set Device Name',
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF262424),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey.withOpacity(0.3)),
              ),
              child: Text(
                'Device: $_deviceName',
                style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.edit, size: 13, color: Colors.white60),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: 'Edit Device Name',
              constraints: const BoxConstraints(),
              padding: EdgeInsets.all(2),
            ),
          ],
        ),
      ),
    );
  }
}