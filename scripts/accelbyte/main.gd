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
class PlayerData:
	var lap_count: int = -1 # Start from -1 as the starting position is before the finish line.
	var elapsed_time: float = 0
	var has_finished: bool = false
#endregion


func get_player_data() -> PlayerData:
	return _player_data


#region overrides
func _ready() -> void:
	# Assign signals.
	_start_and_finish_line.vehicle_passed_finish_line.connect(_on_vehicle_passed_finish_line)
	_start_and_finish_line.vehicle_reversed_finish_line.connect(_on_vehicle_reversed_finish_line)
	
	# Run single player setup.
	_setup()


func _physics_process(delta: float) -> void:
	# Only run on race game mode
	if game_mode != EnumGameMode.RACE:
		return
	
	match state:
		EnumGameState.START:
			# Start countdown.
			countdown_counting -= delta
			if countdown_counting <= 0:
				state = EnumGameState.IN_PROGRESS
		EnumGameState.IN_PROGRESS:
			# Record player's race time.
			var player_data = get_player_data()
			if not player_data.has_finished:
				player_data.elapsed_time += delta


func _process(_delta: float) -> void:
	# Do nothing in free ride mode.
	if game_mode == EnumGameMode.FREE_RIDE:
		return
	
	# Show toast if already finished.
	var current_player_data = get_player_data()
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
				
				var player_data = get_player_data()
				result_data.append(UiManager.ResultData.new(
					"player",
					player_data.elapsed_time
				))
				
				UiManager.show_result(result_data)
	
	_previous_state = state
#endregion


func _setup():
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
	var vehicle: Vehicle = _vehicle_packed_scene.instantiate()
	add_child(vehicle)
	vehicle.global_transform = _start_and_finish_line.get_spawn_global_transform(0)
	_spawned_vehicles.append(vehicle)
	_view.target = vehicle
	
	# Construct player data.
	_player_data = PlayerData.new()


func _reset():
	# Free vehicles.
	for node in _spawned_vehicles:
		if node != null:
			node.free()
	
	# Reset vars.
	_spawned_vehicles.clear()
	state = EnumGameState.START
	countdown_counting = _countdown
	game_mode = EnumGameMode.FREE_RIDE


func _on_vehicle_passed_finish_line(_vehicle_name: String):
	# If not race mode, do nothing.
	if game_mode != EnumGameMode.RACE:
		return
	
	# Increase lap count.
	var player_data = get_player_data()
	player_data.lap_count += 1
	if not player_data.has_finished and player_data.lap_count >= _finish_lap_count:
		player_data.has_finished = true
	
	# Check if all players have finished.
	var it_player_data = get_player_data()
	if not it_player_data.has_finished:
		return
	
	# All players have finished, change state.
	state = EnumGameState.END


func _on_vehicle_reversed_finish_line(_vehicle_name: String):
	# If not race mode, do nothing.
	if game_mode != EnumGameMode.RACE:
		return
	
	# Decrease lap count.
	# Prevent vehicle from finishing by going back the finish and going forward.
	var player_data = get_player_data()
	player_data.lap_count -= 1
