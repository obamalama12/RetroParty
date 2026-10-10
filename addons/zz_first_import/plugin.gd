@tool
extends EditorPlugin
# Temporary editor plugin: force-imports every asset that has a .import file, then quits.

func _enter_tree():
	_go.call_deferred()

func _collect(dir: String, out: PackedStringArray):
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".import"):
			var src := f.trim_suffix(".import")
			if not src.ends_with(".blend"):
				out.append(dir.path_join(src))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_collect(dir.path_join(d), out)

func _go():
	var fs := EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().create_timer(0.5).timeout
	var files := PackedStringArray()
	_collect("res://", files)
	# files that do not have a .import yet (new assets) can be listed here: FIRST_IMPORT_EXTRA=res://a.png,res://b.png
	for extra in OS.get_environment("FIRST_IMPORT_EXTRA").split(",", false):
		files.append(extra)
	print("FIRST_IMPORT importing ", files.size(), " files")
	fs.reimport_files(files)
	print("FIRST_IMPORT DONE")
	get_tree().quit()
