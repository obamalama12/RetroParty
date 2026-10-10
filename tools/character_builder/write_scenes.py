"""Writes Material.tres and character.tscn for the Blender-built characters.

    python write_scenes.py plugins/characters

Run build_characters.py first, copy the output into plugins/characters, and let
Godot import the .glb (the .glb.import files need the animation loop settings,
see README.md).
"""
import os
import sys

CHARACTERS = {"Bolt": "bolt", "Kit": "kit", "Mushi": "mushi", "Businessman": "businessman", "Timber": "timber", "Emo": "emo"}

# The Nintendo 64 look has no cartoon outline and soft smooth shading. OUTLINE=1 brings back the toon shading with the
# black outline that the characters had before.
OUTLINE = os.environ.get("OUTLINE", "0") == "1"
DIFFUSE_MODE = 3 if OUTLINE else 2          # 3 toon, 2 lambert wrap

MATERIAL_OUTLINE = '''[gd_resource type="StandardMaterial3D" load_steps=3 format=3]

[ext_resource type="Texture2D" path="res://plugins/characters/{name}/palette.png" id="1"]

[sub_resource type="StandardMaterial3D" id="1"]
cull_mode = 1
shading_mode = 0
albedo_color = Color(0, 0, 0, 1)
grow = true
grow_amount = 0.02

[resource]
resource_local_to_scene = true
next_pass = SubResource("1")
diffuse_mode = 3
specular_mode = 1
albedo_texture = ExtResource("1")
roughness = 0.75
texture_filter = 0
'''

MATERIAL_PLAIN = '''[gd_resource type="StandardMaterial3D" load_steps=2 format=3]

[ext_resource type="Texture2D" path="res://plugins/characters/{name}/palette.png" id="1"]

[resource]
resource_local_to_scene = true
diffuse_mode = 2
specular_mode = 2
albedo_texture = ExtResource("1")
roughness = 1.0
texture_filter = 0
'''

FACE_MATERIAL = '''[gd_resource type="StandardMaterial3D" load_steps=2 format=3]

[ext_resource type="Texture2D" path="res://plugins/characters/{name}/palette.png" id="1"]

[resource]
resource_local_to_scene = true
diffuse_mode = {diffuse}
specular_mode = 2
albedo_texture = ExtResource("1")
roughness = 1.0
texture_filter = 0
'''

SCENE = '''[gd_scene load_steps=6 format=3]

[ext_resource type="PackedScene" path="res://plugins/characters/{name}/{file}.glb" id="1"]
[ext_resource type="Script" path="res://common/scripts/character.gd" id="2"]
[ext_resource type="Material" path="res://plugins/characters/{name}/Material.tres" id="3"]
[ext_resource type="Material" path="res://plugins/characters/{name}/Face.tres" id="5"]

[sub_resource type="CapsuleShape3D" id="4"]
radius = 0.3
height = 0.9

[node name="{file}" instance=ExtResource("1")]
script = ExtResource("2")
animations = NodePath("AnimationPlayer")
collision_shape = NodePath("Shape3D")

[node name="Body" parent="Armature/Skeleton3D" index="0"]
surface_material_override/0 = ExtResource("3")
surface_material_override/1 = ExtResource("5")

[node name="Shape3D" type="CollisionShape3D" parent="." index="2"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.45, 0)
shape = SubResource("4")
'''

out = sys.argv[1]
for name, file in CHARACTERS.items():
    folder = os.path.join(out, name)
    with open(os.path.join(folder, "Material.tres"), "w") as f:
        f.write((MATERIAL_OUTLINE if OUTLINE else MATERIAL_PLAIN).format(name=name))
    with open(os.path.join(folder, "Face.tres"), "w") as f:
        f.write(FACE_MATERIAL.format(name=name, diffuse=DIFFUSE_MODE))
    with open(os.path.join(folder, "character.tscn"), "w") as f:
        f.write(SCENE.format(name=name, file=file))
    print("wrote", folder)
