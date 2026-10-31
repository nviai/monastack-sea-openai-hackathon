import 'dart:ui';

/// Bundled copy of `data/seed/nviai/map.v2.json`.
const mapAsset = 'assets/map.v2.json';

/// A world cell. Coordinates are grid cells, not pixels.
typedef CellPos = ({int x, int y});

/// Presentation view of the versioned map document. Geometry rules
/// (walkability, validation, room lookup) live in the Rust core; this model
/// only carries what the renderer needs.
class OfficeMap {
  OfficeMap._({
    required this.width,
    required this.height,
    required this.spawn,
    required this.tileWidth,
    required this.tileHeight,
    required this.wallHeight,
    required this.lowWallHeight,
    required this.corridorFloor,
    required this.rooms,
    required this.props,
    required this.desks,
  });

  factory OfficeMap.fromJson(Map<String, dynamic> json) {
    final tile = (json['tile'] as Map?)?.cast<String, dynamic>() ?? const {};
    final corridor =
        (json['corridor'] as Map?)?.cast<String, dynamic>() ?? const {};
    final spawn = (json['spawn'] as List).cast<int>();
    return OfficeMap._(
      width: json['width'] as int,
      height: json['height'] as int,
      spawn: (x: spawn[0], y: spawn[1]),
      tileWidth: (tile['width'] as num?)?.toDouble() ?? 64,
      tileHeight: (tile['height'] as num?)?.toDouble() ?? 32,
      wallHeight: (tile['wall_height'] as num?)?.toDouble() ?? 44,
      lowWallHeight: (tile['low_wall_height'] as num?)?.toDouble() ?? 12,
      corridorFloor: parseColor(corridor['floor'], const Color(0xffdfe3d8)),
      rooms: [
        for (final r in json['rooms'] as List)
          MapRoom.fromJson((r as Map).cast<String, dynamic>()),
      ],
      props: [
        for (final p in json['props'] as List? ?? const [])
          MapProp.fromJson((p as Map).cast<String, dynamic>()),
      ],
      desks: [
        for (final d in json['desks'] as List? ?? const [])
          MapDesk.fromJson((d as Map).cast<String, dynamic>()),
      ],
    );
  }

  final int width;
  final int height;
  final CellPos spawn;
  final double tileWidth;
  final double tileHeight;
  final double wallHeight;
  final double lowWallHeight;
  final Color corridorFloor;
  final List<MapRoom> rooms;
  final List<MapProp> props;
  final List<MapDesk> desks;

  MapRoom? roomById(String id) {
    for (final room in rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  MapRoom? roomContaining(int x, int y) {
    for (final room in rooms) {
      if (room.contains(x, y)) return room;
    }
    return null;
  }
}

class MapRoom {
  MapRoom({
    required this.id,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.doors,
    required this.spawn,
    required this.floor,
    required this.accent,
    required this.pattern,
  });

  factory MapRoom.fromJson(Map<String, dynamic> json) {
    final b = (json['bounds'] as List).cast<int>();
    final style = (json['style'] as Map?)?.cast<String, dynamic>() ?? const {};
    final spawn = (json['spawn'] as List).cast<int>();
    return MapRoom(
      id: json['id'] as String,
      x0: b[0],
      y0: b[1],
      x1: b[2],
      y1: b[3],
      doors: {
        for (final d in json['doors'] as List)
          (x: (d as List)[0] as int, y: d[1] as int),
      },
      spawn: (x: spawn[0], y: spawn[1]),
      floor: parseColor(style['floor'], const Color(0xfff5e9d9)),
      accent: parseColor(style['accent'], const Color(0xff4c7468)),
      pattern: style['pattern'] as String? ?? 'wood',
    );
  }

  final String id;
  final int x0, y0, x1, y1;
  final Set<CellPos> doors;
  final CellPos spawn;
  final Color floor;
  final Color accent;
  final String pattern;

  bool contains(int x, int y) => x >= x0 && x <= x1 && y >= y0 && y <= y1;
  bool perimeter(int x, int y) =>
      contains(x, y) && (x == x0 || x == x1 || y == y0 || y == y1);
  bool isDoor(int x, int y) => doors.contains((x: x, y: y));
  bool isWall(int x, int y) => perimeter(x, y) && !isDoor(x, y);

  /// Walls on the far edges are drawn full height; near edges are cut away
  /// so the interior stays visible.
  bool isBackEdge(int x, int y) => x == x0 || y == y0;
}

class MapProp {
  MapProp({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.solid,
    required this.wallMounted,
    required this.facing,
    this.text,
  });

  factory MapProp.fromJson(Map<String, dynamic> json) {
    final p = (json['position'] as List).cast<int>();
    final f = (json['footprint'] as List).cast<int>();
    return MapProp(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'unknown',
      x: p[0],
      y: p[1],
      w: f[0],
      h: f[1],
      solid: json['collision'] == true,
      wallMounted: json['mount'] == 'wall',
      facing: json['facing'] as String? ?? 's',
      text: json['text'] as String?,
    );
  }

  final String id;
  final String type;
  final int x, y, w, h;
  final bool solid;
  final bool wallMounted;
  final String facing;
  final String? text;

  /// Depth key of the footprint centre, used for painter's ordering.
  double get depth => x + (w - 1) / 2 + y + (h - 1) / 2;
}

class MapDesk {
  MapDesk({
    required this.id,
    required this.room,
    required this.prop,
    required this.seat,
    required this.assignee,
  });

  factory MapDesk.fromJson(Map<String, dynamic> json) {
    final seat = (json['seat'] as List).cast<int>();
    return MapDesk(
      id: json['id'] as String,
      room: json['room'] as String,
      prop: json['prop'] as String,
      seat: (x: seat[0], y: seat[1]),
      assignee: json['assignee'] as String?,
    );
  }

  final String id;
  final String room;
  final String prop;
  final CellPos seat;
  final String? assignee;
}

Color parseColor(Object? value, Color fallback) {
  if (value is! String) return fallback;
  final hex = value.startsWith('#') ? value.substring(1) : value;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null || hex.length != 6) return fallback;
  return Color(0xff000000 | parsed);
}
