extends Control

const GITHUB_REPO = "pgpavlides/feralworld_godot"
const GITHUB_API = "https://api.github.com/repos/" + GITHUB_REPO + "/releases/latest"
const VERSION_FILE = "version.txt"
const GAME_FOLDER = "game"
const GAME_EXE = "MageFights.exe"

@onready var status_label = $LeftPanel/VBox/StatusLabel
@onready var version_label = $LeftPanel/VBox/VersionLabel
@onready var progress_bar = $LeftPanel/VBox/ProgressBar
@onready var play_button = $LeftPanel/VBox/ButtonBox/PlayButton
@onready var update_button = $LeftPanel/VBox/ButtonBox/UpdateButton

var current_version = ""
var latest_version = ""
var download_url = ""
var download_size = 0
var http_check: HTTPRequest
var http_download: HTTPRequest

func _ready():
	play_button.disabled = true
	update_button.disabled = true
	progress_bar.visible = false

	# Load current installed version
	current_version = _load_local_version()
	if current_version != "":
		version_label.text = "Installed: " + current_version
	else:
		version_label.text = "No version installed"

	# Check if game exe exists
	var game_path = OS.get_executable_path().get_base_dir().path_join(GAME_FOLDER).path_join(GAME_EXE)
	if current_version != "" and FileAccess.file_exists(game_path):
		play_button.disabled = false

	# Check for updates
	status_label.text = "Checking for updates..."
	_check_latest_release()

func _check_latest_release():
	http_check = HTTPRequest.new()
	add_child(http_check)
	http_check.request_completed.connect(_on_check_completed)
	var headers = ["User-Agent: FeralWorldLauncher", "Accept: application/vnd.github.v3+json"]
	http_check.request(GITHUB_API, headers)

func _on_check_completed(result, response_code, _headers, body):
	http_check.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var err_msg = "Failed to check for updates\n"
		if result != HTTPRequest.RESULT_SUCCESS:
			err_msg += "Connection error (code " + str(result) + "). Check internet/firewall."
		else:
			err_msg += "HTTP " + str(response_code)
		status_label.text = err_msg
		update_button.disabled = false
		update_button.text = "Retry"
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null:
		status_label.text = "Failed to parse update info"
		return

	latest_version = json.get("tag_name", "")
	var release_name = json.get("name", latest_version)

	# Find the Windows zip asset
	var assets = json.get("assets", [])
	for asset in assets:
		var asset_name = asset.get("name", "")
		if asset_name.ends_with(".zip"):
			download_url = asset.get("browser_download_url", "")
			download_size = asset.get("size", 0)
			break

	if latest_version == "":
		status_label.text = "No releases found. Create a release on GitHub first."
		return

	version_label.text = "Installed: " + (current_version if current_version != "" else "none")
	version_label.text += "  |  Latest: " + latest_version

	if current_version == latest_version:
		status_label.text = "Game is up to date!"
		update_button.disabled = true
		var game_path = OS.get_executable_path().get_base_dir().path_join(GAME_FOLDER).path_join(GAME_EXE)
		if FileAccess.file_exists(game_path):
			play_button.disabled = false
		else:
			status_label.text = "Version matches but game files missing. Click Update."
			update_button.disabled = false
	else:
		if download_url == "":
			status_label.text = "New version available but no download found in release assets."
		else:
			status_label.text = "Update available! " + release_name
			update_button.disabled = false

func _on_update_pressed():
	# If it's a retry, re-check for updates
	if update_button.text == "Retry":
		update_button.text = "Update"
		update_button.disabled = true
		status_label.text = "Checking for updates..."
		_check_latest_release()
		return

	if download_url == "":
		status_label.text = "No download URL available"
		return

	update_button.disabled = true
	play_button.disabled = true
	progress_bar.visible = true
	progress_bar.value = 0
	status_label.text = "Downloading " + latest_version + "..."

	# Download the zip
	http_download = HTTPRequest.new()
	http_download.download_file = OS.get_executable_path().get_base_dir().path_join("update.zip")
	add_child(http_download)
	http_download.request_completed.connect(_on_download_completed)
	var headers = ["User-Agent: FeralWorldLauncher"]
	http_download.request(download_url, headers)

func _process(_delta):
	if http_download and is_instance_valid(http_download) and http_download.get_body_size() > 0:
		var downloaded = http_download.get_downloaded_bytes()
		var total = http_download.get_body_size()
		progress_bar.value = (float(downloaded) / float(total)) * 100.0
		var mb_done = snapped(downloaded / 1048576.0, 0.1)
		var mb_total = snapped(total / 1048576.0, 0.1)
		status_label.text = "Downloading... " + str(mb_done) + " / " + str(mb_total) + " MB"

func _on_download_completed(result, response_code, _headers, _body):
	http_download.queue_free()
	http_download = null

	if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 302):
		status_label.text = "Download failed! (HTTP " + str(response_code) + ")"
		update_button.disabled = false
		progress_bar.visible = false
		return

	progress_bar.value = 100
	status_label.text = "Extracting..."

	# Extract the zip
	var base_dir = OS.get_executable_path().get_base_dir()
	var zip_path = base_dir.path_join("update.zip")
	var game_dir = base_dir.path_join(GAME_FOLDER)

	# Create game directory if it doesn't exist
	DirAccess.make_dir_recursive_absolute(game_dir)

	# Extract zip using ZIPReader
	var zip = ZIPReader.new()
	var err = zip.open(zip_path)
	if err != OK:
		status_label.text = "Failed to open zip file! Error: " + str(err)
		update_button.disabled = false
		progress_bar.visible = false
		return

	var files = zip.get_files()
	for file_path in files:
		# Skip directories
		if file_path.ends_with("/"):
			continue
		var data = zip.read_file(file_path)
		# Remove top-level folder from zip path if present
		var out_path = file_path
		if out_path.contains("/"):
			# Check if there's a common root folder in the zip
			var parts = out_path.split("/", false)
			if parts.size() > 1:
				# Keep relative path from inside the zip
				out_path = "/".join(parts)
		var full_out = game_dir.path_join(out_path)
		# Create subdirectories
		var dir = full_out.get_base_dir()
		DirAccess.make_dir_recursive_absolute(dir)
		# Write file
		var f = FileAccess.open(full_out, FileAccess.WRITE)
		if f:
			f.store_buffer(data)
			f.close()
	zip.close()

	# Delete the zip file
	DirAccess.remove_absolute(zip_path)

	# Save the version
	_save_local_version(latest_version)
	current_version = latest_version

	version_label.text = "Installed: " + current_version + "  |  Latest: " + latest_version
	status_label.text = "Update complete! Ready to play."
	progress_bar.visible = false
	play_button.disabled = false

func _on_play_pressed():
	var game_path = OS.get_executable_path().get_base_dir().path_join(GAME_FOLDER).path_join(GAME_EXE)
	if not FileAccess.file_exists(game_path):
		status_label.text = "Game executable not found! Try updating."
		return
	status_label.text = "Launching game..."
	OS.create_process(game_path, [])
	# Close launcher after a short delay
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()

func _load_local_version() -> String:
	var path = OS.get_executable_path().get_base_dir().path_join(VERSION_FILE)
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			var ver = f.get_as_text().strip_edges()
			f.close()
			return ver
	return ""

func _save_local_version(version: String):
	var path = OS.get_executable_path().get_base_dir().path_join(VERSION_FILE)
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(version)
		f.close()
