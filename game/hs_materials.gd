extends RefCounted

## What a map's surfaces are made of: a wood floor, a tiled corridor, a carpet, a painted
## wall, brick, grass, asphalt, glass. Generated here, once per process, as small tiling
## textures; never a file.
##
## [b]Generated, not vendored, and the reason is the delivered pack.[/b] A texture a game
## ships is a file inside a mount whose path the imported material recorded at the AUTHORED
## location, which is the family's delivery bug in its sixth form; a texture made in code has
## no path to be wrong. They are also tiny: twenty-odd 128-pixel images, generated in about a
## third of a second on a client and never on a server, which draws nothing.
##
## [b]Mapped in world space (triplanar), so a box needs no UVs.[/b] A map is hundreds of boxes
## of every size, and per-box UVs would stretch a plank across a two-metre wall and a
## twenty-metre one alike. In world space a plank is the same width on every wall, which is
## what makes a room read as a room rather than as a box with a picture on it.
##
## [b]A surface has a tint.[/b] A map document names a surface and may tint it, so one carpet
## is a blue classroom and a red library without a second texture.

const SIZE := 128

## id -> `{pattern, colours, metres, roughness, alpha, metallic}`. `metres` is how much world
## one tile of the texture covers.
const SURFACES := {
	"wood_floor": {"pattern": "planks", "a": Color(0.62, 0.43, 0.26), "b": Color(0.47, 0.31, 0.18), "metres": 2.0, "rough": 0.7},
	"parquet": {"pattern": "parquet", "a": Color(0.66, 0.48, 0.30), "b": Color(0.52, 0.36, 0.21), "metres": 1.2, "rough": 0.6},
	"gym": {"pattern": "planks", "a": Color(0.86, 0.69, 0.45), "b": Color(0.76, 0.58, 0.36), "metres": 2.4, "rough": 0.45},
	"tile": {"pattern": "tiles", "a": Color(0.88, 0.87, 0.82), "b": Color(0.62, 0.62, 0.60), "metres": 1.2, "rough": 0.35, "n": 2},
	"tile_check": {"pattern": "checker", "a": Color(0.90, 0.89, 0.84), "b": Color(0.32, 0.46, 0.52), "metres": 1.2, "rough": 0.35},
	"tile_small": {"pattern": "tiles", "a": Color(0.93, 0.94, 0.95), "b": Color(0.70, 0.72, 0.74), "metres": 0.8, "rough": 0.3, "n": 4},
	"carpet": {"pattern": "speckle", "a": Color(0.36, 0.42, 0.55), "b": Color(0.28, 0.33, 0.45), "metres": 1.5, "rough": 0.95},
	"paint": {"pattern": "plaster", "a": Color(0.92, 0.91, 0.88), "b": Color(0.86, 0.85, 0.82), "metres": 3.0, "rough": 0.9},
	"plaster": {"pattern": "plaster", "a": Color(0.95, 0.94, 0.92), "b": Color(0.90, 0.89, 0.87), "metres": 3.0, "rough": 0.9},
	"ceiling": {"pattern": "grid", "a": Color(0.95, 0.95, 0.93), "b": Color(0.78, 0.78, 0.76), "metres": 1.2, "rough": 0.9},
	"brick": {"pattern": "bricks", "a": Color(0.62, 0.30, 0.22), "b": Color(0.80, 0.76, 0.70), "metres": 1.6, "rough": 0.85},
	"stone": {"pattern": "stones", "a": Color(0.60, 0.59, 0.56), "b": Color(0.42, 0.41, 0.40), "metres": 2.0, "rough": 0.85},
	"concrete": {"pattern": "speckle", "a": Color(0.66, 0.66, 0.64), "b": Color(0.56, 0.56, 0.55), "metres": 3.0, "rough": 0.9},
	"sidewalk": {"pattern": "slabs", "a": Color(0.62, 0.61, 0.58), "b": Color(0.48, 0.48, 0.46), "metres": 2.0, "rough": 0.9},
	"asphalt": {"pattern": "speckle", "a": Color(0.20, 0.21, 0.22), "b": Color(0.28, 0.28, 0.29), "metres": 3.0, "rough": 0.95},
	"grass": {"pattern": "grass", "a": Color(0.25, 0.42, 0.16), "b": Color(0.19, 0.33, 0.12), "metres": 2.5, "rough": 1.0},
	"dirt": {"pattern": "speckle", "a": Color(0.47, 0.36, 0.24), "b": Color(0.38, 0.28, 0.18), "metres": 2.5, "rough": 1.0},
	"sand": {"pattern": "speckle", "a": Color(0.86, 0.78, 0.58), "b": Color(0.78, 0.70, 0.50), "metres": 2.0, "rough": 1.0},
	"rubber": {"pattern": "speckle", "a": Color(0.46, 0.20, 0.17), "b": Color(0.38, 0.15, 0.12), "metres": 1.5, "rough": 0.95},
	"roof": {"pattern": "shingles", "a": Color(0.30, 0.28, 0.30), "b": Color(0.20, 0.19, 0.21), "metres": 2.0, "rough": 0.9},
	"wood": {"pattern": "grain", "a": Color(0.58, 0.40, 0.24), "b": Color(0.46, 0.31, 0.18), "metres": 1.5, "rough": 0.6},
	"metal": {"pattern": "brushed", "a": Color(0.70, 0.72, 0.74), "b": Color(0.60, 0.62, 0.65), "metres": 1.0, "rough": 0.35, "metallic": 0.6},
	"locker": {"pattern": "lockers", "a": Color(0.25, 0.45, 0.68), "b": Color(0.14, 0.26, 0.42), "metres": 1.2, "rough": 0.4, "metallic": 0.4},
	"chalkboard": {"pattern": "speckle", "a": Color(0.16, 0.27, 0.21), "b": Color(0.20, 0.31, 0.25), "metres": 2.0, "rough": 0.9},
	"whiteboard": {"pattern": "flat", "a": Color(0.96, 0.97, 0.98), "b": Color(0.96, 0.97, 0.98), "metres": 2.0, "rough": 0.15},
	"glass": {"pattern": "flat", "a": Color(0.72, 0.86, 0.95), "b": Color(0.72, 0.86, 0.95), "metres": 2.0, "rough": 0.05, "alpha": 0.22},
	"water": {"pattern": "speckle", "a": Color(0.20, 0.55, 0.78), "b": Color(0.26, 0.62, 0.85), "metres": 3.0, "rough": 0.1, "alpha": 0.6},
	"line": {"pattern": "flat", "a": Color(0.95, 0.95, 0.92), "b": Color(0.95, 0.95, 0.92), "metres": 1.0, "rough": 0.8},
	"hedge": {"pattern": "grass", "a": Color(0.20, 0.42, 0.16), "b": Color(0.15, 0.33, 0.12), "metres": 1.2, "rough": 1.0},
	"fabric": {"pattern": "speckle", "a": Color(0.70, 0.20, 0.20), "b": Color(0.60, 0.15, 0.15), "metres": 1.0, "rough": 0.95},
	"flat": {"pattern": "flat", "a": Color(0.8, 0.8, 0.8), "b": Color(0.8, 0.8, 0.8), "metres": 2.0, "rough": 0.8},
}

static var _textures: Dictionary = {}
static var _materials: Dictionary = {}


static func ids() -> Array:
	return SURFACES.keys()


static func has(id: String) -> bool:
	return SURFACES.has(id)


## Whether [param id] is drawn see-through. A see-through surface is still solid unless the
## map says otherwise; glass stops a player and does not stop a look.
static func is_transparent(id: String) -> bool:
	return float((SURFACES.get(id, {}) as Dictionary).get("alpha", 1.0)) < 1.0


## The material for [param id], tinted. Cached per (surface, tint).
static func material(id: String, tint: Color = Color.WHITE) -> StandardMaterial3D:
	if not SURFACES.has(id):
		id = "flat"

	var key := "%s|%s" % [id, tint.to_html()]

	if _materials.has(key):
		return _materials[key]

	var spec: Dictionary = SURFACES[id]
	var m := StandardMaterial3D.new()
	var alpha := float(spec.get("alpha", 1.0))
	m.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	m.roughness = float(spec.get("rough", 0.8))
	m.metallic = float(spec.get("metallic", 0.0))

	if str(spec["pattern"]) != "flat":
		m.albedo_texture = texture(id)
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE / maxf(float(spec.get("metres", 2.0)), 0.1)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	else:
		m.albedo_color = Color(
			(spec["a"] as Color).r * tint.r, (spec["a"] as Color).g * tint.g, (spec["a"] as Color).b * tint.b, alpha)

	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX

	_materials[key] = m
	return m


## The tiling texture for [param id].
static func texture(id: String) -> ImageTexture:
	if _textures.has(id):
		return _textures[id]

	var spec: Dictionary = SURFACES.get(id, SURFACES["flat"])
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = hash(id)
	noise.frequency = 0.08
	var a: Color = spec["a"]
	var b: Color = spec["b"]

	match str(spec["pattern"]):
		"planks":
			_planks(image, a, b, noise, 8)
		"parquet":
			_parquet(image, a, b, noise)
		"tiles":
			_tiles(image, a, b, noise, int(spec.get("n", 2)))
		"checker":
			_checker(image, a, b, noise)
		"grid":
			_tiles(image, a, b, noise, 2, 1)
		"bricks":
			_bricks(image, a, b, noise)
		"stones":
			_stones(image, a, b, noise)
		"slabs":
			_tiles(image, a, b, noise, 2, 2)
		"shingles":
			_shingles(image, a, b, noise)
		"grain":
			_grain(image, a, b, noise)
		"brushed":
			_brushed(image, a, b, noise)
		"lockers":
			_lockers(image, a, b, noise)
		"grass":
			_grass(image, a, b, noise)
		"plaster":
			_speckle(image, a, b, noise, 0.5)
		_:
			_speckle(image, a, b, noise, 1.0)

	image.generate_mipmaps()
	var made := ImageTexture.create_from_image(image)
	_textures[id] = made
	return made


static func _n(noise: FastNoiseLite, x: float, y: float) -> float:
	# Tiling noise: the same field sampled on a torus, so the edges meet.
	var u := x / float(SIZE) * TAU
	var v := y / float(SIZE) * TAU
	return noise.get_noise_3d(cos(u) * 8.0, sin(u) * 8.0 + cos(v) * 8.0, sin(v) * 8.0)


static func _speckle(image: Image, a: Color, b: Color, noise: FastNoiseLite, amount: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	for y in range(SIZE):
		for x in range(SIZE):
			var t := clampf(0.5 + _n(noise, x, y) * 0.8 * amount + rng.randf_range(-0.15, 0.15) * amount, 0.0, 1.0)
			image.set_pixel(x, y, a.lerp(b, t))


static func _planks(image: Image, a: Color, b: Color, noise: FastNoiseLite, rows: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	var height := SIZE / rows
	var offsets: Array[int] = []
	var shades: Array[float] = []
	for r in range(rows):
		offsets.append(rng.randi_range(0, SIZE - 1))
		shades.append(rng.randf_range(-0.25, 0.25))
	for y in range(SIZE):
		var row := y / height
		for x in range(SIZE):
			var along := float((x + offsets[row]) % SIZE)
			var grain := sin(along * 0.18 + _n(noise, x, y) * 6.0) * 0.18
			var t := clampf(0.45 + shades[row] + grain, 0.0, 1.0)
			var c := a.lerp(b, t)
			if y % height == 0 or int(along) % (SIZE / 2) == 0:
				c = c.darkened(0.35)
			image.set_pixel(x, y, c)


static func _parquet(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var cell := SIZE / 4
	for y in range(SIZE):
		for x in range(SIZE):
			var cx := x / cell
			var cy := y / cell
			var flip := (cx + cy) % 2 == 0
			var local := (x % cell) if flip else (y % cell)
			var strip := local / (cell / 4)
			var t := clampf(0.4 + (0.25 if strip % 2 == 0 else -0.1) + _n(noise, x, y) * 0.3, 0.0, 1.0)
			var c := a.lerp(b, t)
			if x % cell == 0 or y % cell == 0 or local % (cell / 4) == 0:
				c = c.darkened(0.3)
			image.set_pixel(x, y, c)


static func _tiles(image: Image, a: Color, b: Color, noise: FastNoiseLite, n: int, grout: int = 2) -> void:
	var cell := SIZE / n
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	var shades := []
	for i in range(n * n):
		shades.append(rng.randf_range(-0.04, 0.04))
	for y in range(SIZE):
		for x in range(SIZE):
			var c := a
			if x % cell < grout or y % cell < grout:
				c = b
			else:
				var s: float = shades[(y / cell) * n + (x / cell)]
				c = a.lightened(s) if s > 0.0 else a.darkened(-s)
				c = c.darkened(maxf(_n(noise, x, y), 0.0) * 0.06)
			image.set_pixel(x, y, c)


static func _checker(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var cell := SIZE / 2
	for y in range(SIZE):
		for x in range(SIZE):
			var c := a if ((x / cell) + (y / cell)) % 2 == 0 else b
			c = c.darkened(maxf(_n(noise, x, y), 0.0) * 0.05)
			if x % cell == 0 or y % cell == 0:
				c = c.darkened(0.2)
			image.set_pixel(x, y, c)


static func _bricks(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var rows := 8
	var height := SIZE / rows
	var width := SIZE / 4
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	var shades := []
	for i in range(rows * 5):
		shades.append(rng.randf_range(-0.12, 0.12))
	for y in range(SIZE):
		var row := y / height
		var shift := (width / 2) if row % 2 == 1 else 0
		for x in range(SIZE):
			var xs := (x + shift) % SIZE
			var c := b
			if y % height >= 2 and xs % width >= 2:
				var s: float = shades[row * 5 + xs / width]
				c = a.lightened(s) if s > 0.0 else a.darkened(-s)
				c = c.darkened(maxf(_n(noise, x, y), 0.0) * 0.18)
			image.set_pixel(x, y, c)


static func _stones(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var cells := Voronoi.new(noise.seed, 14)
	for y in range(SIZE):
		for x in range(SIZE):
			var near := cells._near(x, y)
			var d := float(near[1]) - float(near[0])
			var c := a.lerp(b, clampf(0.4 + _n(noise, x, y) * 0.5 + cells.shades[int(near[2])], 0.0, 1.0))
			if d < 1.6:
				c = b.darkened(0.3)
			image.set_pixel(x, y, c)


static func _shingles(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var rows := 8
	var height := SIZE / rows
	for y in range(SIZE):
		var row := y / height
		var shift := (SIZE / 16) if row % 2 == 1 else 0
		for x in range(SIZE):
			var t := float(y % height) / float(height)
			var c := a.lerp(b, t * 0.8 + _n(noise, x, y) * 0.2)
			if (x + shift) % (SIZE / 8) == 0:
				c = b.darkened(0.25)
			image.set_pixel(x, y, c)


static func _grain(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	for y in range(SIZE):
		for x in range(SIZE):
			var t := clampf(0.5 + sin(float(y) * 0.35 + _n(noise, x, y) * 8.0) * 0.35, 0.0, 1.0)
			image.set_pixel(x, y, a.lerp(b, t))


static func _brushed(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	var rows := []
	for y in range(SIZE):
		rows.append(rng.randf_range(0.0, 1.0))
	for y in range(SIZE):
		for x in range(SIZE):
			image.set_pixel(x, y, a.lerp(b, clampf(float(rows[y]) * 0.7 + _n(noise, x, y) * 0.3, 0.0, 1.0)))


static func _lockers(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var door := SIZE / 2
	for y in range(SIZE):
		for x in range(SIZE):
			var c := a.darkened(maxf(_n(noise, x, y), 0.0) * 0.1)
			var lx := x % door
			if lx < 2 or y < 2:
				c = b
			# Vents near the top, a handle half way down.
			elif y > 10 and y < 26 and lx > 12 and lx < door - 12 and y % 4 < 2:
				c = b.lightened(0.1)
			elif lx > door - 12 and lx < door - 7 and y > 58 and y < 72:
				c = Color(0.82, 0.82, 0.84)
			image.set_pixel(x, y, c)


static func _grass(image: Image, a: Color, b: Color, noise: FastNoiseLite) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = noise.seed
	for y in range(SIZE):
		for x in range(SIZE):
			var t := clampf(0.5 + _n(noise, x, y) * 0.9, 0.0, 1.0)
			var c := a.lerp(b, t)
			if rng.randf() < 0.12:
				c = c.lightened(rng.randf_range(0.05, 0.18))
			image.set_pixel(x, y, c)


## A few points on a torus, for stones: how far a pixel is from the nearest edge between two
## cells, and a shade per cell.
class Voronoi:
	extends RefCounted
	var points: Array[Vector2] = []
	var shades: Array[float] = []

	func _init(seed_value: int, count: int) -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		for i in range(count):
			points.append(Vector2(rng.randf() * SIZE, rng.randf() * SIZE))
			shades.append(rng.randf_range(-0.2, 0.2))

	func _near(x: int, y: int) -> Array:
		var best := INF
		var second := INF
		var which := 0
		for i in range(points.size()):
			var d := INF
			for ox in [-SIZE, 0, SIZE]:
				for oy in [-SIZE, 0, SIZE]:
					d = minf(d, Vector2(x, y).distance_to(points[i] + Vector2(ox, oy)))
			if d < best:
				second = best
				best = d
				which = i
			elif d < second:
				second = d
		return [best, second, which]

