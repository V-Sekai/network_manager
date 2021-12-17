@tool
extends EditorPlugin

var editor_interface: EditorInterface = null


func _enable_plugin():
	print("Initialising NetworkManager plugin")
	editor_interface = get_editor_interface()

	add_autoload_singleton("NetworkManager", "res://addons/network_manager/network_manager.gd")
	add_autoload_singleton("NetworkLogger", "res://addons/network_manager/network_logger.gd")


func _notification(p_notification: int):
	match p_notification:
		NOTIFICATION_PREDELETE:
			print("Destroying NetworkManager plugin")


func _get_plugin_name() -> String:
	return "NetworkManager"


func _disable_plugin() -> void:
	remove_autoload_singleton("NetworkManager")
	remove_autoload_singleton("NetworkLogger")
