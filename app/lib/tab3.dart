import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'main.dart';

class Tab3Screen extends StatefulWidget {
  final String searchQuery;
  const Tab3Screen({super.key, required this.searchQuery});

  @override
  State<Tab3Screen> createState() => _Tab3ScreenState();
}

class TelemetryRecord {
  final DateTime timestamp;
  final String ip;
  final String path;
  final int latencyMs;
  String whoisOrg;

  TelemetryRecord({
    required this.timestamp,
    required this.ip,
    required this.path,
    required this.latencyMs,
    this.whoisOrg = 'Resolving...',
  });
}

class _Tab3ScreenState extends State<Tab3Screen> {
  String _selectedHorizon = 'Last 30 Days';
  final List<String> _horizons = ['Individual Day', 'Last 30 Days', 'Last 6 Months', 'Last Year', 'Last 5 Years'];
  
  bool _isLoading = true;
  List<TelemetryRecord> _records = [];
  final Map<String, String> _whoisCache = {};

  @override
  void initState() {
    super.initState();
    _loadAndEnrichAnalytics();
  }

  Future<String> _fetchWhois(String ip) async {
    if (ip == '127.0.0.1' || ip == '::1' || ip.startsWith('192.168.') || ip.startsWith('10.')) {
      return 'Local Loopback / Private LAN';
    }
    if (_whoisCache.containsKey(ip)) {
      return _whoisCache[ip]!;
    }
    try {
      final result = await Process.run('whois', [ip]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (var line in lines) {
          final lower = line.toLowerCase();
          if (lower.startsWith('orgname:') || lower.startsWith('organization:') || lower.startsWith('netname:')) {
            final val = line.split(':').last.trim();
            _whoisCache[ip] = val;
            return val;
          }
        }
      }
    } catch (_) {}
    _whoisCache[ip] = 'External IP (Standard Route)';
    return _whoisCache[ip]!;
  }

  void _showWhoisReportDialog(BuildContext context, String ip) {
    showDialog(
      context: context,
      builder: (context) => WhoisReportDialog(ipAddress: ip),
    );
  }

  Future<void> _loadAndEnrichAnalytics() async {
    setState(() => _isLoading = true);
    _records.clear();

    final logsRootDir = Directory(p.join(appDirectoryPath, '.silvane_logs'));
    if (!await logsRootDir.exists()) {
      setState(() => _isLoading = false);
      return;
    }

    final now = DateTime.now();
    List<TelemetryRecord> tempRecords = [];

    await for (final repoDir in logsRootDir.list(followLinks: false)) {
      if (repoDir is Directory) {
        await for (final file in repoDir.list(followLinks: false)) {
          if (file is File && p.basename(file.path).startsWith('ACTIVITY_')) {
            final name = p.basename(file.path);
            final datePart = name.replaceAll('ACTIVITY_', '').replaceAll('.log', '');
            final fileDate = DateTime.tryParse(datePart);

            if (fileDate != null) {
              bool matchesHorizon = false;
              if (_selectedHorizon == 'IndividualDay') {
                // Handled below
              }

              if (_selectedHorizon == 'Individual Day') {
                matchesHorizon = fileDate.year == now.year && fileDate.month == now.month && fileDate.day == now.day;
              } else if (_selectedHorizon == 'Last 30 Days') {
                final cutoff = now.subtract(const Duration(days: 30));
                matchesHorizon = fileDate.isAfter(cutoff) || fileDate.isAtSameMomentAs(DateTime(cutoff.year, cutoff.month, cutoff.day));
              } else if (_selectedHorizon == 'Last 6 Months') {
                final cutoff = now.subtract(const Duration(days: 180));
                matchesHorizon = fileDate.isAfter(cutoff) || fileDate.isAtSameMomentAs(DateTime(cutoff.year, cutoff.month, cutoff.day));
              } else if (_selectedHorizon == 'Last Year') {
                final cutoff = now.subtract(const Duration(days: 365));
                matchesHorizon = fileDate.isAfter(cutoff) || fileDate.isAtSameMomentAs(DateTime(cutoff.year, cutoff.month, cutoff.day));
              } else if (_selectedHorizon == 'Last 5 Years') {
                final cutoff = now.subtract(const Duration(days: 1825));
                matchesHorizon = fileDate.isAfter(cutoff) || fileDate.isAtSameMomentAs(DateTime(cutoff.year, cutoff.month, cutoff.day));
              }

              if (matchesHorizon) {
                final lines = await file.readAsLines();
                for (var line in lines) {
                  try {
                    // Format: [timestamp] IP: x | Path: y | Latency: zms
                    final timeMatch = RegExp(r'\[(.*?)\]').firstMatch(line);
                    final ipMatch = RegExp(r'IP:\s*([^\s|]+)').firstMatch(line);
                    final pathMatch = RegExp(r'Path:\s*([^\s|]+)').firstMatch(line);
                    final latMatch = RegExp(r'Latency:\s*([0-9]+)ms').firstMatch(line);

                    if (timeMatch != null && ipMatch != null && pathMatch != null && latMatch != null) {
                      tempRecords.add(TelemetryRecord(
                        timestamp: DateTime.parse(timeMatch.group(1)!),
                        ip: ipMatch.group(1)!,
                        path: pathMatch.group(1)!,
                        latencyMs: int.parse(latMatch.group(1)!),
                      ));
                    }
                  } catch (_) {}
                }
              }
            }
          }
        }
      }
    }

    // Sort descending by timestamp
    tempRecords.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Resolve whois for unique IPs
    final uniqueIps = tempRecords.map((r) => r.ip).toSet();
    for (var ip in uniqueIps) {
      final org = await _fetchWhois(ip);
      for (var rec in tempRecords.where((r) => r.ip == ip)) {
        rec.whoisOrg = org;
      }
    }

    if (mounted) {
      setState(() {
        _records = tempRecords;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.searchQuery.trim().toLowerCase();
    final filteredRecords = _records.where((r) {
      return r.ip.toLowerCase().contains(query) ||
          r.path.toLowerCase().contains(query) ||
          r.whoisOrg.toLowerCase().contains(query);
    }).toList();

    // Compute metrics
    int totalReqs = filteredRecords.length;
    int uniqueIps = filteredRecords.map((r) => r.ip).toSet().length;
    double avgLatency = totalReqs > 0 ? filteredRecords.map((r) => r.latencyMs).reduce((a, b) => a + b) / totalReqs : 0.0;

    // Path counts map
    Map<String, int> pathCounts = {};
    for (var r in filteredRecords) {
      pathCounts[r.path] = (pathCounts[r.path] ?? 0) + 1;
    }

    return Container(
      color: const Color(0xFF1C1A1A),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Horizon Filter Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Server Telemetry & Activity Intelligence',
                    style: TextStyle(color: Color(0xFFECEFF1), fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Real-time request tracing, WHOIS network attribution, and performance metrics.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
              Row(
                children: [
                  MetallicShimmerButton(
                    onPressed: _loadAndEnrichAnalytics,
                    label: 'Refresh Telemetry',
                  ),
                  const SizedBox(width: 12),
                  const Text('Horizon: ', style: TextStyle(color: Colors.grey)),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _selectedHorizon,
                    dropdownColor: const Color(0xFF262424),
                    style: const TextStyle(color: Color(0xFFECEFF1)),
                    items: _horizons.map((String horizon) {
                      return DropdownMenuItem<String>(
                        value: horizon,
                        child: Text(horizon),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setState(() => _selectedHorizon = newValue);
                        _loadAndEnrichAnalytics();
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Top Metric KPI Summary Cards
          Row(
            children: [
              Expanded(child: _buildKpiCard('Total Requests', totalReqs.toString(), Icons.bolt, Colors.amberAccent)),
              const SizedBox(width: 12),
              Expanded(child: _buildKpiCard('Unique Visitors (IPs)', uniqueIps.toString(), Icons.public, Colors.blueAccent)),
              const SizedBox(width: 12),
              Expanded(child: _buildKpiCard('Average Latency', '${avgLatency.toStringAsFixed(1)} ms', Icons.timer, Colors.greenAccent)),
              const SizedBox(width: 12),
              Expanded(child: _buildKpiCard('Tracked Endpoints', pathCounts.keys.length.toString(), Icons.lan, Colors.purpleAccent)),
            ],
          ),
          const SizedBox(height: 16),

          // Main Multi-Grid Dashboard Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left Column: Path Distribution Summary
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            Expanded(
                              child: _buildSectionCard(
                                'Endpoint Hit Frequencies',
                                Icons.bar_chart,
                                pathCounts.isEmpty
                                    ? const Center(child: Text('No endpoint data found.', style: TextStyle(color: Colors.grey)))
                                    : ListView(
                                        children: pathCounts.entries.map((e) {
                                          double pct = totalReqs > 0 ? (e.value / totalReqs) : 0.0;
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Text(e.key, style: const TextStyle(color: Color(0xFFECEFF1), fontWeight: FontWeight.bold, fontSize: 13)),
                                                    Text('${e.value} hits (${(pct * 100).toStringAsFixed(1)}%)', style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                LinearProgressIndicator(
                                                  value: pct,
                                                  backgroundColor: const Color(0xFF1C1A1A),
                                                  color: Colors.greenAccent,
                                                  minHeight: 6,
                                                ),
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Right Column: Detailed Request Stream with Clickable WHOIS Reports
                      Expanded(
                        flex: 6,
                        child: _buildSectionCard(
                          'Live Visitor Activity & WHOIS Attribution Log',
                          Icons.security,
                          filteredRecords.isEmpty
                              ? const Center(child: Text('No telemetry logs matching query.', style: TextStyle(color: Colors.grey)))
                              : ListView.builder(
                                  itemCount: filteredRecords.length,
                                  itemBuilder: (context, index) {
                                    final rec = filteredRecords[index];
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1C1A1A),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.white10),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Text(rec.ip, style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: Colors.blueAccent.withOpacity(0.15),
                                                        borderRadius: BorderRadius.circular(4),
                                                      ),
                                                      child: Text(rec.whoisOrg, style: const TextStyle(color: Colors.blueAccent, fontSize: 10)),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                Text('Requested: ${rec.path}', style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 12)),
                                                const SizedBox(height: 2),
                                                Row(
                                                  children: [
                                                    Text('Timestamp: ${rec.timestamp.toLocal().toString().split('.').first}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                                    const SizedBox(width: 12),
                                                    InkWell(
                                                      onTap: () => _showWhoisReportDialog(context, rec.ip),
                                                      child: const Text(
                                                        '[View WHOIS Report]',
                                                        style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: rec.latencyMs > 200 ? Colors.red.withOpacity(0.2) : Colors.green.withOpacity(0.2),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '${rec.latencyMs} ms',
                                                  style: TextStyle(
                                                    color: rec.latencyMs > 200 ? Colors.redAccent : Colors.greenAccent,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              const Text('Latency', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                            ],
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF262424),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, IconData icon, Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF262424),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          const Divider(color: Colors.white10, height: 20),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class WhoisReportDialog extends StatefulWidget {
  final String ipAddress;
  const WhoisReportDialog({super.key, required this.ipAddress});

  @override
  State<WhoisReportDialog> createState() => _WhoisReportDialogState();
}

class _WhoisReportDialogState extends State<WhoisReportDialog> {
  bool _isLoading = true;
  String _whoisOutput = '';

  @override
  void initState() {
    super.initState();
    _fetchWhoisReport();
  }

  Future<void> _fetchWhoisReport() async {
    if (widget.ipAddress == '127.0.0.1' || widget.ipAddress == '::1' || widget.ipAddress.startsWith('192.168.') || widget.ipAddress.startsWith('10.')) {
      setState(() {
        _whoisOutput = 'WHOIS Report not applicable for local loopback or private LAN address (${widget.ipAddress}).';
        _isLoading = false;
      });
      return;
    }

    try {
      final result = await Process.run('whois', [widget.ipAddress]);
      setState(() {
        _whoisOutput = result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty
            ? result.stdout.toString()
            : 'Failed to retrieve WHOIS record or command unavailable.';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _whoisOutput = 'Exception executing whois utility: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1A1A),
      title: Text('WHOIS Report: ${widget.ipAddress}', style: const TextStyle(color: Colors.white, fontSize: 16)),
      content: SizedBox(
        width: 650,
        height: 450,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.amber))
            : Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _whoisOutput,
                    style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}