class_name StartAndFinishLine
extends Node3D

@export var _first_area: Area3D
@export var _second_area: Area3D
@export var _spawns: Array[Marker3D]

signal vehicle_passed_finish_line(id: int)
signal vehicle_reversed_finish_line(id: int)


func _ready() -> void:
	_first_area.body_entered.connect(Callable(self, "_on_body_entered_first_area"))
	_second_area.body_entered.connect(Callable(self, "_on_body_entered_second_area"))


func get_spawn_global_transform(index: int) -> Transform3D:
	var final_index = posmod(index, _spawns.size())
	return _spawns[final_index].global_transform


func _on_body_entered_first_area(body: Node3D):
	# Assume physics body will always be directly under Vehicle node.
	var vehicle = body.get_parent_node_3d() as Vehicle
	if vehicle == null:
		return
	
	for body_on_second in _second_area.get_overlapping_bodies():
		var vehicle_on_second = body_on_second.get_parent_node_3d() as Vehicle
		if vehicle == vehicle_on_second:
			# Vehicle is detected entering first area when already inside of second area.
			# Vehicle is going through the line in reverse.
			vehicle_reversed_finish_line.emit(vehicle.name)


func _on_body_entered_second_area(body: Node3D):
	# Assume physics body will always be directly under Vehicle node.
	var vehicle = body.get_parent_node_3d() as Vehicle
	if vehicle == null:
		return
	
	for body_on_first in _first_area.get_overlapping_bodies():
		var vehicle_on_first = body_on_first.get_parent_node_3d() as Vehicle
		if vehicle == vehicle_on_first:
			# Vehicle is detected entering second area when already inside of first area.
			# Vehicle is going through the line in forward.
			vehicle_passed_finish_line.emit(vehicle.name)
