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
	
	AccelbyteManager.get_local_user_leaderboard_ranking(
		leaderboard_code,
		_on_get_local_user_leaderboard_ranking_completed
	)
	
	if leaderboard_cycle_id.is_empty():
		AccelbyteManager.get_alltime_leaderboard(
			leaderboard_code,
			5,
			_on_get_leaderboard_completed
		)
	else:
		AccelbyteManager.get_cycle_leaderboard(
			leaderboard_code,
			leaderboard_cycle_id,
			5,
			_on_get_leaderboard_completed
		)


func _on_get_local_user_leaderboard_ranking_completed(
	data: Array[AccelbyteManager.UserLeaderboardRankingData],
	is_succeeded: bool
):
	_waiting_ranking = false
	
	if not is_succeeded:
		_get_ranking_succeeded = false
		show_result()
		return
	_get_ranking_succeeded = true
	
	# Update self ranking.
	for ranking_data in data:
		if ranking_data.cycle_id == leaderboard_cycle_id:
			_self_entry.setup(
				ranking_data.rank,
				"%s (you)" % AccelbyteManager.get_user_id(),
				ranking_data.point
			)
			break
	show_result()


func _on_get_leaderboard_completed(
	data: Array[AccelbyteManager.LeaderboardData],
	is_succeeded: bool
):
	_waiting_leaderboard = false
	
	if not is_succeeded:
		_get_leaderboard_succeeded = false
		show_result()
		return
	_get_leaderboard_succeeded = true
	
	# Reset list.
	for child in _container.get_children():
		child.queue_free()
	
	# Contruct list.
	for index in range(data.size()):
		var leaderboard_data = data[index]
		var entry: LeaderboardEntry = _leaderboard_entry_packed_scene.instantiate()
		entry.setup(
			index + 1,
			"%s%s" % [
				leaderboard_data.user_id,
				" (you)" if leaderboard_data.user_id == AccelbyteManager.get_user_id() else ""
			],
			leaderboard_data.point
		)
		_container.add_child(entry)
	show_result()


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
