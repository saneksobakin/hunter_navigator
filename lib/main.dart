import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum PointType {
	hunt,
	track,
	animal,
	note,
}

class MapPoint {
	final LatLng position;
	final PointType type;

	MapPoint({
		required this.position,
		required this.type,
	});
}

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
	double currentAccuracy = 0;

	final List<MapPoint> huntPoints = [];

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

	void _showPointMenu(MapPoint point) {
		showModalBottomSheet(
			context: context,
			builder: (context) {
				return SafeArea(
					child: Column(
						mainAxisSize: MainAxisSize.min,
						children: [
							ListTile(
								leading: const Icon(Icons.navigation),
								title: const Text('Следовать'),
								onTap: () {
									Navigator.pop(context);
									_centerMapSmart(point.position);
								},
							),
							ListTile(
								leading: const Icon(Icons.info_outline),
								title: const Text('Информация'),
								onTap: () {
									Navigator.pop(context);
									_showPointInfo(point);
								},
							),
							ListTile(
								leading: const Icon(Icons.edit),
								title: const Text('Корректировать'),
								onTap: () {
									Navigator.pop(context);
									_editPoint(point);
								},
							),
							ListTile(
								leading: const Icon(Icons.delete, color: Colors.red),
								title: const Text('Удалить'),
								onTap: () {
									Navigator.pop(context);
									_deletePoint(point);
								},
							),
						],
					),
				);
			},
		);
	}

	void _showPointInfo(MapPoint point) {
		showDialog(
			context: context,
			builder: (context) => AlertDialog(
				title: const Text('Информация о точке'),
				content: Text(
					'Тип: ${point.type}\n'
					'Широта: ${point.position.latitude}\n'
					'Долгота: ${point.position.longitude}',
				),
				actions: [
					TextButton(
						onPressed: () => Navigator.pop(context),
						child: const Text('ОК'),
					),
				],
			),
		);
	}

	void _editPoint(MapPoint point) {
		ScaffoldMessenger.of(context).showSnackBar(
			const SnackBar(content: Text('Редактирование — в разработке')),
		);
	}

	void _deletePoint(MapPoint point) {
		setState(() {
			huntPoints.remove(point);
		});
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
			currentAccuracy = position.accuracy;
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
					:FlutterMap(
						mapController: _mapController,
						options: MapOptions(
							initialCenter: currentLocation ?? const LatLng(43.238949, 76.889709),
							initialZoom: 13,
							onTap: (tapPosition, latLng) {
								setState(() {
									huntPoints.add(
										MapPoint(
											position: latLng,
											type: PointType.hunt,
										),
									);
								});
							},
						),
						children: [
							TileLayer(
								urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
								userAgentPackageName: 'com.example.hunter_navigator',
							),

							if (currentLocation != null)
								CircleLayer(
									circles: [
										CircleMarker(
											point: currentLocation!,
											radius: currentAccuracy,
											useRadiusInMeter: true,
											color: Colors.blue.withValues(alpha: 0.2),
											borderColor: Colors.blue,
											borderStrokeWidth: 2,
										),
									],
								),

							MarkerLayer(
								markers: [
									if (currentLocation != null)
										Marker(
											point: currentLocation!,
											width: 40,
											height: 40,
											child: const Icon(Icons.my_location, color: Colors.red),
										),

									...huntPoints.map(
										(point) => Marker(
											point: point.position,
											width: 40,
											height: 40,
											child: GestureDetector(
												onTap: () => _showPointMenu(point),
												child: const Icon(Icons.place, color: Colors.green),
											),
										),
									),
								],
							),
						],
					),
			floatingActionButton: FloatingActionButton(
				onPressed: () {
					if (currentLocation != null) {
						_centerMapSmart(currentLocation!);
					} else {
						_getLocation();
					}
				},
				tooltip: 'Моё местоположение',
				child: const Icon(Icons.my_location),
			),
		);
	}
}