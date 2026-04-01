class_name NotificationToast
extends Control

@export var timeout: int = 5
@export var _label: Label
var persistent: bool


func setup(message: String, in_persistent: bool = false):
	_label.text = message
	self.persistent = in_persistent
	if not in_persistent:
		_delayed_destroy()


func _delayed_destroy():
	await get_tree().create_timer(timeout).timeout
	queue_free()
