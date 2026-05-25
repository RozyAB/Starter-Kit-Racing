class_name P2PManagerClass
extends Node

# Wraps AccelByteP2PManager into a Host Client model P2P
#
# Prerequisites:
#   - Device login and lobby connection must be established first
#   - WebRTC plugin must be installed (see requirements below)
# WebRTC Plugin Requirement:
#   - Desktop (Windows/Linux/macOS): Install WebRTC plugin from Godot Asset Library
#     Asset Library ID: 2103 (https://godotengine.org/asset-library/asset/2103)
#     GitHub: https://github.com/godotengine/webrtc-native/releases
#   - Web (HTML5): Built-in, no plugin needed
#
# Known issues:
# 	- Send / broadcast data from client to client through host would result in the sender shown as host instead of the original sender

# Host side signals.
signal host_started()
signal client_connected(user_id: String)
signal client_disconnected(user_id: String)
signal host_stopped()

# Client side signals.
signal connected_to_host()
signal disconnected_from_host()
signal replicated_node_spawned(node: Node)

# Both side signals.
signal data_received(peer_user_id: String, data: Dictionary)
signal turn_servers_ready(server_count: int)


var p2p_manager: AccelByteP2PManager
var connected_peer_ids: Array[String] # Should only contains the host's user id on client.
var is_host: bool = false
var player_data: Dictionary # <user_id, PlayerDataBase>; Will be replicated from host to all client periodically.
var spawn_request_data: Array[SpawnRequestData] # Host stores this to send to client later.

const _REPLICATION_INTERVAL: float = 0.03
const _REPLICATION_KEY_PLAYER_DATA = "player_data"
const _REPLICATION_KEY_VARIABLES = "replicate_variables"
const _REPLICATION_KEY_SPAWN_NODES = "spawn_nodes"
const _REPLICATION_KEY_RELAY_TARGET = "relay_target"
const _REPLICATION_KEY_NODE_PATH = "node_path"
var _network_timer: Timer
var replicate_variables: Array[ReplicateVariableData] # Data here should be replicated periodically.
var replicated_nodes: Array[Node]
var player_data_class: Variant


#region Structs
@abstract class PlayerDataBase extends Object:
	@abstract func update_from_dictionary(data: Dictionary)
	@abstract func to_dictionary() -> Dictionary


class ReplicateVariableData extends Object:
	var node: Node
	var variable_name: String
	var value: Variant
	
	func _init(
		target_node: Node,
		target_variable_name: String
	) -> void:
		node = target_node
		variable_name = target_variable_name
	
	static func from_dictionary(data: Dictionary, context: Node) -> ReplicateVariableData:
		var obj = ReplicateVariableData.new(
			context.get_tree().root.get_node(NodePath(data["node"])),
			data["variable_name"]
		)
		obj.value = JSON.to_native(data["value"])
		return obj
	
	func to_dictionary() -> Dictionary:
		return {
			"node": str(node.get_path()),
			"variable_name": variable_name,
			"value": JSON.from_native(node[variable_name])
		}


class SpawnRequestData extends Object:
	var scene_path: String
	var parent_node: Node
	var owner_user_id: String
	var additional_data: Dictionary
	
	func _init(
		_scene_path: String,
		_parent_node: Node,
		_owner_user_id: String,
		_additional_data: Dictionary
	):
		scene_path = _scene_path
		parent_node = _parent_node
		owner_user_id = _owner_user_id
		additional_data = _additional_data
	
	static func from_dictionary(data: Dictionary, context: Node) -> SpawnRequestData:
		return SpawnRequestData.new(
			data["scene_path"],
			context.get_tree().root.get_node(data["parent_node"]),
			data["owner_user_id"],
			data["additional_data"]
		)
	
	func to_dictionary() -> Dictionary:
		return {
			"scene_path": scene_path,
			"parent_node": str(parent_node.get_path()),
			"owner_user_id": owner_user_id,
			"additional_data": additional_data
		}
#endregion


#region Enum
enum DataType {
	NONE = 0,
	BROADCAST_RELAY, # Allowing client to broadcast through host.
	REPLICATION,
	REPLICATION_RELAY, # Allowing client to replicate its data through host.
	SPAWN_NODE,
	FREE_NODE,
	INITIALIZE,
	RELAY
}
#endregion


#region Public functions
func start_host() -> bool:
	_setup_p2p_manager()
	await turn_servers_ready
	
	# Host setup.
	is_host = true
	_network_timer.start()
	player_data[AccelbyteManager.get_user_id()] = player_data_class.new()
	
	# Notify.
	host_started.emit()
	
	return true


func stop_host():
	_cleanup()
	host_stopped.emit()


func connect_to_host(user_id: String) -> bool:
	_setup_p2p_manager()
	await turn_servers_ready
	
	if not p2p_manager:
		push_error("[P2PManager] P2P Manager not initialized")
		return false

	if user_id.is_empty():
		push_error("[P2PManager] Target user ID cannot be empty")
		return false

	if user_id == AccelbyteManager.get_user_id():
		push_error("[P2PManager] Cannot connect to yourself")
		return false

	print("[P2PManager] Initiating P2P connection to: ", user_id)
	var result = p2p_manager.connect_to_peer(user_id)
	var is_succeeded = result == OK
	if not is_succeeded:
		push_error("[P2PManager] Failed to connect to host: %s" % user_id)
	return is_succeeded


func disconnect_from_host() -> bool:
	if not p2p_manager or connected_peer_ids.is_empty():
		return false
	p2p_manager.disconnect_peer(connected_peer_ids[0])
	_cleanup()
	disconnected_from_host.emit()
	return true


func send_data(user_id: String, data: Dictionary) -> bool:
	if not p2p_manager:
		return false

	if connected_peer_ids.has(user_id):
		var json_str = _parse_data(DataType.NONE, data)
		var result = p2p_manager.send_string_to_peer(user_id, json_str)
		return result == OK
	else:
		# Client trying to send data to another client. Send to host, first.
		if connected_peer_ids.is_empty():
			push_error("[P2PManager] Cannot relay: not connected to host.")
			return false
		print("[P2PManager] Sending relay instruction to host.")
		var json_str = _parse_data(DataType.RELAY, data, {_REPLICATION_KEY_RELAY_TARGET: user_id})
		var result = p2p_manager.send_string_to_peer(connected_peer_ids[0], json_str)
		return result == OK


func broadcast_data(data: Dictionary) -> bool:
	if is_host:
		# Broadcast immediately.
		# The broadcaster won't receive the data. Only every other clients.
		if not p2p_manager:
			return false
		var json_str = _parse_data(DataType.NONE, data)
		var result = p2p_manager.broadcast_string(json_str)
		return result == OK
	else:
		# Send to host, first.
		print("[P2PManager] Sending broadcast instruction to host.")
		if not p2p_manager:
			return false
		var json_str = _parse_data(DataType.BROADCAST_RELAY, data)
		var result = p2p_manager.send_string_to_peer(connected_peer_ids[0], json_str)
		return result == OK


func spawn_node(
	packed_scene: PackedScene,
	parent_node: Node,
	owner_user_id: String,
	additional_data: Dictionary = {}
) -> Node:
	# Host is the only one that can request spawn.
	if not is_host:
		push_error("[P2PManager] Can't request spawn from a non-host.")
		return null
	
	# Spawn on host.
	var new_node = packed_scene.instantiate()
	new_node.name = owner_user_id
	parent_node.add_child(new_node)
	replicated_nodes.append(new_node)
	
	# Broadcast to other clients.
	var request_data = SpawnRequestData.new(
		packed_scene.resource_path,
		parent_node,
		owner_user_id,
		additional_data
	)
	spawn_request_data.append(request_data) # Host need to keep a list of spawned node so that it can send it to new client later on.
	p2p_manager.broadcast_string(_parse_data(DataType.SPAWN_NODE, request_data.to_dictionary()))
	
	return new_node


func free_node(node_path: NodePath):
	# Host is the only one that can request free.
	if not is_host:
		push_error("[P2PManager] Can't request free from a non-host.")
		return

	# Remove matching spawn request entries so new clients won't receive them.
	spawn_request_data = spawn_request_data.filter(
		func(it: SpawnRequestData) -> bool:
			return it.parent_node.get_path().get_concatenated_names() + "/" + it.owner_user_id != str(node_path)
	)

	# Free locally and remove from replicated_nodes.
	var node_removed: bool = false
	for node in replicated_nodes:
		if node.get_path() == node_path:
			replicated_nodes.erase(node)
			node.free()
			node_removed = true
			break
	
	# Safety, in case the previous game sessoin isn't a multiplayer.
	if not node_removed:
		get_tree().root.get_node(node_path).free()

	# Broadcast so all clients free their copy.
	p2p_manager.broadcast_string(_parse_data(DataType.FREE_NODE, {_REPLICATION_KEY_NODE_PATH: str(node_path)}))


func is_active() -> bool:
	return p2p_manager != null
#endregion


#region Internal callbacks
func _on_data_received(peer_user_id: String, data: PackedByteArray) -> void:
	# Parse to JSON.
	var text = data.get_string_from_utf8()
	var json = JSON.parse_string(text)
	var data_body: Dictionary = json["data"]
	
	# For debug.
	#print("[P2PManager] Received P2P data from ", peer_user_id, ": ", text)
	
	# Handle data.
	match json["type"] as DataType:
		DataType.BROADCAST_RELAY:
			if (is_host):
				# Relay broadcast data to every other client except `peer_user_id`.
				for user_id in connected_peer_ids:
					if user_id == peer_user_id:
						continue
					send_data(user_id, data_body)
				
				# Trigger on host.
				_on_data_received(
					AccelbyteManager.get_user_id(),
					var_to_bytes(_parse_data(DataType.NONE, data_body))
				)
			return
		DataType.REPLICATION_RELAY:
			if (is_host):
				# Relay broadcast data to every other client except `peer_user_id`.
				for user_id in connected_peer_ids:
					if user_id == peer_user_id:
						continue
					p2p_manager.send_string_to_peer(
						user_id,
						_parse_data(DataType.REPLICATION, data_body)
					)
				
				# Trigger on host.
				_on_data_received(
					AccelbyteManager.get_user_id(),
					_parse_data(DataType.REPLICATION, data_body).to_utf8_buffer()
				)
			return
		DataType.REPLICATION:
			_handle_replicate_data(data_body)
			return
		DataType.SPAWN_NODE:
			_handle_spawn_node(SpawnRequestData.from_dictionary(data_body, self))
			return
		DataType.FREE_NODE:
			_handle_free_node(NodePath(data_body[_REPLICATION_KEY_NODE_PATH]))
			return
		DataType.INITIALIZE:
			if (data_body.has(_REPLICATION_KEY_SPAWN_NODES)):
				for spawn_node_data in data_body[_REPLICATION_KEY_SPAWN_NODES]:
					_handle_spawn_node(SpawnRequestData.from_dictionary(spawn_node_data, self))
			_handle_replicate_data(data_body)
			return
		DataType.RELAY:
			var target_user_id = json[_REPLICATION_KEY_RELAY_TARGET]
			send_data(target_user_id, data_body)
			return
	
	# Notify.
	UiManager.push_toast(str(data_body))
	data_received.emit(peer_user_id, data_body)


func _on_peer_connected(peer_user_id: String):
	# On the initiator / client, peer_user_id would be the host.
	# On host, peer_user_id would be the client.
	print("[P2PManager] Peer conected: %s" % peer_user_id)
	connected_peer_ids.append(peer_user_id)
	
	if is_host:
		# Add player data.
		player_data[peer_user_id] = player_data_class.new()
		
		# Request replicated data and node initialization.
		var data = _contruct_replication_variables_data(true)
		var spawn_data: Array[Dictionary]
		for it_spawn_data in spawn_request_data:
			spawn_data.append(it_spawn_data.to_dictionary())
		data[_REPLICATION_KEY_SPAWN_NODES] = spawn_data
		p2p_manager.send_string_to_peer(peer_user_id, _parse_data(DataType.INITIALIZE, data))
		
		# Notify that a client is connected.
		client_connected.emit(peer_user_id)
	else:
		connected_to_host.emit()
		_network_timer.start()


func _on_peer_disconnected(peer_user_id: String):
	# If disconnect is called, this won't trigger on the "disconnectee", only other party.
	print("[P2PManager] Peer disconected: %s" % peer_user_id)
	
	if is_host:
		# Remove player data.
		player_data.erase(peer_user_id)
		connected_peer_ids.erase(peer_user_id)
	
		# Host frees any replicated node owned by the disconnected peer.
		for node in replicated_nodes.duplicate():
			if node.name == peer_user_id:
				free_node(node.get_path())
	
		client_disconnected.emit(peer_user_id)
	else:
		# Unexpectedly disconnect from host.
		_cleanup()
		disconnected_from_host.emit()


func _on_ice_servers_configured(server_count: int) -> void:
	print("[P2PManager] Ready for connections! Turn server count: %d" % server_count)
	turn_servers_ready.emit(server_count)
#endregion


func _parse_data(type: DataType, data: Dictionary, additional_headers: Dictionary = {}) -> String:
	var final_json = {"type": type, "data": data}
	final_json.merge(additional_headers)
	return JSON.stringify(final_json)


func _handle_replicate_data(data: Dictionary):
	# Update player data.
	if (data.has(_REPLICATION_KEY_PLAYER_DATA)):
		for user_id in data[_REPLICATION_KEY_PLAYER_DATA]:
			if not player_data.has(user_id):
				player_data[user_id] = player_data_class.new()
			(player_data[user_id] as PlayerDataBase).update_from_dictionary(data[_REPLICATION_KEY_PLAYER_DATA][user_id])
	
	# Update other replication data.
	if (data.has(_REPLICATION_KEY_VARIABLES)):
		for it_data in data[_REPLICATION_KEY_VARIABLES]:
			var replication_data = ReplicateVariableData.from_dictionary(it_data, self)
			if replication_data.node == null:
				push_warning("[P2PManager] Replicate node is null (%s)" % it_data["node"])
				continue
			replication_data.node[replication_data.variable_name] = replication_data.value


func _handle_free_node(node_path: NodePath):
	for node in replicated_nodes.duplicate():
		if node.get_path() == node_path:
			replicated_nodes.erase(node)
			node.queue_free()
			return
	# Fallback: try to find the node in the tree directly.
	var node = get_tree().root.get_node_or_null(node_path)
	if node:
		node.queue_free()


func _handle_spawn_node(data: SpawnRequestData):
	var new_node = (load(data.scene_path) as PackedScene).instantiate()
	new_node.name = data.owner_user_id
	data.parent_node.add_child(new_node)
	replicated_nodes.append(new_node)
	replicated_node_spawned.emit(new_node, data.additional_data)


func _ready():
	# Setup replication timer.
	_network_timer = Timer.new()
	_network_timer.timeout.connect(_broadcast_replication)
	_network_timer.one_shot = false
	_network_timer.wait_time = _REPLICATION_INTERVAL
	_network_timer.autostart = false
	add_child(_network_timer)


func _broadcast_replication() -> void:
	if connected_peer_ids.is_empty():
		# No connected peer, skip.
		return
	
	if is_host:
		var replicate_data = _contruct_replication_variables_data(true)
		if not p2p_manager.broadcast_string(_parse_data(DataType.REPLICATION, replicate_data)):
			push_error("[P2PManager] Replication failed.")
	else:
		# Client to send data to host first to send replication.
		var replicate_data = _contruct_replication_variables_data(false)
		p2p_manager.send_string_to_peer(connected_peer_ids[0], _parse_data(DataType.REPLICATION_RELAY, replicate_data))


func _contruct_replication_variables_data(include_player_data: bool) -> Dictionary:
	var replicate_data: Dictionary
	
	# Replicate player data from host to clients.
	if include_player_data:
		var player_data_dict: Dictionary
		for user_id in player_data:
			player_data_dict[user_id] = player_data[user_id].to_dictionary()
		if not player_data_dict.is_empty():
			replicate_data[_REPLICATION_KEY_PLAYER_DATA] = player_data_dict
	
	# Replicate manually set replicate_variables.
	var replicate_variables_dict: Array[Dictionary]
	for replicate_variable in replicate_variables:
		replicate_variables_dict.append(replicate_variable.to_dictionary())
	if not replicate_variables_dict.is_empty():
		replicate_data[_REPLICATION_KEY_VARIABLES] = replicate_variables_dict
	
	return replicate_data


func _cleanup():
	print("[P2PManager] Cleaning up")
	if p2p_manager:
		# Explicitly disconnect each peer before cleanup so the remote side receives
		# proper signaling and clears its peer entry. p2p_manager.cleanup() closes
		# peers locally without notifying the remote, leaving stale entries that
		# reject subsequent connection attempts.
		for peer_id in connected_peer_ids.duplicate():
			p2p_manager.disconnect_peer(peer_id)
		p2p_manager.peer_connected.disconnect(_on_peer_connected)
		p2p_manager.peer_disconnected.disconnect(_on_peer_disconnected)
		p2p_manager.data_received.disconnect(_on_data_received)
		p2p_manager.ice_servers_configured.disconnect(_on_ice_servers_configured)
		p2p_manager.cleanup()
		p2p_manager = null
	for node in replicated_nodes:
		node.queue_free()
	replicated_nodes.clear()
	replicate_variables.clear()
	spawn_request_data.clear()
	connected_peer_ids.clear()
	player_data.clear()
	is_host = false
	_network_timer.stop()


func _setup_p2p_manager():
	_cleanup()
	
	# Create P2P Manager.
	p2p_manager = AccelByteP2PManager.new()

	# Connect P2P signals.
	p2p_manager.peer_connected.connect(_on_peer_connected)
	p2p_manager.peer_disconnected.connect(_on_peer_disconnected)
	p2p_manager.data_received.connect(_on_data_received)
	p2p_manager.ice_servers_configured.connect(_on_ice_servers_configured)

	# Initialize with SDK, lobby WebSocket, and scene tree.
	p2p_manager.initialize(AccelbyteManager.sdk, AccelbyteManager.lobby, get_tree().root)

	print("[P2PManager] Initialized. Waiting for TURN server configuration...")
