extends Node3D

var starting_time: float

func _init() -> void:
	starting_time = Time.get_unix_time_from_system()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	call_deferred(&"after_first_frame")

func after_first_frame():
	var current_time = Time.get_unix_time_from_system()
	print("TIME ELAPSED: ", current_time - starting_time)
