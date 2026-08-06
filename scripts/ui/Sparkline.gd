class_name Sparkline
extends Control
## A tiny history plot.
##
## An idle game lives on the *shape* of the curve, and until now the interface
## only ever showed the current value - which tells you nothing about whether
## the last ten minutes went well. One `draw_polyline` call, redrawn only when
## the data actually changes.

var color := Color("d9a441")
var fill := true

var _values := PackedFloat32Array()
var _last_size := -1
var _last_tail := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, 34)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Hand it the series; it redraws only if something moved.
func set_values(values: PackedFloat32Array) -> void:
	var tail := values[values.size() - 1] if values.size() > 0 else 0.0
	if values.size() == _last_size and is_equal_approx(tail, _last_tail):
		return
	_last_size = values.size()
	_last_tail = tail
	_values = values
	queue_redraw()


func _draw() -> void:
	if _values.size() < 2 or size.x <= 1.0:
		return

	var lo := INF
	var hi := -INF
	for v in _values:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	# A flat line should sit in the middle rather than divide by zero.
	if hi - lo < 0.0001:
		lo -= 1.0
		hi += 1.0

	var n := _values.size()
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var x := size.x * float(i) / float(n - 1)
		var y := size.y - (( _values[i] - lo) / (hi - lo)) * (size.y - 2.0) - 1.0
		pts[i] = Vector2(x, y)

	if fill:
		var poly := pts.duplicate()
		poly.append(Vector2(size.x, size.y))
		poly.append(Vector2(0.0, size.y))
		draw_colored_polygon(poly, Color(color.r, color.g, color.b, 0.16))
	draw_polyline(pts, color, 1.5, true)
	# Mark where the line is now, which is the number the panel is showing.
	draw_circle(pts[n - 1], 2.0, color)
