## Builds plugins/boards/RetroValley/board.tscn from the files layout.py wrote.
##
##   DATA_DIR=<layout.py output> godot --headless --path . --script res://tools/board_builder/build_board.gd
extends SceneTree

const BOARD_DIR := "res://plugins/boards/RetroValley/"
const NATURE := "res://assets/models/nature/glTF/"
const PROPS := BOARD_DIR + "props/"

var data_dir := ""
var layout: Dictionary
var board: Node3D


func own(parent: Node, node: Node, node_name: String) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = board
	return node


func read_floats(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(f.get_length()).to_float32_array()


func build_terrain(heights: PackedFloat32Array, colors: PackedByteArray) -> ArrayMesh:
	var n: int = layout.n
	var cell: float = layout.cell
	var half: float = layout.half
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in n:
		for ix in n:
			var i := iz * n + ix
			var uv := Vector2(float(ix) / (n - 1), float(iz) / (n - 1))
			st.set_uv(uv)
			st.set_uv2(uv)     # the tiling ground detail
			st.add_vertex(Vector3(-half + ix * cell, heights[i], -half + iz * cell))
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			var b := a + 1
			var c := a + n
			var d := c + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	st.generate_normals()
	return st.commit()


var colors_texture: Texture2D
# how often the ground detail repeats over the whole board (about 2.5 m per repeat)
const DETAIL_TILES := 95.0


func terrain_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = colors_texture
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.roughness = 1.0
	m.albedo_color = Color(0.77, 0.77, 0.77)    # the toon lighting is bright, so darken the colours a little
	# a tiling grain over the colour map: blotches and tufts, so the ground is not one flat paint
	m.detail_enabled = true
	m.detail_albedo = load(BOARD_DIR + "ground_detail.png")
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	m.uv2_scale = Vector3(DETAIL_TILES, DETAIL_TILES, 1.0)
	return m


func first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var r := first_mesh(c)
		if r:
			return r
	return null


func prop_mesh(kind: String) -> Mesh:
	if kind == "SnowTree":
		return load("res://assets/models/tree/tree_snow.obj")
	var scene: PackedScene = load(NATURE + kind + ".gltf")
	if scene == null:
		push_warning("missing prop " + kind)
		return null
	var inst := scene.instantiate()
	var mi := first_mesh(inst)
	var mesh: Mesh = mi.mesh if mi else null
	inst.free()
	# the pine, palm, maple and dead trees come without textures, give them flat toon colours
	var family := kind.split("_")[0]
	if mesh and family in ["PineTree", "PalmTree", "DeadTree", "MapleTree"]:
		var colors: Array = {
			"PineTree": [Color(0.40, 0.27, 0.16), Color(0.14, 0.42, 0.22)],
			"PalmTree": [Color(0.66, 0.50, 0.30), Color(0.30, 0.66, 0.24)],
			"DeadTree": [Color(0.38, 0.32, 0.28), Color(0.38, 0.32, 0.28)],
			"MapleTree": [Color(0.42, 0.28, 0.17), Color(0.90, 0.42, 0.14)],
		}[family]
		for i in mesh.get_surface_count():
			mesh.surface_set_material(i, toon_material(colors[mini(i, 1)]))
	return mesh


func toon_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.roughness = 1.0
	return m



## Adds a box (without its bottom) to a SurfaceTool; origin is the lowest corner.
func add_box(st: SurfaceTool, origin: Vector3, size: Vector3, color: Color) -> void:
	var o := origin
	var s := size
	var p := [
		o, o + Vector3(s.x, 0, 0), o + Vector3(s.x, 0, s.z), o + Vector3(0, 0, s.z),
		o + Vector3(0, s.y, 0), o + Vector3(s.x, s.y, 0), o + Vector3(s.x, s.y, s.z), o + Vector3(0, s.y, s.z),
	]
	# faces as quads (top, front, back, left, right); Godot treats clockwise triangles as the front
	var quads := [[4, 7, 6, 5], [0, 4, 5, 1], [3, 2, 6, 7], [0, 3, 7, 4], [1, 5, 6, 2]]
	for q in quads:
		for i in [0, 2, 1, 0, 3, 2]:
			st.set_color(color)
			st.add_vertex(p[q[i]])


func _initialize() -> void:
	data_dir = OS.get_environment("DATA_DIR")
	layout = JSON.parse_string(FileAccess.get_file_as_string(data_dir.path_join("layout.json")))
	board = Node3D.new()
	board.name = "RetroValley"
	board.set_script(load(BOARD_DIR + "board.gd"))

	# terrain, saved as a separate binary resource so the scene stays small
	var heights := read_floats(data_dir.path_join("heights.bin"))
	var colors := FileAccess.get_file_as_bytes(data_dir.path_join("colors.bin"))
	var nc: int = layout.nc
	var image := Image.create_from_data(nc, nc, false, Image.FORMAT_RGB8, colors)
	image.generate_mipmaps()
	var tex := ImageTexture.create_from_image(image)
	ResourceSaver.save(tex, BOARD_DIR + "terrain_colors.res")
	colors_texture = load(BOARD_DIR + "terrain_colors.res")
	var terrain := build_terrain(heights, colors)
	terrain.surface_set_material(0, terrain_material())
	ResourceSaver.save(terrain, BOARD_DIR + "terrain.res")
	var terrain_node := MeshInstance3D.new()
	terrain_node.mesh = load(BOARD_DIR + "terrain.res")
	own(board, terrain_node, "Terrain")

	# water: the shared water material, with the texture scale matched to the bigger plane
	var plane := PlaneMesh.new()
	plane.size = Vector2(900, 900)
	var water_mat: ShaderMaterial = load("res://assets/materials/water_still.tres").duplicate()
	water_mat.shader = load("res://assets/shaders/water_foam.gdshader")
	water_mat.set_shader_parameter("texture_scale", Vector2(900, 900))
	# the depth of the water over the terrain, for the foam along the shores (0.5 + depth / 6 m, so the shore line is 0.5)
	var n_cells: int = layout.n
	var depth_bytes := PackedByteArray()
	depth_bytes.resize(n_cells * n_cells)
	for i in n_cells * n_cells:
		depth_bytes[i] = int(clampf(0.5 + (layout.water_y - heights[i]) / 6.0, 0.0, 1.0) * 255.0)
	var shore_tex := ImageTexture.create_from_image(Image.create_from_data(n_cells, n_cells, false, Image.FORMAT_R8, depth_bytes))
	ResourceSaver.save(shore_tex, BOARD_DIR + "shore_depth.res")
	water_mat.set_shader_parameter("shore_map", load(BOARD_DIR + "shore_depth.res"))
	water_mat.set_shader_parameter("shore_origin", Vector2(-layout.half, -layout.half))
	water_mat.set_shader_parameter("shore_size", 2.0 * layout.half)
	plane.material = water_mat
	var water := MeshInstance3D.new()
	water.mesh = plane
	water.position.y = layout.water_y
	own(board, water, "Water")

	# bridge over the lake
	var bridge_mesh: Mesh = load("res://assets/models/bridge/bridge_mesh.obj")
	var scenery := Node3D.new()
	own(board, scenery, "Scenery")
	var bridge := Node3D.new()
	own(scenery, bridge, "Bridge")
	var bx0: float = layout.bridge.x0
	var bx1: float = layout.bridge.x1
	var segs := int(ceil((bx1 - bx0) / 8.4))
	var seg_len := (bx1 - bx0) / segs
	for i in segs:
		var piece := MeshInstance3D.new()
		piece.mesh = bridge_mesh
		piece.material_override = toon_material(Color(0.62, 0.42, 0.24))
		piece.position = Vector3(bx0 + seg_len * (i + 0.5), layout.bridge.y, layout.bridge.z)
		piece.rotation_degrees.y = 90
		piece.scale = Vector3(1.4, 1.0, seg_len / 8.64)
		own(bridge, piece, "Piece%d" % i)
	# The planks of the bridge model undulate, so a flat deck of planks goes on top of them. The spaces stand on it.
	var deck := SurfaceTool.new()
	deck.begin(Mesh.PRIMITIVE_TRIANGLES)
	var plank_x := bx0
	var plank_no := 0
	while plank_x < bx1 - 0.05:
		var plank_len := minf(0.55, bx1 - plank_x)
		var shade := 0.0 if plank_no % 2 == 0 else 0.07
		add_box(deck, Vector3(plank_x, layout.bridge.y - 0.1, layout.bridge.z - 1.45), Vector3(plank_len, 0.1, 2.9),
				Color(0.70 - shade, 0.50 - shade, 0.30 - shade))
		plank_x += 0.61
		plank_no += 1
	deck.generate_normals()
	var deck_mat := toon_material(Color.WHITE)
	deck_mat.vertex_color_use_as_albedo = true
	var deck_mesh := deck.commit()
	deck_mesh.surface_set_material(0, deck_mat)
	var deck_node := MeshInstance3D.new()
	deck_node.mesh = deck_mesh
	own(bridge, deck_node, "Deck")

	# scatter: one MultiMesh per kind of prop
	DirAccess.make_dir_recursive_absolute(BOARD_DIR + "meshes")
	var scatter_root := Node3D.new()
	own(scenery, scatter_root, "Scatter")
	var kinds: Array = layout.scatter.keys()
	kinds.sort()
	var instances := 0
	for kind in kinds:
		var mesh := prop_mesh(kind)
		if mesh == null:
			continue
		# keep each mesh in its own small file, so board.tscn only references it
		var mesh_path: String = BOARD_DIR + "meshes/" + str(kind) + ".res"
		ResourceSaver.save(mesh, mesh_path)
		mesh = load(mesh_path)
		var items: Array = layout.scatter[kind]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = items.size()
		var base_scale := 0.75 if kind == "SnowTree" else 1.0
		for i in items.size():
			var it: Array = items[i]
			var basis := Basis(Vector3.UP, deg_to_rad(it[3])) * Basis.from_scale(Vector3.ONE * it[4] * base_scale)
			mm.set_instance_transform(i, Transform3D(basis, Vector3(it[0], it[1], it[2])))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		own(scatter_root, mmi, kind)
		instances += items.size()

	# landmarks: instanced scenes from props/<kind>.glb (skipped while they do not exist yet)
	var landmark_root := Node3D.new()
	own(scenery, landmark_root, "Landmarks")
	var counter := {}
	for lm in layout.landmarks:
		var path: String = PROPS + str(lm.kind) + ".glb"
		var scene: PackedScene
		if lm.kind == "BoatProp":
			scene = load("res://assets/models/boat/boat.glb")
		elif ResourceLoader.exists(path):
			scene = load(path)
		if scene == null:
			continue
		var inst := scene.instantiate()
		counter[lm.kind] = int(counter.get(lm.kind, 0)) + 1
		inst.position = Vector3(lm.pos[0], lm.pos[1], lm.pos[2])
		inst.rotation_degrees.y = lm.rot
		inst.scale = Vector3.ONE * lm.scale
		own(landmark_root, inst, "%s%d" % [lm.kind, counter[lm.kind]])

	# spaces
	var controller: Node3D = load("res://common/scenes/board_logic/controller/controller.tscn").instantiate()
	own(board, controller, "Controller")
	controller.set("COOKIES_FOR_CAKE", 20)
	controller.set("MAX_TURNS", 6)
	controller.set("show_linking_type", 3)
	controller.set("start_node", NodePath("../Nodes/" + str(layout.start)))
	for i in 4:
		own(board, load("res://common/scenes/board_logic/player_board/player_board.tscn").instantiate(), "Player%d" % (i + 1))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	own(board, sun, "DirectionalLight3D")

	var nodes_root := Node3D.new()
	own(board, nodes_root, "Nodes")
	var space_scene: PackedScene = load("res://common/scenes/board_logic/node/node.tscn")
	for nd in layout.nodes:
		var space: Node3D = space_scene.instantiate()
		space.position = Vector3(nd.pos[0], nd.pos[1], nd.pos[2])
		if nd.has("normal"):
			space.basis = Basis(Quaternion(Vector3.UP, Vector3(nd.normal[0], nd.normal[1], nd.normal[2])))
		own(nodes_root, space, nd.name)
		space.set("type", int(nd.type))
		space.set("_visible", not nd.hidden)
		space.set("potential_cake", nd.cake)
		var next_paths: Array[NodePath] = []
		for nx in nd.next:
			next_paths.append(NodePath("../" + nx))
		var prev_paths: Array[NodePath] = []
		for pv in nd.prev:
			prev_paths.append(NodePath("../" + pv))
		space.set("next", next_paths)
		space.set("prev", prev_paths)

	var music := AudioStreamPlayer.new()
	music.process_mode = Node.PROCESS_MODE_ALWAYS
	music.stream = load("res://assets/music/retro/valley_stroll.ogg")
	music.autoplay = true
	own(board, music, "AudioStreamPlayer")
	own(board, load("res://common/scenes/speech_dialog/speech_dialog.tscn").instantiate(), "SpeechDialog")

	var warps := {}
	for pair in layout.warps:
		warps[pair[0]] = pair[1]
		warps[pair[1]] = pair[0]
	board.set("warps", warps)
	controller.connect("trigger_event", Callable(board, "handle_event"), CONNECT_PERSIST)

	var packed := PackedScene.new()
	var err := packed.pack(board)
	assert(err == OK, "pack failed")
	err = ResourceSaver.save(packed, BOARD_DIR + "board.tscn")
	print("BUILT ", error_string(err), " spaces=", layout.nodes.size(), " scatter=", instances, " landmarks=", layout.landmarks.size())
	quit()
