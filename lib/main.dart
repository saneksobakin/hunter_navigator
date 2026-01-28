import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const MyApp());
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? currentLocation;

  final MapController _mapController = MapController();

  void _centerMapSmart(LatLng target) {
    final camera = _mapController.camera;

    final distance = const Distance().as(
      LengthUnit.Meter,
      camera.center,
      target,
    );

    double zoom = camera.zoom;

    // если далеко — приближаем
    if (distance > 300) {
      zoom = 16;
    }

    _mapController.move(target, zoom);
  }

  @override
  void initState() {
    super.initState();
    _getLocation();
  }

  Future<void> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        timeLimit: Duration(seconds: 10),
      ),
    );

    final newLocation = LatLng(position.latitude, position.longitude);

    setState(() {
      currentLocation = newLocation;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerMapSmart(newLocation);
  });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Навигатор охотника'),
      ),
      body: currentLocation == null
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentLocation!,
                initialZoom: 15,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.hunter_navigator',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentLocation!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.red,
                        size: 30,
                      ),
                    ),
                  ],
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _getLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}