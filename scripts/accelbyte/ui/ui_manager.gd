extends Control

# Toast
@export var _toast_packed_scene: PackedScene
@export var _toast_container: Container

# Menu
@export var _menu_container: Container
@export var _close_menu_button: Button
@export var label_id: Label

# Matchmaking menu
@export var _matchmaking_pool: StringName
@export var _start_match_button: Button
@export var _cancel_match_button: Button
@export var _leave_game_session_button: Button

# Result
@export var _result_outer: Container
@export var _result_entry_packed_scene: PackedScene

class ResultData:
	var player_name: String
	var time_secs: float
	
	func _init(
		_player_name: String,
		_time_secs: float
	) -> void:
		player_name = _player_name
		time_secs = _time_secs


#region Overrides
func _ready() -> void:
	 # Hide menu by default.
	_menu_container.hide()
	
	# Disable cancel match and leave button by default.
	_cancel_match_button.disabled = true
	_leave_game_session_button.disabled = true


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _menu_container.visible:
			_on_button_close_pressed()
		else:
			# Show menu.
			_menu_container.show()
			_close_menu_button.grab_focus()
#endregion


#region Toast
func push_toast(message: String, persistent: bool = false) -> NotificationToast:
	var toast: NotificationToast = _toast_packed_scene.instantiate()
	_toast_container.add_child(toast)
	toast.setup(message, persistent)
	return toast


func clear_persistent():
	for child in _toast_container.get_children():
		var toast = child as NotificationToast
		if toast == null or toast.persistent:
			child.queue_free()


func clear_all():
	for child in _toast_container.get_children():
		child.queue_free()
#endregion


#region Result
func show_result(data: Array): # Array[ResultData]
	clear_result()
	for result in data:
		var entry: ResultEntry = _result_entry_packed_scene.instantiate()
		_result_outer.add_child(entry)
		entry.setup(result.player_name, result.time_secs)
	_menu_container.show()


func clear_result():
	for child in _result_outer.get_children():
		child.queue_free()
#endregion


func _on_button_close_pressed() -> void:
	# Hide menu.
	_menu_container.hide()


func _on_button_start_match_pressed() -> void:
	pass


func _on_button_cancel_match_pressed() -> void:
	pass


func _on_button_leave_session_pressed() -> void:
	pass


func _on_button_copy_id_pressed() -> void:
	if not label_id.text.is_empty():
		DisplayServer.clipboard_set(label_id.text)
