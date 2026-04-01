extends Control

@export var _toast_packed_scene: PackedScene
@export var _container: Container


func push_toast(message: String, persistent: bool = false):
	var toast: NotificationToast = _toast_packed_scene.instantiate()
	_container.add_child(toast)
	toast.setup(message, persistent)


func clear_persistent():
	for child in _container.get_children():
		var toast = child as NotificationToast
		if toast == null or toast.persistent:
			child.queue_free()


func clear_all():
	for child in _container.get_children():
		child.queue_free()
