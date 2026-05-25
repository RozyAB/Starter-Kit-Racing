extends Node

var sdk: AccelByteSDKWrapper

# Auth
var iam: IamService

# Session
var lobby: LobbyWsService
var _active_game_session_id: String = ""

# Matchmaking
signal matchmaking_started()
signal matchmaking_failed(reason: String)
signal matchmaking_canceled()
signal matchmaking_found()

var matchmaking: Match2Service
var session: SessionService
var _matchmaking_ticket_id: StringName
var _is_polling: bool = false
var _POOL_INTERVAL_SEC: int = 3
var _matchmaking_timer: Timer

# Statistics and Leaderboard
var STAT_CODE_BEST_LAP_TIME = "best-lap-time"
var leaderboard: LeaderboardService
var social: SocialService
const _stat_update_strategy_to_string: Dictionary = {
	StatUpdateStrategy.OVERRIDE: "OVERRIDE",
	StatUpdateStrategy.INCREMENT: "INCREMENT",
	StatUpdateStrategy.MAX: "MAX",
	StatUpdateStrategy.MIN: "MIN",
}

## Supported update strategies for stat items.
enum StatUpdateStrategy {
	OVERRIDE = 0,
	INCREMENT,
	MAX,
	MIN
}

## Data structure for a single stat update entry used in bulk updates.
class BulkStatUpdateData:
	func _init(
		_user_id: StringName,
		_stat_code: String,
		_update_strategy: StatUpdateStrategy,
		_value: float
	) -> void:
		user_id = _user_id
		stat_code = _stat_code
		update_strategy = _update_strategy
		value = _value
	
	var user_id: StringName
	var stat_code: String
	var update_strategy: StatUpdateStrategy
	var value: float

## Data structure for a leaderboard entry returned from ranking queries.
class LeaderboardData:
	func _init(
		_point: float,
		_user_id: StringName,
		_hidden: bool
	) -> void:
		point = _point
		user_id = _user_id
		hidden = _hidden
	
	var point: float
	var user_id: StringName
	var hidden: bool

## Data structure for the local user's leaderboard ranking, including cycle info.
class UserLeaderboardRankingData:
	var point: float
	var rank: int
	var hidden: bool
	var cycle_id: String  # Empty string means all-time ranking


#region Overrides
func _ready():
	# SDK init.
	sdk = AccelByteSDKWrapper.new()
	sdk.initialize(self)

	# Load core credentials from project.godot [accelbyte] section
	var base_url: String = ProjectSettings.get_setting("accelbyte/base_url", "")
	var np: String = ProjectSettings.get_setting("accelbyte/namespace", "")
	var client_id: String = ProjectSettings.get_setting("accelbyte/client_id", "")
	var client_secret: String = ProjectSettings.get_setting("accelbyte/client_secret", "")

	# Ensure credentials are set
	assert(
		not (base_url.is_empty() or np.is_empty() or client_id.is_empty()),
		"[AccelByteManager] Missing required project settings: accelbyte/base_url, accelbyte/namespace, accelbyte/client_id"
	)

	# Setup credentials
	sdk.set_base_url(base_url)
	sdk.set_client_credentials(client_id, client_secret)
	sdk.set_namespace(np)
	
	# Setup vars.
	iam = sdk.get_service(IamService)
	matchmaking = sdk.get_service(Match2Service)
	session = sdk.get_service(SessionService)
	lobby = sdk.get_lobby_ws_service()
	leaderboard = sdk.get_service(LeaderboardService)
	social = sdk.get_service(SocialService)
	
	# Bind signals.
	sdk.lobby_connected.connect(_on_lobby_connected)
	sdk.lobby_disconnected.connect(_on_lobby_disconnected)
	
	# Login and show notification.
	# Login username if `-username <email/username>` and `-password <password>` launch param are provided.
	# Use device ID otherwise.
	UiManager.push_toast("Logging in...", true)
	var args = OS.get_cmdline_args()
	var username_idx = args.find("-username")
	var password_idx = args.find("-password")
	var on_completed = func(succeeded: bool):
		# Connect to lobby as preparation for P2P.
		var lobby_error = sdk.lobby_connect()
		if not lobby_error.is_empty():
			push_error("[AccelByteManager] Lobby connect failed.")
			UiManager.push_toast("Failed to connect to lobby")
		
		UiManager.clear_persistent()
		UiManager.push_toast("Login succeeded" if succeeded else "Login Failed")
		UiManager.label_id.text = get_user_id()
	if username_idx != -1 and password_idx != -1 and username_idx + 1 < args.size() and password_idx + 1 < args.size():
		login_username(args[username_idx + 1], args[password_idx + 1], on_completed)
	else:
		login_device_id(on_completed)


func _exit_tree() -> void:
	logout()
	
	# Ensure clean close.
	sdk.lobby_disconnect()
#endregion


#region Auth
func login_device_id(completed: Callable = Callable()): # completed(succeeded)
	var device_id: String = OS.get_unique_id()
	# All possible platoform ID: steam, steamopenid, facebook, google, googleplaygames, oculus, twitch, discord, android, ios, apple, device, justice, epicgames, ps4, ps5, nintendo, awscognito, live, xblweb, netflix, snapchat
	var result: Dictionary = await iam.platform_token_grant_v4(
		"device",
		"",
		"",
		"",
		"",
		true,
		device_id
	)
	var is_success = result["success"]

	if is_success:
		# Tokens are automatically stored by the SDK
		completed.call(true)
	else:
		push_error("[AccelByteManager] Device ID login failed: %s" % str(result))
		completed.call(false)


func login_username(username: String, password: String, completed: Callable = Callable()): # completed(succeeded)
	# All possible grant type: authorization_code, password, refresh_token, client_credentials, urn:ietf:params:oauth:grant-type:extend_client_credentials, urn:ietf:params:oauth:grant-type:login_queue_ticket
	var result: Dictionary = await iam.token_grant_v4(
		"password",
		"",
		"",
		"",
		"",
		"",
		"",
		"",
		"",
		false,
		"",
		password,
		"",
		"",
		"",
		username
	)
	var is_success = result["success"]

	if is_success:
		completed.call(true)
	else:
		push_error("[AccelByteManager] Username login failed: %s" % str(result))
		completed.call(false)


func logout(completed: Callable = Callable()): # completed(succeeded):
	var result: Dictionary = await iam.logout()
	var is_success = result["success"]
	if is_success:
		# Tokens are automatically stored by the SDK
		completed.call(true)
	else:
		push_error("[AccelByteManager] Logout failed: %s" % str(result))
		completed.call(false)


func get_user_id() -> String:
	return sdk.get_user_id()
#endregion


#region Session
func _on_lobby_connected(_data: Dictionary):
	UiManager.push_toast("Connected to lobby")


func _on_lobby_disconnected(_data: Dictionary):
	UiManager.push_toast("Failed to connect to lobby")


func leave_game_session(completed: Callable = Callable()): # completed(succeeded):
	if _active_game_session_id.is_empty():
		# No active game session id, treat as succeeded.
		completed.call(true)
		return
	
	var result: Dictionary = await session.leave_game_session("", _active_game_session_id)
	var is_success = result["success"]
	if is_success:
		completed.call(true)
	else:
		push_error("[AccelByteManager] Logout failed: %s" % str(result))
		completed.call(false)
	
	# Regardless the result, leave server and reset stored session ID.
	_active_game_session_id = ""
#endregion


#region Matchmaking
func start_matchmaking(matchpool: StringName):
	# Result structure:
	#{
		#"status_code": int,
		#"data": {
			#"matchTicketID": String,
			#"queueTime": int
		#}
		#"success": bool,
		#"error": String
	#}
	var result = await matchmaking.create_match_ticket(
		"", # Use empty string to default to already set namespace.
		{
			"matchPool" = matchpool
		}
	)
	
	# Error handler.
	var is_success = result["success"]
	if not is_success:
		push_error("[AccelByteManager] Matchmaking failed: %s" % str(result))
		matchmaking_failed.emit(result["error"])
		return
	
	# Success handler.
	_matchmaking_ticket_id = result["data"]["matchTicketID"]
	_is_polling = true
	matchmaking_started.emit()
	
	# Trigger ticket periodic poll.
	_matchmaking_timer = Timer.new()
	_matchmaking_timer.autostart = true
	_matchmaking_timer.one_shot = false
	_matchmaking_timer.wait_time = _POOL_INTERVAL_SEC
	_matchmaking_timer.timeout.connect(Callable(self, "_poll_ticket_status"))
	add_child(_matchmaking_timer)


func cancel_matchmaking():
	_stop_poll_ticket()
	await matchmaking.delete_match_ticket("", _matchmaking_ticket_id)
	
	# Trigger matchmaking canceled regardless the result.
	matchmaking_canceled.emit()


func _poll_ticket_status():
	if not _is_polling:
		return
	
	# Result structure:
	#{
		#"status_code": int,
		#"data": {
			#"sessionID": String,
			#"matchFound": bool,
			#"isActive": bool
		#}
		#"success": bool,
		#"error": String
	#}
	var result = await matchmaking.match_ticket_details("", _matchmaking_ticket_id)
	var is_success = result["success"]
	var is_match_found = result["data"]["matchFound"]
	if is_match_found and is_success:
		_stop_poll_ticket()
		
		var session_id = result["data"]["sessionID"]
		_resolve_session(session_id)
		# Store session id.
		_active_game_session_id = session_id
	elif not is_success:
		_stop_poll_ticket()
		matchmaking_failed.emit(result["error"])


func _stop_poll_ticket():
	_is_polling = false
	if _matchmaking_timer != null:
		_matchmaking_timer.stop()
	_matchmaking_timer = null


func _resolve_session(session_id: StringName):
	# Result structure:
	#{
		#"status_code": int,
		#"data": {
			#"matchPool": String,
			#"backfillTicketID": String,
			#"code": String,
			#"ticketIDs": Object,
			#"isActive": bool,
			#"isFull": bool,
			#"version": String,
			#"id": String,
			#"namespace": String,
			#"createdAt": String,
			#"createdBy": String,
			#"updatedAt": String,
			#"leaderID": String,
			#"configuration": {
				#"persistent": bool,
				#"textChat": bool,
				#"textChatMode": String,
				#"autoJoin": bool,
				#"tieTeamsSessionLifetime": bool,
				#"minPlayers": int,
				#"maxPlayers": int,
				#"inviteTimeout": float,
				#"inactiveTimeout": float,
				#"name": String,
				#"type": String,
				#"joinability": String,
				#"deployment": String,
				#"clientVersion": String,
				#"requestedRegions": [],
				#"dsSource": String,
				#"preferredClaimKeys": Object,
				#"fallbackClaimKeys": Object,
				#"nativeSessionSetting": {},
				#"PSNBaseURL": String,
				#"maxActiveSession": int,
				#"disableResendInvite": bool,
				#"attributes": {},
				#"leaderElectionGracePeriod": float,
				#"grpcSessionConfig": {},
				#"asyncProcessDSRequest": {},
				#"ttlHours": int,
				#"amsClaimTimeoutMinutes": int,
				#"partyCodeLength": int,
				#"partyCodeGeneratorString": String
			#},
			#"members": [
				#{
					#"id": String,
					#"status": String,
					#"statusV2": String,
					#"updatedAt": String,
					#"platformID": String,
					#"platformUserID": String
				#}
			#],
			#"attributes": {},
			#"DSInformation": {
				#"CreatedAt": String,
				#"RequestedAt": String,
				#"Status": String,
				#"StatusV2": String
			#},
			#"teams": [
				#{
					#"teamId": String,
					#"userIDs": [String],
					#"parties": [
						#{
							#"partyID": String,
							#"userIDs": [String],
						#}
					#]
				#}
			#]
		#}
		#"success": bool,
		#"error": String
	#}
	var result = await session.get_game_session("", session_id)
	
	# Error handler.
	var is_success = result["success"]
	if not is_success:
		push_error("[AccelByteManager] Matchmaking failed: %s" % str(result))
		matchmaking_failed.emit(result["error"])
		return
	
	var session_data = result["data"]
	var user_id: String = get_user_id()
	var host_user_id: String = session_data["leaderID"]
	var is_host: bool = (user_id == host_user_id)
	
	if is_host:
		P2PManager.start_host()
	else:
		P2PManager.connect_to_host(host_user_id)
	
	matchmaking_found.emit()
#endregion


#region Statistics and Leaderboard
## Update the local (authenticated) user's single stat item value.
## on_complete(is_succeeded: bool)
func update_local_user_stat(stat_code: String, update_strategy: StatUpdateStrategy, value: float, on_complete: Callable = Callable()):
	# Send request.
	var user_id: String = get_user_id()
	var body: Dictionary = {
		"updateStrategy": _stat_update_strategy_to_string[update_strategy],
		"value": value,
	}
	var result: Dictionary = await social.update_user_stat_item_value_1("", stat_code, user_id, "", body)
	
	# Response handler.
	var is_success: bool = result["success"]
	if not is_success:
		push_error("[AccelByteManager] update_local_user_stat failed: %s" % str(result))
	on_complete.call(is_success)


## Bulk update stat items for multiple users.
## on_complete(is_succeeded: bool)
func update_user_stat(data: Array[BulkStatUpdateData], on_complete: Callable = Callable()):
	# Send request.
	var body: Array[Dictionary]
	for entry in data:
		body.append({
			"userId": entry.user_id,
			"statCode": entry.stat_code,
			"updateStrategy": _stat_update_strategy_to_string[entry.update_strategy],
			"value": entry.value,
		})
	var result: Dictionary = await social.bulk_update_user_stat_item_1("", body)
	
	# Response handler.
	var is_success: bool = result["success"]
	if not is_success:
		push_error("[AccelByteManager] update_user_stat failed: %s" % str(result))
	on_complete.call(is_success)


## Get the local user's ranking from a leaderboard (all-time and cycles).
## on_complete(data: Array[UserLeaderboardRankingData], is_succeeded: bool)
func get_local_user_leaderboard_ranking(leaderboard_code: String, on_complete: Callable = Callable()):
	# Send request.
	var user_id: String = get_user_id()
	var result: Dictionary = await leaderboard.get_user_ranking_public_v3(leaderboard_code, "", user_id)
	
	# Response handler.
	var is_success: bool = result["success"]
	var rankings: Array[UserLeaderboardRankingData]
	if is_success:
		var res_data: Dictionary = result["data"]
		# All-time entry.
		if res_data.has("allTime"):
			var entry = UserLeaderboardRankingData.new()
			entry.point = res_data["allTime"].get("point", 0.0)
			entry.rank = res_data["allTime"].get("rank", 0)
			entry.hidden = res_data["allTime"].get("hidden", false)
			entry.cycle_id = ""
			rankings.append(entry)
		# Cycle entries.
		for cycle in res_data.get("cycles", []):
			var entry = UserLeaderboardRankingData.new()
			entry.point = cycle.get("point", 0.0)
			entry.rank = cycle.get("rank", 0)
			entry.hidden = cycle.get("hidden", false)
			entry.cycle_id = cycle.get("cycleId", "")
			rankings.append(entry)
	elif result["status_code"] == 404:
		# Expected error when player doesn't have any stats yet.
		is_success = true
		var entry = UserLeaderboardRankingData.new()
		entry.point = -1.0
		entry.rank = -1
		entry.hidden = false
		entry.cycle_id = ""
		rankings.append(entry)
	else:
		push_error("[AccelByteManager] get_local_user_leaderboard_ranking failed: %s" % str(result))
	on_complete.call(rankings, is_success)


## Get the all-time leaderboard ranking (top N entries).
## on_complete(data: Array[LeaderboardData], is_succeeded: bool)
func get_alltime_leaderboard(leaderboard_code: String, limit: int, on_complete: Callable = Callable()):
	# Send request.
	var result: Dictionary = await leaderboard.get_all_time_leaderboard_ranking_public_v3(leaderboard_code, "", limit)
	
	# Response handler.
	var is_success: bool = result["success"]
	var entries: Array[LeaderboardData]
	if is_success:
		for item in result["data"].get("data", []):
			entries.append(LeaderboardData.new(
				item.get("point", 0.0),
				item.get("userId", ""),
				item.get("hidden", false)
			))
	else:
		push_error("[AccelByteManager] get_alltime_leaderboard failed: %s" % str(result))
	on_complete.call(entries, is_success)


## Get a weekly/cycle leaderboard ranking (top N entries for a given cycle).
## on_complete(data: Array[LeaderboardData], is_succeeded: bool)
func get_cycle_leaderboard(leaderboard_code: String, cycle_id: String, limit: int, on_complete: Callable = Callable()):
	# Send request.
	var result: Dictionary = await leaderboard.get_current_cycle_leaderboard_ranking_public_v3(cycle_id, leaderboard_code, "", limit)
	
	# Response handler.
	var is_success: bool = result["success"]
	var entries: Array[LeaderboardData]
	if is_success:
		for item in result["data"].get("data", []):
			entries.append(LeaderboardData.new(
				item.get("point", 0.0),
				item.get("userId", ""),
				item.get("hidden", false)
			))
	else:
		push_error("[AccelByteManager] get_cycle_leaderboard failed: %s" % str(result))
	on_complete.call(entries, is_success)
#endregion
