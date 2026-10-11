extends Node3D

const SPEED = 2

enum Kind { NORMAL, FAST, TANK, BOSS }

var finished := false
var kind: int = Kind.NORMAL
var hp := 1
var speed := float(SPEED)
var hit_cooldown := 0.0
var dead := false
var base_scale := Vector3.ONE

func _ready():
	$AnimationPlayer.play(&"Idle")
	var tint := Color.WHITE
	match kind:
		Kind.FAST:
			speed = 3.6
			tint = Color(1.0, 0.45, 0.4)
			base_scale = Vector3.ONE * 0.8
		Kind.TANK:
			speed = 1.4
			hp = 2
			tint = Color(0.6, 0.9, 1.0)
			base_scale = Vector3.ONE * 1.4
		Kind.BOSS:
			speed = 0.9
			hp = 4
			tint = Color(0.8, 0.4, 1.0)
			base_scale = Vector3.ONE * 2.6
	scale = base_scale
	if kind != Kind.NORMAL:
		var mesh := get_node_or_null(^"CharacterArmature/Skeleton3D/Ghost") as MeshInstance3D
		if mesh:
			var material := mesh.get_active_material(0)
			if material is BaseMaterial3D:
				material = material.duplicate()
				material.albedo_color = tint
				mesh.material_override = material

func _server_process(delta: float):
	if finished:
		return
	hit_cooldown = maxf(0.0, hit_cooldown - delta)
	if get_parent().freeze_time > 0:
		return
	
	var dir := Vector3(-self.position.x, 0, -self.position.z).normalized()
	self.rotation.y = atan2(dir.x, dir.z)
	self.position += dir * delta * speed
	get_parent().lobby.broadcast(position_updated.bind(position, rotation))

@rpc("unreliable") func position_updated(trans: Vector3, rot: Vector3):
	self.position = trans
	self.rotation = rot

@rpc func delete():
	$AudioStreamPlayer.play()
	$AnimationPlayer.play(&"Sad")
	var tween := get_tree().create_tween()
	tween.tween_property($CharacterArmature/Skeleton3D/Ghost, ^"transparency", 1.0, 0.5)
	tween.finished.connect(queue_free)

@rpc func hurt():
	$AudioStreamPlayer.pitch_scale = 1.5
	$AudioStreamPlayer.play()
	var tween := create_tween()
	tween.tween_property(self, ^"scale", base_scale * 1.3, 0.1)
	tween.tween_property(self, ^"scale", base_scale, 0.2)

func win():
	$AnimationPlayer.play("Happy")

# Server only. Returns true if the ghost died.
func take_hit(damage := 1, ignore_cooldown := false) -> bool:
	if dead or (hit_cooldown > 0 and not ignore_cooldown):
		return false
	hp -= damage
	if hp <= 0:
		dead = true
		get_parent().lobby.broadcast(delete)
		get_parent().on_ghost_killed(self)
		queue_free()
		return true
	hit_cooldown = 0.6
	# Knock the ghost back, away from the bed
	var out := Vector3(position.x, 0, position.z).normalized()
	position += out * 2.0
	get_parent().lobby.broadcast(position_updated.bind(position, rotation))
	get_parent().lobby.broadcast(hurt)
	hurt()
	return false

func _on_area_3d_area_entered(area: Area3D):
	if not multiplayer.is_server():
		return
	if area.is_in_group(&"target"):
		get_parent().ghost_reached_bed(self)

func _on_area_3d_body_entered(body: Node3D):
	if not multiplayer.is_server():
		return
	if body.is_in_group(&"player"):
		take_hit()
