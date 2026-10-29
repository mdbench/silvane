import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sembast/sembast.dart';
import 'db_service.dart';
import 'main.dart';

class VoiceTrunkScreen extends StatefulWidget {
  final String searchQuery;
  const VoiceTrunkScreen({super.key, required this.searchQuery});

  @override
  State<VoiceTrunkScreen> createState() => _VoiceTrunkScreenState();

  // --- Static Linux SIP Daemon State & Methods ---
  static bool _isDaemonRunning = false;
  static bool _hasInitializedDaemon = false;
  static const String _dbKeyVoiceRunning = 'voice_trunk_daemon_running';

  static final List<String> _daemonLogs = [];

  static void _log(String message) {
    final entry = '[${DateTime.now().toLocal().toString().split('.').first}] $message';
    debugPrint('[VoiceTrunk-SIP] $message');
    _daemonLogs.insert(0, entry);
    if (_daemonLogs.length > 100) _daemonLogs.removeLast();
  }

  /// Public static method to start the Linux SIP daemon on app boot if enabled.
  static Future<void> startServerIfEnabled() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      
      // 1. Check if persistently enabled by user
      final persistedState = await store.record(_dbKeyVoiceRunning).get(sembastDb) as bool? ?? false;
      if (!persistedState) return;
      
      // 2. Check Hours of Operation configuration from the Sembast 'system_time_config' store
      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['VoiceTrunk'] ?? '24/7 Active';
          
          if (!scheduleStr.toLowerCase().contains('24/7') && !scheduleStr.toLowerCase().contains('active')) {
            if (scheduleStr.contains('-')) {
              final parts = scheduleStr.split('-');
              if (parts.length == 2) {
                final now = DateTime.now();
                final currentMinutes = now.hour * 60 + now.minute;
                final startParts = parts[0].trim().split(':');
                final endParts = parts[1].trim().split(':');
                if (startParts.length == 2 && endParts.length == 2) {
                  final startMinutes = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
                  final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);
                  
                  if (startMinutes <= endMinutes) {
                    withinHours = currentMinutes >= startMinutes && currentMinutes <= endMinutes;
                  } else {
                    withinHours = currentMinutes >= startMinutes || currentMinutes <= endMinutes;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      // 3. Evaluate combined conditions
      final shouldBeRunning = persistedState && withinHours;

      if (shouldBeRunning && !_isDaemonRunning) {
        await _startLinuxSipDaemon();
        _log('Daemon started automatically (Enabled & Within Hours).');
      } else if (!shouldBeRunning && _isDaemonRunning) {
        await _stopLinuxSipDaemon();
        _log('Daemon stopped automatically (Disabled or Outside Hours).');
      }
    } catch (e) {
      _log('Failed to evaluate daemon state on schedule tick: $e');
    }
  }

  static Future<void> _startLinuxSipDaemon() async {
    if (_isDaemonRunning) return;
    try {
      _log('Starting Kamailio SIP daemon as kiosk user via non-interactive sudo...');
      
      // Execute system command using sudo -n to fail fast instead of hanging on a password prompt
      final result = await Process.run('sudo', ['-n', 'systemctl', 'start', 'kamailio']);
      if (result.exitCode != 0) {
        // Fallback to direct binary execution if systemctl fails
        final fallback = await Process.run('sudo', ['-n', 'kamailio', '-P', '/var/run/kamailio.pid', '-DD']);
        if (fallback.exitCode != 0) {
          throw Exception(result.stderr.toString().isNotEmpty ? result.stderr : fallback.stderr);
        }
      }

      _isDaemonRunning = true;
      _log('Linux SIP daemon successfully started and bound to port 5060.');
    } catch (e) {
      _isDaemonRunning = false;
      _log('Failed to start Linux SIP daemon: $e. Ensure kiosk user has NOPASSWD sudo privileges.');
    }
  }

  static Future<void> _stopLinuxSipDaemon() async {
    try {
      _log('Stopping Linux SIP daemon and killing CLI background processes as kiosk user...');
      
      // Stop via non-interactive sudo systemctl and killall
      await Process.run('sudo', ['-n', 'systemctl', 'stop', 'kamailio']);
      await Process.run('sudo', ['-n', 'killall', '-9', 'kamailio']);

      _isDaemonRunning = false;
      _log('Linux SIP daemon completely stopped and unloaded from CLI.');
    } catch (e) {
      _log('Error stopping SIP daemon: $e');
    }
  }
}

class _VoiceTrunkScreenState extends State<VoiceTrunkScreen> with AutomaticKeepAliveClientMixin {
  List<String> _allUsers = [];
  bool _isLoadingUsers = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadUsersList();
    if (!VoiceTrunkScreen._hasInitializedDaemon) {
      VoiceTrunkScreen._hasInitializedDaemon = true;
      _loadPersistedDaemonState();
    }
  }

  Future<void> _loadPersistedDaemonState() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(VoiceTrunkScreen._dbKeyVoiceRunning).get(sembastDb) as bool? ?? false;
      if (persistedState) {
        await _toggleVoiceDaemon(true, silent: true);
      }
    } catch (e) {
      debugPrint('Failed to load persisted VoiceTrunk state: $e');
    }
  }

  Future<void> _persistDaemonState(bool running) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(VoiceTrunkScreen._dbKeyVoiceRunning).put(sembastDb, running);
    } catch (e) {
      debugPrint('Failed to save VoiceTrunk state: $e');
    }
  }

  Future<void> _loadUsersList() async {
    setState(() => _isLoadingUsers = true);
    final users = await DbService().getAllUsers();
    setState(() {
      _allUsers = users.map((u) => u.username).toList();
      _isLoadingUsers = false;
    });
  }

  Future<void> _toggleVoiceDaemon(bool enable, {bool silent = false}) async {
    await _persistDaemonState(enable);
    if (enable) {
      await VoiceTrunkScreen._startLinuxSipDaemon();
      if (mounted) setState(() {});

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('VoiceTrunk Linux SIP Daemon started on port 5060.')),
        );
      }
    } else {
      await VoiceTrunkScreen._stopLinuxSipDaemon();
      if (mounted) setState(() {});

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('VoiceTrunk Linux SIP Daemon completely stopped.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: const Color(0xFF1C1A1A),
      body: Row(
        children: [
          // Left Sidebar: Daemon Switch & Extensions
          Container(
            width: 260,
            color: const Color(0xFF222020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text('VoiceTrunk SIP Daemon', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: VoiceTrunkScreen._isDaemonRunning ? Colors.cyan.withOpacity(0.1) : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: VoiceTrunkScreen._isDaemonRunning ? Colors.cyanAccent.withOpacity(0.3) : Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(VoiceTrunkScreen._isDaemonRunning ? 'Daemon: Active' : 'Daemon: Stopped', style: TextStyle(color: VoiceTrunkScreen._isDaemonRunning ? Colors.cyanAccent : Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                          Switch(
                            value: VoiceTrunkScreen._isDaemonRunning,
                            onChanged: (val) => _toggleVoiceDaemon(val),
                            activeColor: Colors.cyanAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text('Port: 5060 (UDP/TCP SIP)', style: TextStyle(color: Colors.white60, fontSize: 10)),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('ACL Extensions', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white54, size: 14),
                        onPressed: _loadUsersList,
                        tooltip: 'Refresh Users',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _isLoadingUsers
                      ? const Center(child: CircularProgressIndicator())
                      : _allUsers.isEmpty
                          ? const Center(child: Text('No ACL users found.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                          : ListView.builder(
                              itemCount: _allUsers.length,
                              itemBuilder: (context, index) {
                                final username = _allUsers[index];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.phone_in_talk, color: Colors.cyanAccent, size: 16),
                                  title: Text('Ext: $username', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                  subtitle: const Text('Ready for hardware registration', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white12),

          // Center Main Pane: CLI Process Logs
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('VoiceTrunk Linux SIP Backend Control', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                      Text('Protocol: SIP / RTP Hardware Relay', style: TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('CLI Daemon Process & Call Activity Logs', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: VoiceTrunkScreen._daemonLogs.isEmpty
                          ? const Center(child: Text('Daemon logs empty. Toggle the switch to start the Linux backend process.', style: TextStyle(color: Colors.grey, fontSize: 11)))
                          : ListView.builder(
                              itemCount: VoiceTrunkScreen._daemonLogs.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    VoiceTrunkScreen._daemonLogs[index],
                                    style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 11),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}