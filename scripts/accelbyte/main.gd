class_name Main
extends Node3D

@export var _start_and_finish_line: StartAndFinishLine
@export var _view: View

# Game state vars.
@export var _finish_lap_count: int = 1
@export var _countdown: int = 5

# Replicated game state vars.
var countdown_counting: float = _countdown
var state: EnumGameState = EnumGameState.START
var game_mode: EnumGameMode

# Local var.
var _player_data: PlayerData
var _finished_toast
var _spawned_vehicles: Array[Node3D]
var _previous_state: EnumGameState = EnumGameState.START
@export var _vehicle_packed_scene: PackedScene

static var PARAM_KEY_GAME_MODE = "game_mode"
var _countdown_toast: NotificationToast
const SPAWN_DATA_KEY_TRANSFORM = "transform"


#region Enums
enum EnumGameMode {
	FREE_RIDE = 0,
	RACE
}


enum EnumGameState {
	START,
	IN_PROGRESS,
	END
}
#endregion


#region Structs
class PlayerData extends P2PManagerClass.PlayerDataBase:
	var lap_count: int = -1 # Start from -1 as the starting position is before the finish line.
	var elapsed_time: float = 0
	var has_finished: bool = false
	
	func update_from_dictionary(data: Dictionary):
		lap_count = data["lap_count"]
		elapsed_time = data["elapsed_time"]
		has_finished = data["has_finished"]
	
	func to_dictionary() -> Dictionary:
		return {
			"lap_count": lap_count,
			"elapsed_time": elapsed_time,
			"has_finished": has_finished
		}
#endregion


func get_player_data(user_id: String) -> PlayerData:
	if not P2PManager.is_active():
		return _player_data
	
	for it_user_id in P2PManager.player_data:
		# Assume node's name is the multiplayer ID.
		if it_user_id == user_id:
			return P2PManager.player_data[user_id]
	
	return null


#region overrides
func _ready() -> void:
	# Assign signals.
	_start_and_finish_line.vehicle_passed_finish_line.connect(_on_vehicle_passed_finish_line)
	_start_and_finish_line.vehicle_reversed_finish_line.connect(_on_vehicle_reversed_finish_line)
	P2PManager.client_connected.connect(_on_client_connected)
	P2PManager.host_started.connect(_on_host_started)
	P2PManager.host_stopped.connect(_on_host_stopped)
	P2PManager.connected_to_host.connect(_on_connected_to_host)
	P2PManager.disconnected_from_host.connect(_on_disconnected_from_host)
	P2PManager.replicated_node_spawned.connect(_on_replicated_node_spawned)
	
	# Register player data class to P2PManager.
	P2PManager.player_data_class = PlayerData
	
	# Run single player setup.
	if P2PManager.is_active():
		if not P2PManager.is_host:
			# If this is a multiplayer game, only run on host.
			_setup(true)
	else:
		# Run single player setup.
		_setup(false)


func _physics_process(delta: float) -> void:
	if (
		game_mode != EnumGameMode.RACE or # Only run on race game mode.
		(P2PManager.is_active() and not P2PManager.is_host) # If P2P, only run on host.
	):
		return
	
	match state:
		EnumGameState.START:
			# Start countdown.
			countdown_counting -= delta
			if countdown_counting <= 0:
				state = EnumGameState.IN_PROGRESS
		EnumGameState.IN_PROGRESS:
			# Record player's race time.
			for user_id in P2PManager.player_data:
				var player_data = P2PManager.player_data[user_id] as PlayerData
				if not player_data.has_finished:
					player_data.elapsed_time += delta


func _process(_delta: float) -> void:
	# Do nothing in free ride mode.
	if game_mode == EnumGameMode.FREE_RIDE:
		return
	
	# Show toast if already finished.
	var current_player_data = get_player_data(AccelbyteManager.get_user_id())
	if (
		current_player_data != null and
		_finished_toast == null and # Don't show toast if already shown.
		current_player_data.has_finished and
		state != EnumGameState.END # Don't show toast if game already ended.
	):
		_finished_toast = UiManager.push_toast("Finished. Waiting others...", true)
	
	match state:
		EnumGameState.START:
			# Show starting countdown.
			if _countdown_toast == null:
				_countdown_toast = UiManager.push_toast(
					"Starting in %d" % countdown_counting,
					true
				)
			else:
				_countdown_toast.setup(
					"Starting in %d" % countdown_counting,
					true
				)
		EnumGameState.IN_PROGRESS:
			# Clear starting countdown toast.
			if _countdown_toast != null:
				# Clear countdown.
				_countdown_toast.queue_free()
		EnumGameState.END:
			# Clear finished toast.
			if _finished_toast != null:
				_finished_toast.queue_free()
			
			# Show result screen when state just turned to END.
			if _previous_state != EnumGameState.END:
				var result_data: Array[UiManager.ResultData]
				for user_id in P2PManager.player_data:
					var player_data: PlayerData = P2PManager.player_data[user_id]
					result_data.append(UiManager.ResultData.new(
						user_id,
						player_data.elapsed_time
					))
				UiManager.show_result(result_data)
	
	_previous_state = state
#endregion


func _setup(is_multiplayer: bool):
	var tree = get_tree()
	
	# Get game mode type.
	game_mode = EnumGameMode.FREE_RIDE
	if tree.has_meta(PARAM_KEY_GAME_MODE):
		# Retrieve from tree's metadata.
		game_mode = get_tree().get_meta(PARAM_KEY_GAME_MODE, 0)
		
		# Clear metadata so that the next attempt won't be stuck at the last game mode.
		tree.remove_meta(PARAM_KEY_GAME_MODE)
	else:
		# If not set in tree's metadata, check launch param.
		var args = OS.get_cmdline_args()
		var game_mode_idx = args.find("-%s" % PARAM_KEY_GAME_MODE)
		if game_mode_idx != -1 and game_mode_idx + 1 < args.size():
			game_mode = args[game_mode_idx + 1] as EnumGameMode
	
	# Spawn vehicle for local player.
	if is_multiplayer:
		# P2P host, spawn via P2PManager.
		_on_client_connected(AccelbyteManager.get_user_id())
	else:
		# Single player, spawn traditionally.
		var vehicle: Vehicle = _vehicle_packed_scene.instantiate()
		add_child(vehicle)
		vehicle.global_transform = _start_and_finish_line.get_spawn_global_transform(0)
		_spawned_vehicles.append(vehicle)
		_view.target = vehicle
		
		# Construct player data.
		_player_data = PlayerData.new()
	
	# Free ride game mode doesn't have any rules, skip logic.
	if game_mode != EnumGameMode.FREE_RIDE:
		P2PManager.replicate_variables.append_array([
			P2PManager.ReplicateVariableData.new(self, "countdown_counting"),
			P2PManager.ReplicateVariableData.new(self, "state"),
			P2PManager.ReplicateVariableData.new(self, "game_mode")
		])


func _reset():
	# Free vehicles.
	if P2PManager.is_active() and P2PManager.is_host:
		for node in _spawned_vehicles:
			if node != null: # If previous session is P2P, P2PManager would've already freed the node.
				P2PManager.free_node(node.get_path())
	else:
		for node in _spawned_vehicles:
			if node != null: # If previous session is P2P, P2PManager would've already freed the node.
				node.free()
	
	# Reset vars.
	_spawned_vehicles.clear()
	state = EnumGameState.START
	countdown_counting = _countdown
	game_mode = EnumGameMode.FREE_RIDE


func _on_vehicle_passed_finish_line(_vehicle_name: String):
	# Only run on P2P host.
	if P2PManager.is_active() and not P2PManager.is_host:
		return
	
	# If not race mode, do nothing.
	if game_mode != EnumGameMode.RACE:
		return
	
	# Increase lap count.
	var player_data = get_player_data(_vehicle_name)
	player_data.lap_count += 1
	if not player_data.has_finished and player_data.lap_count >= _finish_lap_count:
		player_data.has_finished = true
	
	# Check if all players have finished.
	for user_id in P2PManager.player_data:
		var it_player_data = P2PManager.player_data[user_id] as PlayerData
		if not it_player_data.has_finished:
			return
	
	# All players have finished, change state.
	state = EnumGameState.END


func _on_vehicle_reversed_finish_line(_vehicle_name: String):
	# Only run on P2P host.
	if P2PManager.is_active() and not P2PManager.is_host:
		return
	
	# If not race mode, do nothing.
	if game_mode != EnumGameMode.RACE:
		return
	
	# Decrease lap count.
	# Prevent vehicle from finishing by going back the finish and going forward.
	var player_data = get_player_data(_vehicle_name)
	player_data.lap_count -= 1


func _on_client_connected(user_id: String):
	# Only run on host.
	if not P2PManager.is_host:
		return
	
	# Start / reset countdown.
	if state == EnumGameState.START:
		state = EnumGameState.START
		countdown_counting = _countdown
	
	# Spawn vehicle.
	var init_transform = _start_and_finish_line.get_spawn_global_transform(_spawned_vehicles.size())
	var vehicle: Node3D = P2PManager.spawn_node(_vehicle_packed_scene, self, user_id, {
		SPAWN_DATA_KEY_TRANSFORM: JSON.from_native(init_transform)
	})
	vehicle.global_transform = init_transform
	_spawned_vehicles.append(vehicle)
	
	# Update view target if this is owned by the local player.
	if vehicle.name == AccelbyteManager.get_user_id():
		_view.target = vehicle


func _on_host_started():
	_reset()
	_setup(true)


func _on_host_stopped():
	# Clear metadata so that the next attempt won't be stuck at the last game mode.
	get_tree().remove_meta(PARAM_KEY_GAME_MODE)
	
	_reset()
	_setup(false)


func _on_connected_to_host():
	_reset()


func _on_disconnected_from_host():
	# Clear metadata so that the next attempt won't be stuck at the last game mode.
	get_tree().remove_meta(PARAM_KEY_GAME_MODE)
	
	_reset()
	_setup(false)


func _on_replicated_node_spawned(node: Node, additional_data: Dictionary):
	var new_vehicle = node as Vehicle
	if new_vehicle == null:
		return
	
	# Update initial position
	(node as Node3D).global_transform = JSON.to_native(additional_data[SPAWN_DATA_KEY_TRANSFORM])
	
	# Update view.
	if new_vehicle.name == AccelbyteManager.get_user_id():
		_view.target = node
