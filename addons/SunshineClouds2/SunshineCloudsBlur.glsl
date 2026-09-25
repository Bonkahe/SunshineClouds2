#[compute]
#version 450

// One pass of the edge-aware cloud blur, a Kawase-style filter over the low-res
// cloud color buffer.
// Run several times, ping-ponging, with a growing tap offset each pass.
//
// Each pass takes the center texel plus four diagonal bilinear taps. A tap's
// weight is how much of its 2x2 bilinear footprint lies on the same surface as
// the center, judged from the geometry distance the clouds were marched against
// (data.a). That keeps cloud color that was marched out to the sky from bleeding
// across a foreground silhouette, and vice versa.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D input_color_image;
layout(binding = 1) uniform sampler2D input_data_image;
layout(rgba32f, binding = 2) uniform writeonly image2D output_color_image;

layout(push_constant, std430) uniform Params {
	vec2 texel_size;
	// Tap offset for this pass in low-res texels, before the per-pixel distance fade.
	float offset;
	// How fast a relative difference in geometry distance rejects a tap.
	float edge_sharpness;
	// View distance at which the blur has faded out entirely.
	float fade_distance;
	float pad0;
	float pad1;
	float pad2;
} params;

float surfaceSimilarity(vec4 depths, float centerDepth, vec4 bilinearWeights){
	vec4 relative = abs(depths - centerDepth) / max(min(depths, vec4(centerDepth)), vec4(1.0));
	vec4 similarity = exp2(-relative * params.edge_sharpness);
	return dot(similarity, bilinearWeights);
}

void main() {
	ivec2 size = textureSize(input_color_image, 0);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	if (uv.x >= size.x || uv.y >= size.y){
		return;
	}

	vec4 centerColor = texelFetch(input_color_image, uv, 0);
	vec4 centerData = texelFetch(input_data_image, uv, 0);
	float centerDepth = centerData.a;

	float offset = params.offset * (1.0 - clamp(centerData.b / params.fade_distance, 0.0, 1.0));
	if (offset <= 0.0){
		imageStore(output_color_image, uv, centerColor);
		return;
	}

	vec2 texelPos = vec2(uv) + 0.5;
	vec4 accum = centerColor;
	float totalWeight = 1.0;

	const vec2 dirs[4] = vec2[4](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));
	for (int i = 0; i < 4; i++){
		vec2 tapPos = texelPos + dirs[i] * offset;
		vec2 tapUV = tapPos * params.texel_size;

		// Gather returns the 2x2 footprint the bilinear fetch below blends, in
		// (i0,j1), (i1,j1), (i1,j0), (i0,j0) order.
		vec2 f = fract(tapPos - 0.5);
		vec4 bilinearWeights = vec4((1.0 - f.x) * f.y, f.x * f.y, f.x * (1.0 - f.y), (1.0 - f.x) * (1.0 - f.y));
		vec4 depths = textureGather(input_data_image, tapUV, 3);

		float weight = surfaceSimilarity(depths, centerDepth, bilinearWeights);
		accum += texture(input_color_image, tapUV) * weight;
		totalWeight += weight;
	}

	imageStore(output_color_image, uv, accum / totalWeight);
}
