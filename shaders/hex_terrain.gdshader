shader_type canvas_item;
render_mode unshaded;

// The whole map, as one draw call, on a hexagonal grid.
//
// The map data is still a rectangular 96x64 array - offset ("odd-r") hex
// coordinates, where odd rows are shifted half a hex to the right. That means
// the terrain can stay a single 96x64 texture with one texel per tile, exactly
// as it was when tiles were squares, and the hex shape is decided here at the
// last possible moment.
//
// Drawing hexes as geometry would be one call per visible tile - thousands of
// them at the zooms that make people visible. This is one call at every zoom,
// and it is exact rather than approximate: each fragment works out which hex it
// falls inside and samples that hex's texel.
//
// The camera is isometric, which for a top-down hex field means the vertical
// axis is foreshortened. That is a single divide - the fragment is un-squashed
// before the hex maths and everything downstream is ordinary regular-hex
// geometry.

uniform sampler2D grid : filter_nearest, repeat_disable;
uniform vec2 grid_dims = vec2(96.0, 64.0);
// Hex-space coordinate of this rect's top-left corner, and how much hex-space
// it spans. Set from GDScript so panning and zooming are just these two.
uniform vec2 origin_hex;
uniform vec2 span_hex;
uniform float iso_squash = 0.62;
uniform vec4 void_color : source_color = vec4(0.039, 0.047, 0.059, 1.0);

// Round a fractional cube coordinate to the nearest hex centre. The component
// with the largest rounding error is recomputed from the other two, which is
// what keeps the result on the q + s + r = 0 plane.
vec3 cube_round(vec3 c) {
	vec3 r = round(c);
	vec3 d = abs(r - c);
	if (d.x > d.y && d.x > d.z) {
		r.x = -r.y - r.z;
	} else if (d.y > d.z) {
		r.y = -r.x - r.z;
	} else {
		r.z = -r.x - r.y;
	}
	return r;
}

void fragment() {
	// Where this fragment sits in hex space, with the isometric foreshortening
	// undone so the hexes below are regular.
	vec2 p = origin_hex + UV * span_hex;
	p.y /= iso_squash;

	// Pointy-top hex of width 1.0, so centre-to-corner is 1/sqrt(3).
	float s = 1.0 / sqrt(3.0);
	float q = (sqrt(3.0) / 3.0 * p.x - p.y / 3.0) / s;
	float r = (2.0 / 3.0 * p.y) / s;
	vec3 cube = cube_round(vec3(q, -q - r, r));

	// Axial back to offset odd-r. GLSL's mod is floor-based, so mod(-3,2) == 1
	// and the parity test stays correct for negative rows.
	float row = cube.z;
	float col = cube.x + (row - mod(row, 2.0)) * 0.5;

	if (col < 0.0 || row < 0.0 || col >= grid_dims.x || row >= grid_dims.y) {
		COLOR = void_color;
	} else {
		COLOR = texture(grid, (vec2(col, row) + 0.5) / grid_dims);
	}
}
