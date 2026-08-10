shader_type spatial;

render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D crater_atlas : source_color, filter_linear, repeat_disable;
instance uniform vec2 crater_uv_offset = vec2(0.0);
instance uniform float decal_opacity = 1.0;


void fragment() {
	vec4 crater = texture(crater_atlas, UV * 0.5 + crater_uv_offset);
	ALBEDO = crater.rgb;
	ALPHA = crater.a * decal_opacity;
}
