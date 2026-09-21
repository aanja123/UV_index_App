import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UV Index',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      home: const UVScreen(),
    );
  }
}

Future<Map<String, dynamic>> fetchUVData(double lat, double lon) async {
  print('Fetching UV data for lat=$lat, lon=$lon');
  final url = Uri.parse(
    'https://api.open-meteo.com/v1/forecast'
    '?latitude=$lat&longitude=$lon'
    '&hourly=uv_index'
    '&past_days=1'
    '&forecast_days=2'
    '&timezone=auto',
  );

  final response = await http.get(url);

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception('Failed to load UV data');
  }
}

Future<List<Map<String, dynamic>>> searchCity(String query) async {
  final url = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search'
    '?name=${Uri.encodeComponent(query)}'
    '&count=5'
    '&language=en',
  );

  final response = await http.get(url);

  if (response.statusCode == 200) {
    final result = jsonDecode(response.body);
    final results = result['results'];
    if (results == null) return [];
    return List<Map<String, dynamic>>.from(results);
  } else {
    throw Exception('Failed to search city');
  }
}

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Europe/Ljubljana'));

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);

  await notificationsPlugin.initialize(initSettings);

  final androidPlugin = notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
  await androidPlugin?.requestExactAlarmsPermission();
}

Future<void> scheduleUVNotification(String message, int hour, int minute) async {
  await notificationsPlugin.cancelAll();

  final now = tz.TZDateTime.now(tz.local);
  var scheduledDate = tz.TZDateTime(
    tz.local, now.year, now.month, now.day, hour, minute,
  );

  if (scheduledDate.isBefore(now)) {
    scheduledDate = scheduledDate.add(const Duration(days: 1));
  }
  print('Final scheduled date: $scheduledDate (now: $now)');
  await notificationsPlugin.zonedSchedule(
    0,
    'UV Index Update',
    message,
    scheduledDate,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'uv_channel',
        'UV Notifications',
        channelDescription: 'Daily UV index reminder',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
  );
}

Future<void> showTestNotification() async {
  await notificationsPlugin.show(
    1,
    'Test',
    'If you see this, notifications work!',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'uv_channel',
        'UV Notifications',
        channelDescription: 'Daily UV index reminder',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

Future<void> checkPendingNotifications() async {
  final pending = await notificationsPlugin.pendingNotificationRequests();
  print('Pending notifications: ${pending.length}');
  for (var p in pending) {
    print('ID: ${p.id}, Title: ${p.title}, Body: ${p.body}');
  }
}

class UVScreen extends StatefulWidget {
  const UVScreen({super.key});

  @override
  State<UVScreen> createState() => _UVScreenState();
}

class _UVScreenState extends State<UVScreen> {
  Map<String, dynamic>? data;
  int selectedDay = 1; // 0 = yesterday, 1 = today, 2 = tomorrow
  double latitude = 46.05;
  double longitude = 14.51;
  bool loadingLocation = false;
  final TextEditingController searchController = TextEditingController();
  List<Map<String, dynamic>> searchResults = [];
  Timer? _debounce;
  bool notificationsEnabled = false;
  TimeOfDay notificationTime = const TimeOfDay(hour: 8, minute: 0);
  String currentLocationName = 'Ljubljana';

  @override
  void initState() {
    super.initState();
    _initApp();
    //showTestNotification();
  }

  Future<void> _initApp() async {
    await _loadSettings();
    _loadUVData();
  }

  void _loadUVData() {
    fetchUVData(latitude, longitude).then((result) {
      setState(() => data = result);
    });
  }

  // Splits the 72 hourly entries into 3 lists of 24 (yesterday/today/tomorrow)
  List<List<double>> getUVByDay() {
    final uvValues = (data!['hourly']['uv_index'] as List)
        .map((v) => (v as num).toDouble())
        .toList();

    return [
      uvValues.sublist(0, 24),
      uvValues.sublist(24, 48),
      uvValues.sublist(48, 72),
    ];
  }

  List<List<String>> getTimesByDay() {
    final times = (data!['hourly']['time'] as List).cast<String>();

    return [
      times.sublist(0, 24),
      times.sublist(24, 48),
      times.sublist(48, 72),
    ];
  }

  Color uvColor(double uv) {
    if (uv < 3) return Colors.green;
    if (uv < 6) return Colors.yellow.shade700;
    if (uv < 8) return Colors.orange;
    return Colors.red;
  }

  Future<void> _getCurrentLocation() async {
    setState(() => loadingLocation = true);

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => loadingLocation = false);
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => loadingLocation = false);
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => loadingLocation = false);
      return;
    }

    final position = await Geolocator.getCurrentPosition();
    print('GPS location: lat=${position.latitude}, lon=${position.longitude}');
    final locationName = await reverseGeocode(position.latitude, position.longitude);

    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
      currentLocationName = locationName;
      loadingLocation = false;
    });

    _saveLocation();
    _loadUVData();
  }

  Future<void> _searchCity(String query) async {
    if (query.trim().isEmpty) {
      setState(() => searchResults = []);
      return;
    }
    final results = await searchCity(query);
    setState(() => searchResults = results);
  }

  void _selectCity(Map<String, dynamic> city) {
    setState(() {
      latitude = city['latitude'];
      longitude = city['longitude'];
      currentLocationName = city['name'];
      searchResults = [];
      searchController.clear();
    });
    _saveLocation();
    _loadUVData();
  }

  Future<String> reverseGeocode(double lat, double lon) async {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse'
      '?lat=$lat&lon=$lon&format=json',
    );

    final response = await http.get(url, headers: {'User-Agent': 'uv_index_app'});

    if (response.statusCode == 200) {
      final result = jsonDecode(response.body);
      final address = result['address'];
      return address['city'] ?? address['town'] ?? address['village'] ?? 'Unknown location';
    } else {
      return 'Unknown location';
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (query.trim().length >= 3) {
        _searchCity(query);
      } else {
        setState(() => searchResults = []);
      }
    });
  }

  String getUVMessage(List<double> uvValues, List<String> times) {
    final maxUV = uvValues.reduce((a, b) => a > b ? a : b);

    if (maxUV < 3) {
      return 'UV index is below 3 all day. No need for sunscreen.';
    }

    int firstIndex = uvValues.indexWhere((uv) => uv >= 3);
    int lastIndex = uvValues.lastIndexWhere((uv) => uv >= 3);

    final startHour = times[firstIndex].split('T')[1].substring(0, 2);
    final endHour = times[lastIndex].split('T')[1].substring(0, 2);

    if (firstIndex == lastIndex) {
      return 'Max UV index today is ${maxUV.toStringAsFixed(1)}. '
          'Wear sunscreen at $startHour:00.';
    }

    return 'Max UV index today is ${maxUV.toStringAsFixed(1)}. '
        'Wear sunscreen from $startHour:00 to $endHour:00.';
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      notificationsEnabled = prefs.getBool('notificationsEnabled') ?? false;
      final savedHour = prefs.getInt('notificationHour') ?? 8;
      final savedMinute = prefs.getInt('notificationMinute') ?? 0;
      notificationTime = TimeOfDay(hour: savedHour, minute: savedMinute);

      latitude = prefs.getDouble('latitude') ?? 46.05;
      longitude = prefs.getDouble('longitude') ?? 14.51;
      currentLocationName = prefs.getString('locationName') ?? 'Ljubljana';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationsEnabled', notificationsEnabled);
    await prefs.setInt('notificationHour', notificationTime.hour);
    await prefs.setInt('notificationMinute', notificationTime.minute);
  }

  Future<void> _saveLocation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('latitude', latitude);
    await prefs.setDouble('longitude', longitude);
    await prefs.setString('locationName', currentLocationName);
  }

  void _showTableSheet(BuildContext context, List<String> times, List<double> uvValues) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 50),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.6,
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Hour-by-hour', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: times.length,
                    itemBuilder: (context, index) {
                      final hourLabel = times[index].split('T')[1];
                      final uv = uvValues[index];
                      return ListTile(
                        title: Text(hourLabel),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: uvColor(uv).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'UV: ${uv.toStringAsFixed(1)}',
                            style: TextStyle(color: uvColor(uv), fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Notification Settings', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Daily reminder'),
                      value: notificationsEnabled,
                      onChanged: (value) {
                        setModalState(() => notificationsEnabled = value);
                        setState(() => notificationsEnabled = value);
                      },
                    ),
                    ListTile(
                      title: const Text('Notification time'),
                      trailing: Text(notificationTime.format(context)),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: notificationTime,
                        );
                        if (picked != null) {
                          setModalState(() => notificationTime = picked);
                          setState(() => notificationTime = picked);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () async {
                        await _saveSettings();
                        try {
                          if (notificationsEnabled) {
                            final todayUV = getUVByDay()[1];
                            final todayTimes = getTimesByDay()[1];
                            final message = getUVMessage(todayUV, todayTimes);
                            print('Scheduling notification: "$message" at ${notificationTime.hour}:${notificationTime.minute}');
                            await scheduleUVNotification(
                              message,
                              notificationTime.hour,
                              notificationTime.minute,
                            );
                            print('Notification scheduled successfully');
                            await checkPendingNotifications();
                          } else {
                            await notificationsPlugin.cancelAll();
                          }
                        } catch (e) {
                          print('Error scheduling notification: $e');
                        }
                        if (context.mounted) Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFECB3),
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final uvByDay = getUVByDay();
    final timesByDay = getTimesByDay();
    final dayUV = uvByDay[selectedDay];
    final dayTimes = timesByDay[selectedDay];

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showSettingsSheet(context),
        backgroundColor: const Color(0xFFFFECB3),
        foregroundColor: Colors.black87,
        child: const Icon(Icons.settings),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFB3E5FC), // light sky blue
              Color(0xFFE1F5FE), // very pale blue near bottom
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Stack(
              children: [
                Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: ElevatedButton.icon(
                            onPressed: loadingLocation ? null : _getCurrentLocation,
                            icon: loadingLocation
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.my_location),
                            label: const Text('My location'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFFF9C4),
                              foregroundColor: Colors.black87,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            onChanged: _onSearchChanged,
                            decoration: InputDecoration(
                              hintText: 'Search city...',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      currentLocationName,
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          selectedBackgroundColor: const Color(0xFFFFF9C4),
                          selectedForegroundColor: Colors.black87,
                        ),
                      segments: const [
                        ButtonSegment(
                          value: 0,
                          label: SizedBox(width: 80, child: Center(child: Text('Yesterday'))),
                        ),
                        ButtonSegment(
                          value: 1,
                          label: SizedBox(width: 80, child: Center(child: Text('Today'))),
                        ),
                        ButtonSegment(
                          value: 2,
                          label: SizedBox(width: 80, child: Center(child: Text('Tomorrow'))),
                        ),
                      ],
                      selected: {selectedDay},
                      onSelectionChanged: (newSelection) {
                        setState(() => selectedDay = newSelection.first);
                      },
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 250,
                      child: LineChart(
                        LineChartData(
                          minY: 0,
                          maxY: 12,
                          minX: 0,
                          maxX: 24,
                          extraLinesData: ExtraLinesData(
                            horizontalLines: [
                              HorizontalLine(
                                y: 3,
                                color: Colors.red.withOpacity(0.5),
                                strokeWidth: 2,
                                dashArray: [8, 4],
                                label: HorizontalLineLabel(
                                  show: true,
                                  labelResolver: (_) => 'Sunscreen line (UV 3)',
                                ),
                              ),
                            ],
                          ),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: true, reservedSize: 30, interval: 2),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 4,
                                getTitlesWidget: (value, meta) {
                                  final hour = value.toInt();
                                  if (hour < 0 || hour >= dayTimes.length) {
                                    return const Text('');
                                  }
                                  final time = dayTimes[hour];
                                  final hourLabel = time.split('T')[1].substring(0, 2);
                                  return Text(hourLabel);
                                },
                              ),
                            ),
                            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          gridData: const FlGridData(show: true),
                          borderData: FlBorderData(show: true),
                          lineBarsData: [
                            LineChartBarData(
                              spots: [
                                ...List.generate(
                                  dayUV.length,
                                  (i) => FlSpot(i.toDouble(), dayUV[i]),
                                ),
                                const FlSpot(24, 0),
                              ],
                              isCurved: true,
                              color: Colors.deepPurple,
                              barWidth: 3,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: true,
                                color: Colors.deepPurple.withOpacity(0.15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      getUVMessage(dayUV, dayTimes),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ElevatedButton(
                        onPressed: () => _showTableSheet(context, dayTimes, dayUV),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFF9C4),
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Hour-by-hour table'),
                      ),
                    ),
                  ],
                ),
                if (searchResults.isNotEmpty)
                  Positioned(
                    top: 56,
                    left: 150,
                    right: 0,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        children: searchResults.map((city) {
                          final label = city['admin1'] != null
                              ? '${city['name']}, ${city['admin1']}, ${city['country']}'
                              : '${city['name']}, ${city['country']}';
                          return ListTile(
                            title: Text(label),
                            onTap: () => _selectCity(city),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}