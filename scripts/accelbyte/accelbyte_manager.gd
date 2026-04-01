extends Node

var sdk: AccelByteSDKWrapper

# Auth
var iam: IamService


#region Overrides
func _ready():
	# SDK init
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
	
	# Login and show notification
	UiManager.push_toast("Logging in...", true)
	login_device_id(
		func(succeeded: bool):
			UiManager.clear_persistent()
			UiManager.push_toast(
				"Login succeeded" if succeeded else "Login Failed"
			)
	)


func _exit_tree() -> void:
	logout()
#endregion


#region Auth
func login_device_id(completed: Callable = Callable()): # completed(succeeded)
	iam = sdk.get_service(IamService)
	var device_id: String = OS.get_unique_id()
	var result: Dictionary = await iam.platform_token_grant_v4("device", "", "", "", "", true, device_id)

	if result.get("success", false):
		# Tokens are automatically stored by the SDK
		completed.call(true)
	else:
		push_error("[AccelByteManager] Device ID login failed: %s" % str(result))
		completed.call(false)


func logout(completed: Callable = Callable()): # completed(succeeded):
	var result: Dictionary = await iam.logout()
	if result.get("success", false):
		# Tokens are automatically stored by the SDK
		completed.call(true)
	else:
		push_error("[AccelByteManager] Logout failed: %s" % str(result))
		completed.call(false)
#endregion
