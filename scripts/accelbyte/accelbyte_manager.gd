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
