extends Node

var sdk: AccelByteSDKWrapper

# Auth
var iam: IamService


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
	
	# Login and show notification.
	# Login username if `-username <email/username>` and `-password <password>` launch param are provided.
	# Use device ID otherwise.
	UiManager.push_toast("Logging in...", true)
	var args = OS.get_cmdline_args()
	var username_idx = args.find("-username")
	var password_idx = args.find("-password")
	var on_completed = func(succeeded: bool):
		UiManager.clear_persistent()
		UiManager.push_toast("Login succeeded" if succeeded else "Login Failed")
		UiManager.label_id.text = get_user_id()
	if username_idx != -1 and password_idx != -1 and username_idx + 1 < args.size() and password_idx + 1 < args.size():
		login_username(args[username_idx + 1], args[password_idx + 1], on_completed)
	else:
		login_device_id(on_completed)


func _exit_tree() -> void:
	logout()
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
