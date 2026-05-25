class_name ResultEntry
extends Control

@export var _label_name: Label
@export var _label_time: Label


func setup(player_name: String, time_secs: float):
	_label_name.text = player_name
	
	# Format time_secs to `mm:ss.SSS`.
	var minute = floori(time_secs / 60)
	var second = fposmod(time_secs, 60)
	_label_time.text = "%02d:%06.3f" % [
		minute,
		second
	]
