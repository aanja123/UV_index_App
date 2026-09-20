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
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    matchDateTimeComponents: DateTimeComponents.time,
  );
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

  @override
  void initState() {
    super.initState();
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

    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
      loadingLocation = false;
    });

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
      searchResults = [];
      searchController.clear();
    });
    _loadUVData();
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