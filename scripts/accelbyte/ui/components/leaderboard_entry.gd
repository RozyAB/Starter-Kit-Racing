class_name LeaderboardEntry
extends HBoxContainer

@export var _label_rank: Label
@export var _label_name: Label
@export var _label_time: Label


func setup(
	rank: int,
	in_name: String,
	time_secs: float
) -> void:
	var is_rank_invalid = rank <= 0
	
	_label_rank.text = str(rank) if not is_rank_invalid else "NaN"
	_label_name.text = in_name
	
	# Format time_secs to `mm:ss.SSS`.
	if is_rank_invalid:
		_label_time.text = "No lap time set."
	else:
		var minute = floori(time_secs / 60)
		var second = fposmod(time_secs, 60)
		_label_time.text = "%02d:%06.3f" % [
			minute,
			second
		]
