import 'package:sembast/sembast.dart';
import 'main.dart';

/*
How to use:
await LogService.log(
  title: 'Network Event',
  message: 'WireGuard tunnel successfully established.',
  author: 'Admin',
);
*/

class LogService {
  static Future<void> log({
    required String title,
    required String message,
    String author = 'System Daemon',
    String deviceName = 'Silvane-Kiosk-01',
  }) async {
    try {
      final store = StoreRef<String, dynamic>('weather_vane_notifications');
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      
      final notifMap = {
        'id': id,
        'title': title,
        'message': message,
        'author': author,
        'deviceName': deviceName,
        'timestamp': DateTime.now().toIso8601String(),
        'jwtSignature': 'JWT_SYSTEM_AUTOGEN_${DateTime.now().millisecondsSinceEpoch}',
      };

      await store.record(id).put(sembastDb, notifMap);
    } catch (e) {
      // Fallback debug print if database isn't fully ready
      print('LogService error: $e');
    }
  }
}