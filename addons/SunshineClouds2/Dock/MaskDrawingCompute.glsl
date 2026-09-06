#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(rgba16f, binding = 0) uniform image2D mask_image;

layout(push_constant, std430) uniform Params {
	vec2 brush_position;
	float brush_radius;
	float brush_sharpness;

	float brush_strength;
    float editingtype;
	float mask_resolution;
    float reserved;

    vec4 brush_value;
} params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.mask_resolution);

    if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

    vec4 current = imageLoad(mask_image, uv);
    float delta = 1.0 - smoothstep(params.brush_sharpness, 1.0, clamp(distance(params.brush_position, uv) / params.brush_radius, 0.0, 1.0));
    switch (int(params.editingtype)) {
        case 0:
            if (params.brush_strength > 0.0){
                current.a = min(current.a + (delta * params.brush_strength), 1.0);
            }
            else{
                current.a = max(current.a - (delta * abs(params.brush_strength)), 0.0);
            }
            break;
        case 1:
            current.rgb = mix(current.rgb, params.brush_value.rgb, delta * params.brush_strength);
            break;
        case 2:
            current = params.brush_value;
            break;
    }
    
    imageStore(mask_image, uv, current);
}