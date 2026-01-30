import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

enum AppMode { hunt, fish, jeep, hike, moto, bike, outdoors }

enum MarkerFrame { pin, circle, badge, flag, shield }

class MarkerVisual {
  final IconData icon;
  final Color color;
  final MarkerFrame frame;

  const MarkerVisual({
    required this.icon,
    required this.color,
    required this.frame,
  });
}

class MapPoint {
  final String id;
  final LatLng position;
  final AppMode mode;
  final String tag;

  final DateTime createdAt;
  final String comment;

  /// Persistent local path to an image file (copied into app documents folder).
  final String? photoPath;

  MapPoint({
    required this.id,
    required this.position,
    required this.mode,
    required this.tag,
    required this.createdAt,
    required this.comment,
    this.photoPath,
  });

  MapPoint copyWith({
    LatLng? position,
    AppMode? mode,
    String? tag,
    DateTime? createdAt,
    String? comment,
    String? photoPath,
  }) {
    return MapPoint(
      id: id,
      position: position ?? this.position,
      mode: mode ?? this.mode,
      tag: tag ?? this.tag,
      createdAt: createdAt ?? this.createdAt,
      comment: comment ?? this.comment,
      photoPath: photoPath ?? this.photoPath,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lng': position.longitude,
        'mode': mode.name,
        'tag': tag,
        'createdAt': createdAt.toIso8601String(),
        'comment': comment,
        'photoPath': photoPath,
      };

  static MapPoint fromJson(Map<String, dynamic> j) {
    final modeName = (j['mode'] as String?) ?? AppMode.hunt.name;
    final mode = AppMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => AppMode.hunt,
    );

    return MapPoint(
      id: (j['id'] as String?) ?? DateTime.now().microsecondsSinceEpoch.toString(),
      position: LatLng(
        (j['lat'] as num).toDouble(),
        (j['lng'] as num).toDouble(),
      ),
      mode: mode,
      tag: (j['tag'] as String?) ?? 'Заметка',
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      comment: (j['comment'] as String?) ?? '',
      photoPath: j['photoPath'] as String?,
    );
  }
}

/// Hive TypeAdapter without codegen
class MapPointAdapter extends TypeAdapter<MapPoint> {
  @override
  final int typeId = 1;

  @override
  MapPoint read(BinaryReader reader) {
    final id = reader.readString();
    final lat = reader.readDouble();
    final lng = reader.readDouble();
    final modeIndex = reader.readInt();
    final tag = reader.readString();
    final createdMillis = reader.readInt();
    final comment = reader.readString();
    final photoPath = reader.readString();

    return MapPoint(
      id: id,
      position: LatLng(lat, lng),
      mode: AppMode.values[modeIndex],
      tag: tag,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMillis),
      comment: comment,
      photoPath: photoPath.isEmpty ? null : photoPath,
    );
  }

  @override
  void write(BinaryWriter writer, MapPoint obj) {
    writer.writeString(obj.id);
    writer.writeDouble(obj.position.latitude);
    writer.writeDouble(obj.position.longitude);
    writer.writeInt(obj.mode.index);
    writer.writeString(obj.tag);
    writer.writeInt(obj.createdAt.millisecondsSinceEpoch);
    writer.writeString(obj.comment);
    writer.writeString(obj.photoPath ?? '');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive
  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(MapPointAdapter());
  }
  await Hive.openBox<MapPoint>('points');

  // Tile caching (ObjectBox backend)
  await FMTCObjectBoxBackend().initialise();
  await const FMTCStore('mainStore').manage.create();

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
  // Location
  LatLng? currentLocation;
  double currentAccuracy = 0;

  // Map
  final MapController _mapController = MapController();

  // Data
  final List<MapPoint> mapPoints = [];
  late final Box<MapPoint> _box;

  // Mode / view
  AppMode currentMode = AppMode.hunt;
  bool showAllModes = false;
  String? movingPointId;

  // Tile caching provider (construct once)
  late final FMTCTileProvider _tileProvider;

  // Photo
  final ImagePicker _picker = ImagePicker();

  // =========================================================
  //  TAG CONFIGS
  // =========================================================

  static const Map<String, MarkerVisual> universalTagConfig = {
    'опасно': MarkerVisual(
      icon: Icons.warning_amber_rounded,
      color: Colors.red,
      frame: MarkerFrame.shield,
    ),
    'заметка': MarkerVisual(
      icon: Icons.sticky_note_2_outlined,
      color: Colors.indigo,
      frame: MarkerFrame.badge,
    ),
  };

  static const Map<AppMode, Map<String, MarkerVisual>> modeTagConfig = {
    AppMode.hunt: {
      'засидка': MarkerVisual(icon: Icons.visibility, color: Colors.green, frame: MarkerFrame.circle),
      'след': MarkerVisual(icon: Icons.pets, color: Colors.green, frame: MarkerFrame.flag),
      'стоянка': MarkerVisual(icon: Icons.local_florist, color: Colors.green, frame: MarkerFrame.badge),
    },
    AppMode.fish: {
      'точка клёва': MarkerVisual(icon: Icons.phishing, color: Colors.blue, frame: MarkerFrame.pin),
      'стоянка': MarkerVisual(icon: Icons.cabin, color: Colors.blue, frame: MarkerFrame.badge),
      'прикорм': MarkerVisual(icon: Icons.set_meal, color: Colors.blue, frame: MarkerFrame.circle),
    },
    AppMode.jeep: {
      'брод': MarkerVisual(icon: Icons.waves, color: Colors.brown, frame: MarkerFrame.pin),
      'сложный участок': MarkerVisual(icon: Icons.report_problem_outlined, color: Colors.brown, frame: MarkerFrame.flag),
      'смотровая': MarkerVisual(icon: Icons.landscape, color: Colors.brown, frame: MarkerFrame.circle),
      'лагерь': MarkerVisual(icon: Icons.local_fire_department, color: Colors.brown, frame: MarkerFrame.badge),
    },
    AppMode.hike: {
      'тропа': MarkerVisual(icon: Icons.route, color: Colors.teal, frame: MarkerFrame.flag),
      'источник': MarkerVisual(icon: Icons.water_drop, color: Colors.teal, frame: MarkerFrame.circle),
      'привал': MarkerVisual(icon: Icons.chair_alt, color: Colors.teal, frame: MarkerFrame.badge),
    },
    AppMode.moto: {
      'сбор': MarkerVisual(icon: Icons.group, color: Colors.deepOrange, frame: MarkerFrame.badge),
      'крутой участок': MarkerVisual(icon: Icons.terrain, color: Colors.deepOrange, frame: MarkerFrame.flag),
      'заправка': MarkerVisual(icon: Icons.local_gas_station, color: Colors.deepOrange, frame: MarkerFrame.circle),
    },
    AppMode.bike: {
      'маршрут': MarkerVisual(icon: Icons.route, color: Colors.purple, frame: MarkerFrame.flag),
      'подъём': MarkerVisual(icon: Icons.trending_up, color: Colors.purple, frame: MarkerFrame.circle),
      'спуск': MarkerVisual(icon: Icons.trending_down, color: Colors.purple, frame: MarkerFrame.circle),
      'источник': MarkerVisual(icon: Icons.water_drop, color: Colors.purple, frame: MarkerFrame.circle),
    },
    AppMode.outdoors: {
      'пляж': MarkerVisual(icon: Icons.beach_access, color: Colors.lightGreen, frame: MarkerFrame.pin),
      'вид': MarkerVisual(icon: Icons.photo_camera_outlined, color: Colors.lightGreen, frame: MarkerFrame.circle),
      'мангальная зона': MarkerVisual(icon: Icons.outdoor_grill, color: Colors.lightGreen, frame: MarkerFrame.badge),
      'стоянка': MarkerVisual(icon: Icons.local_parking, color: Colors.lightGreen, frame: MarkerFrame.badge),
    },
  };

  static const Map<AppMode, MarkerVisual> defaultModeVisual = {
    AppMode.hunt: MarkerVisual(icon: Icons.gps_fixed, color: Colors.green, frame: MarkerFrame.pin),
    AppMode.fish: MarkerVisual(icon: Icons.water, color: Colors.blue, frame: MarkerFrame.pin),
    AppMode.jeep: MarkerVisual(icon: Icons.directions_car, color: Colors.brown, frame: MarkerFrame.pin),
    AppMode.hike: MarkerVisual(icon: Icons.directions_walk, color: Colors.teal, frame: MarkerFrame.pin),
    AppMode.moto: MarkerVisual(icon: Icons.two_wheeler, color: Colors.deepOrange, frame: MarkerFrame.pin),
    AppMode.bike: MarkerVisual(icon: Icons.directions_bike, color: Colors.purple, frame: MarkerFrame.pin),
    AppMode.outdoors: MarkerVisual(icon: Icons.park, color: Colors.lightGreen, frame: MarkerFrame.pin),
  };

  String _normTag(String tag) => tag.trim().toLowerCase();

  String _prettyTag(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    return t[0].toUpperCase() + t.substring(1);
  }

  MarkerVisual _visualForTag(AppMode mode, String tag) {
    final key = _normTag(tag);
    final u = universalTagConfig[key];
    if (u != null) return u;
    final m = modeTagConfig[mode]?[key];
    if (m != null) return m;
    return defaultModeVisual[mode] ?? const MarkerVisual(icon: Icons.place, color: Colors.green, frame: MarkerFrame.pin);
  }

  List<String> _tagsForMode(AppMode mode) {
    final modeKeys = (modeTagConfig[mode] ?? {}).keys.toList();
    final universalKeys = universalTagConfig.keys.toList();
    return [...modeKeys.map(_prettyTag), ...universalKeys.map(_prettyTag)];
  }

  // =========================================================
  //  INIT
  // =========================================================

  @override
  void initState() {
    super.initState();

    _box = Hive.box<MapPoint>('points');
    _loadPointsFromHive();

    // v10.1.1 expects store -> strategy map
    _tileProvider = FMTCTileProvider(
      stores: {'mainStore': BrowseStoreStrategy.readUpdateCreate},
    );

    _getLocation();
  }

  void _loadPointsFromHive() {
    mapPoints
      ..clear()
      ..addAll(_box.values);
    setState(() {});
  }

  Future<void> _savePointsToHive() async {
    await _box.clear();
    for (final p in mapPoints) {
      await _box.put(p.id, p);
    }
  }

  // =========================================================
  //  LOCATION
  // =========================================================

  Future<void> _getLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return;

    try {
      final position = await Geolocator.getCurrentPosition(
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
    } catch (_) {}
  }

  // =========================================================
  //  MAP HELPERS
  // =========================================================

  void _centerMapSmart(LatLng target) {
    final camera = _mapController.camera;
    final distance = const Distance().as(LengthUnit.Meter, camera.center, target);

    double zoom = camera.zoom;
    if (distance > 300) zoom = 16;

    _mapController.move(target, zoom);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _formatDateTime(DateTime dt) {
    return '${_two(dt.day)}.${_two(dt.month)}.${dt.year} ${_two(dt.hour)}:${_two(dt.minute)}';
  }

  // =========================================================
  //  MODES
  // =========================================================

  String _modeTitle(AppMode mode) {
    switch (mode) {
      case AppMode.hunt:
        return 'Охота';
      case AppMode.fish:
        return 'Рыбалка';
      case AppMode.jeep:
        return 'Джип-тур';
      case AppMode.hike:
        return 'Пешие прогулки';
      case AppMode.moto:
        return 'Мотопрохват';
      case AppMode.bike:
        return 'Велопрогулка';
      case AppMode.outdoors:
        return 'Активный отдых';
    }
  }

  IconData _modeIcon(AppMode mode) {
    switch (mode) {
      case AppMode.hunt:
        return Icons.gps_fixed;
      case AppMode.fish:
        return Icons.water;
      case AppMode.jeep:
        return Icons.directions_car;
      case AppMode.hike:
        return Icons.directions_walk;
      case AppMode.moto:
        return Icons.two_wheeler;
      case AppMode.bike:
        return Icons.directions_bike;
      case AppMode.outdoors:
        return Icons.park;
    }
  }

  void _showModeSelector() {
    if (movingPointId != null) {
      _showSnack('Сначала завершите перемещение (или отмените ✖).');
      return;
    }

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: AppMode.values.map((mode) {
              final selected = mode == currentMode;
              return ListTile(
                leading: Icon(_modeIcon(mode)),
                title: Text(_modeTitle(mode)),
                trailing: selected ? const Icon(Icons.check, color: Colors.green) : null,
                onTap: () {
                  setState(() => currentMode = mode);
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Future<AppMode?> _pickMode({required AppMode initial}) {
    return showModalBottomSheet<AppMode>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: AppMode.values.map((mode) {
              final selected = mode == initial;
              return ListTile(
                leading: Icon(_modeIcon(mode)),
                title: Text(_modeTitle(mode)),
                trailing: selected ? const Icon(Icons.check, color: Colors.green) : null,
                onTap: () => Navigator.pop(context, mode),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  // =========================================================
  //  MARKER WIDGET (shape)
  // =========================================================

  Widget _markerWidget(MarkerVisual v) {
    const double iconSize = 20;

    switch (v.frame) {
      case MarkerFrame.pin:
        return Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.location_on, color: Colors.white, size: 36),
            Icon(Icons.location_on, color: v.color, size: 32),
            Positioned(top: 9, child: Icon(v.icon, color: Colors.white, size: iconSize)),
          ],
        );

      case MarkerFrame.circle:
        return Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: v.color, width: 3),
            boxShadow: const [
              BoxShadow(blurRadius: 6, spreadRadius: 0.5, offset: Offset(0, 2), color: Colors.black26),
            ],
          ),
          child: Center(child: Icon(v.icon, color: v.color, size: 22)),
        );

      case MarkerFrame.badge:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: v.color, width: 2),
            boxShadow: const [
              BoxShadow(blurRadius: 6, spreadRadius: 0.5, offset: Offset(0, 2), color: Colors.black26),
            ],
          ),
          child: Icon(v.icon, color: v.color, size: 22),
        );

      case MarkerFrame.flag:
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: v.color, width: 2),
                boxShadow: const [
                  BoxShadow(blurRadius: 6, spreadRadius: 0.5, offset: Offset(0, 2), color: Colors.black26),
                ],
              ),
              child: Icon(v.icon, color: v.color, size: 22),
            ),
            Positioned(bottom: -2, child: Icon(Icons.arrow_drop_down, color: v.color, size: 28)),
          ],
        );

      case MarkerFrame.shield:
        return Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.shield, color: Colors.white, size: 40),
            Icon(Icons.shield, color: v.color, size: 36),
            Positioned(child: Icon(v.icon, color: Colors.white, size: 18)),
          ],
        );
    }
  }

  // =========================================================
  //  ADD / EDIT HELPERS
  // =========================================================

  Future<String?> _pickTag({
    required AppMode mode,
    String? initialTag,
    String? title,
  }) {
    final tags = _tagsForMode(mode);

    return showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(title ?? 'Выбор тега • ${_modeTitle(mode)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Выберите категорию точки'),
              ),
              const Divider(height: 1),
              ...tags.map((displayTag) {
                final v = _visualForTag(mode, displayTag);
                final isSelected = initialTag != null && _normTag(initialTag) == _normTag(displayTag);

                return ListTile(
                  leading: SizedBox(width: 44, height: 44, child: Center(child: _markerWidget(v))),
                  title: Text(displayTag),
                  trailing: isSelected ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: () => Navigator.pop(context, displayTag),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _askComment({required String tag, required String initial}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Комментарий • $tag'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Например: “есть брод”, “клёв с 6:00”, “опасные ямы”…',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Сохранить')),
          ],
        );
      },
    );
    return result;
  }

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<String> _persistImageFile(String sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${appDir.path}${Platform.pathSeparator}photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }

    final sep = Platform.pathSeparator;
    final lastSep = sourcePath.lastIndexOf(sep);
    final lastDot = sourcePath.lastIndexOf('.');
    String ext = '.jpg';
    if (lastDot > lastSep && lastDot != -1) {
      ext = sourcePath.substring(lastDot);
      if (ext.length > 8) ext = '.jpg';
    }

    final fileName = '${DateTime.now().microsecondsSinceEpoch}$ext';
    final destPath = '${photosDir.path}${Platform.pathSeparator}$fileName';

    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<ImageSource?> _choosePhotoSourceSheet() async {
    // Desktop/web: only file picker (gallery)
    if (kIsWeb || _isDesktop) {
      return ImageSource.gallery;
    }

    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Камера'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Галерея'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _pickPhoto() async {
    try {
      final source = await _choosePhotoSourceSheet();
      if (source == null) return null;

      final x = await _picker.pickImage(source: source, imageQuality: 80);
      if (x == null) return null;

      // Copy into app folder so path is stable
      final savedPath = await _persistImageFile(x.path);
      return savedPath;
    } catch (e) {
      _showSnack('Фото недоступно: $e');
      return null;
    }
  }

  Future<void> _startAddPointFlow(LatLng position) async {
    if (movingPointId != null) {
      _showSnack('Сначала завершите перемещение точки (или отмените ✖).');
      return;
    }

    final tag = await _pickTag(
      mode: currentMode,
      title: 'Добавить точку • ${_modeTitle(currentMode)}',
    );
    if (!mounted) return;
    if (tag == null) return;

    final comment = await _askComment(tag: tag, initial: '');
    if (!mounted) return;
    if (comment == null) return;

    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();

    setState(() {
      mapPoints.add(
        MapPoint(
          id: id,
          position: position,
          mode: currentMode,
          tag: tag,
          createdAt: now,
          comment: comment,
          photoPath: null,
        ),
      );
    });
    await _savePointsToHive();
  }

  // =========================================================
  //  MOVE POINT
  // =========================================================

  void _startMovePoint(MapPoint point) {
    setState(() => movingPointId = point.id);
    _showSnack('Перемещение: тапните по карте в новое место. Отмена — ✖ вверху.');
  }

  void _cancelMovePoint() {
    setState(() => movingPointId = null);
    _showSnack('Перемещение отменено.');
  }

  Future<void> _applyMoveTo(LatLng newPos) async {
    final id = movingPointId;
    if (id == null) return;

    setState(() {
      final idx = mapPoints.indexWhere((p) => p.id == id);
      if (idx != -1) {
        mapPoints[idx] = mapPoints[idx].copyWith(position: newPos);
      }
      movingPointId = null;
    });

    await _savePointsToHive();
    _showSnack('Точка перемещена.');
  }

  // =========================================================
  //  INFO / MENU / EDIT
  // =========================================================

  void _showPointInfo(MapPoint point) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_modeTitle(point.mode)} • ${point.tag}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Создана: ${_formatDateTime(point.createdAt)}'),
            const SizedBox(height: 8),
            Text('Комментарий: ${point.comment.isEmpty ? "—" : point.comment}'),
            const SizedBox(height: 8),
            Text('Широта: ${point.position.latitude}'),
            Text('Долгота: ${point.position.longitude}'),
            const SizedBox(height: 8),
            Text('Фото: ${point.photoPath == null ? "нет" : "есть"}'),
            if (point.photoPath != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(point.photoPath!),
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 160,
                    alignment: Alignment.center,
                    color: Colors.black12,
                    child: const Text('Не удалось открыть фото'),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОК')),
        ],
      ),
    );
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
                leading: const Icon(Icons.open_with),
                title: const Text('Переместить'),
                onTap: () {
                  Navigator.pop(context);
                  _startMovePoint(point);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Корректировать'),
                onTap: () {
                  Navigator.pop(context);
                  _editPointFull(point);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Удалить'),
                onTap: () async {
                  Navigator.pop(context);
                  setState(() => mapPoints.removeWhere((p) => p.id == point.id));
                  await _savePointsToHive();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editPointFull(MapPoint point) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        AppMode editMode = point.mode;
        String editTag = point.tag;
        String? editPhoto = point.photoPath;
        final commentController = TextEditingController(text: point.comment);

        Future<void> save() async {
          setState(() {
            final idx = mapPoints.indexWhere((p) => p.id == point.id);
            if (idx != -1) {
              mapPoints[idx] = mapPoints[idx].copyWith(
                mode: editMode,
                tag: editTag,
                comment: commentController.text.trim(),
                photoPath: editPhoto,
              );
            }
          });

          await _savePointsToHive();
          if (!mounted) return;
          Navigator.pop(this.context);
        }

        return StatefulBuilder(
          builder: (context, setLocal) {
            final v = _visualForTag(editMode, editTag);

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(width: 44, height: 44, child: Center(child: _markerWidget(v))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Корректировать точку', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                    ],
                  ),
                  const SizedBox(height: 12),

                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_modeIcon(editMode)),
                    title: const Text('Режим'),
                    subtitle: Text(_modeTitle(editMode)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final picked = await _pickMode(initial: editMode);
                      if (picked == null) return;
                      setLocal(() {
                        editMode = picked;
                        final available = _tagsForMode(editMode);
                        final isUniversal = universalTagConfig.containsKey(_normTag(editTag));
                        final existsInMode = (modeTagConfig[editMode] ?? {}).containsKey(_normTag(editTag));
                        if (!isUniversal && !existsInMode && available.isNotEmpty) {
                          editTag = available.first;
                        }
                      });
                    },
                  ),

                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(v.icon, color: v.color),
                    title: const Text('Тег'),
                    subtitle: Text(editTag),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final picked = await _pickTag(
                        mode: editMode,
                        initialTag: editTag,
                        title: 'Выберите тег • ${_modeTitle(editMode)}',
                      );
                      if (picked == null) return;
                      setLocal(() => editTag = picked);
                    },
                  ),

                  if (editPhoto != null && editPhoto!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(editPhoto!),
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          height: 160,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Не удалось открыть фото'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final path = await _pickPhoto();
                            if (path == null) return;
                            setLocal(() => editPhoto = path);
                          },
                          icon: Icon(_isDesktop || kIsWeb ? Icons.folder_open : Icons.photo_camera),
                          label: Text(_isDesktop || kIsWeb ? 'Файл' : 'Фото'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => setLocal(() => editPhoto = null),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Удалить'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),
                  TextField(
                    controller: commentController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Комментарий',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Отмена'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => save(),
                          child: const Text('Сохранить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // =========================================================
  //  VIEW SETTINGS
  // =========================================================

  void _showViewSettings() {
    if (movingPointId != null) {
      _showSnack('Сначала завершите перемещение (или отмените ✖).');
      return;
    }

    showModalBottomSheet(
      context: context,
      builder: (context) {
        bool localShowAll = showAllModes;

        return StatefulBuilder(
          builder: (context, setLocal) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    title: Text('Отображение точек', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('Фильтр по режимам'),
                  ),
                  SwitchListTile(
                    title: const Text('Показывать все режимы'),
                    subtitle: Text(localShowAll ? 'На карте будут точки всех режимов' : 'Только точки текущего режима'),
                    value: localShowAll,
                    onChanged: (v) => setLocal(() => localShowAll = v),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              setState(() => showAllModes = localShowAll);
                              Navigator.pop(context);
                            },
                            child: const Text('Применить'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // =========================================================
  //  IMPORT / EXPORT JSON
  // =========================================================

  String _exportJson() {
    final data = mapPoints.map((p) => p.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  Future<void> _importJson(String jsonText) async {
    final decoded = json.decode(jsonText);
    if (decoded is! List) throw Exception('JSON должен быть списком точек');

    final imported = decoded.map((e) => MapPoint.fromJson(Map<String, dynamic>.from(e as Map))).toList();

    setState(() {
      mapPoints
        ..clear()
        ..addAll(imported);
    });
    await _savePointsToHive();
  }

  Future<String?> _showJsonDialog({
    required String title,
    required String initial,
    required bool readOnly,
  }) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: c,
            readOnly: readOnly,
            maxLines: 12,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
          if (!readOnly) TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Импорт')),
        ],
      ),
    );
  }

  // =========================================================
  //  UI
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final modeTitle = _modeTitle(currentMode);
    final visiblePoints = showAllModes ? mapPoints : mapPoints.where((p) => p.mode == currentMode).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(movingPointId == null ? 'Навигатор • $modeTitle' : 'Перемещение • $modeTitle'),
        actions: [
          if (movingPointId != null)
            IconButton(
              tooltip: 'Отменить перемещение',
              onPressed: _cancelMovePoint,
              icon: const Icon(Icons.close),
            ),
          IconButton(
            tooltip: 'Отображение точек',
            onPressed: _showViewSettings,
            icon: Icon(showAllModes ? Icons.visibility : Icons.visibility_outlined),
          ),
          IconButton(
            tooltip: 'Выбрать режим',
            onPressed: _showModeSelector,
            icon: const Icon(Icons.layers_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'export') {
                final text = _exportJson();
                await _showJsonDialog(title: 'Экспорт JSON', initial: text, readOnly: true);
              } else if (v == 'import') {
                final input = await _showJsonDialog(title: 'Импорт JSON', initial: '', readOnly: false);
                if (!mounted) return;
                if (input == null) return;
                try {
                  await _importJson(input);
                  if (!mounted) return;
                  _showSnack('Импорт выполнен.');
                } catch (e) {
                  if (!mounted) return;
                  _showSnack('Ошибка импорта: $e');
                }
              } else if (v == 'clear') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Очистить все точки?'),
                    content: const Text('Удалятся все сохранённые точки.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Очистить')),
                    ],
                  ),
                );
                if (!mounted) return;
                if (ok == true) {
                  setState(() => mapPoints.clear());
                  await _savePointsToHive();
                  if (!mounted) return;
                  _showSnack('Точки удалены.');
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Экспорт JSON')),
              PopupMenuItem(value: 'import', child: Text('Импорт JSON')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'clear', child: Text('Очистить все точки')),
            ],
          ),
        ],
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: currentLocation ?? const LatLng(43.238949, 76.889709),
          initialZoom: 13,
          onTap: (tapPosition, latLng) {
            if (movingPointId != null) {
              _applyMoveTo(latLng);
            }
          },
          onLongPress: (tapPosition, latLng) => _startAddPointFlow(latLng),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.hunter_navigator',
            tileProvider: _tileProvider,
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
                  width: 44,
                  height: 44,
                  child: const Icon(Icons.my_location, color: Colors.red, size: 34),
                ),
              ...visiblePoints.map((point) {
                final v = _visualForTag(point.mode, point.tag);
                return Marker(
                  point: point.position,
                  width: 52,
                  height: 52,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showPointInfo(point),
                    onLongPress: () => _showPointMenu(point),
                    child: Center(child: _markerWidget(v)),
                  ),
                );
              }),
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
