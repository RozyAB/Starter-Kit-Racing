extends TabContainer

@export var leaderboard_code: String
@export var leaderboard_cycle_id: String = "" # Treat empty as all time.

@export var _leaderboard_entry_packed_scene: PackedScene
@export var _container: Container
@export var _self_entry: LeaderboardEntry
@export var _label: Label

var _waiting_ranking: bool = false
var _waiting_leaderboard: bool = false
var _get_ranking_succeeded: bool = false
var _get_leaderboard_succeeded: bool = false


func _notification(what: int) -> void:
	# Prevent call at the start of game.
	if not is_node_ready():
		return
	
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			# Detect hierarchy visibility changes.
			if is_visible_in_tree():
				_setup()


func _setup() -> void:
	# Don't trigger request again if currently waiting for request.
	if _waiting_ranking or _waiting_leaderboard:
		return
	
	# This function called withing `NOTIFICATION_VISIBILITY_CHANGED`.
	# Godot's internal logic will override it back to the previous value.
	# Use deferred to prevent that.
	set_deferred("current_tab", 1)
	
	_label.text = "Loading..."
	_waiting_ranking = true
	_waiting_leaderboard = true


func show_result():
	if _waiting_leaderboard or _waiting_ranking:
		# Still waiting, do nothing.
		return
	
	# Failure handler.
	if not (_get_ranking_succeeded and _get_leaderboard_succeeded):
		_label.text = "Failed to retrieve data"
		return
	
	# Show result.
	current_tab = 0
