class_name NetworkSpawn extends Position3D



func _enter_tree() -> void:
	add_to_group("NetworkSpawnGroup")


func _exit_tree() -> void:
	remove_from_group("NetworkSpawnGroup")
