shader_type spatial;
//render_mode cull_disabled;


uniform vec3 WindDirection;
uniform float WindSpeed;


group_uniforms Color;
uniform float Roughness : hint_range(-1.0, 2.0) = 0.0;
uniform float Specular : hint_range(-1.0, 2.0) = 0.5;
uniform vec3 HighlightColor : source_color;

group_uniforms Waves;

uniform float WaveHeight = 10.0;
uniform float WaterUVScale = 100.0;
uniform float LargeWaveHeight = 10.0;
uniform float LargeWaterUVScale = 100.0;
uniform float waveBlendPower = 1.0;
uniform float waveBlendSoftness = 1.0;
uniform float NormalMapSampleRange = 1.0;
uniform sampler2D WaveNoise : source_color;
uniform sampler2D WaveNoiseNormalMap : hint_normal;
uniform sampler2D LargeWaveNoise : source_color;
uniform sampler2D LargeWaveNoiseNormalMap : hint_normal;

varying vec2 vertexPosA;
varying vec2 vertexPosB;
varying vec2 vertexPosC;
varying float worldHeightWaveScale;
varying float currentBaseWaveHeight;
varying float currentBaseLargeWaveHeight;

group_uniforms Reflections;
global uniform sampler2D Reflections: repeat_disable;

uniform float ssr_max_travel = 500.0;
uniform int ssr_max_steps : hint_range(4, 128) = 48;
uniform int ssr_refine_steps : hint_range(0, 8) = 5;
uniform float ssr_thickness = 1.0;
uniform float ssr_start_bias : hint_range(0.0, 16.0) = 2.0;
uniform float ssr_jitter : hint_range(0.0, 1.0) = 1.0;
uniform bool ssr_reject_below_surface = true;
uniform float ssr_below_surface_bias = 1.0;

uniform float ssr_sides_edge_fade : hint_range(0.0, 0.5) = 0.15;
uniform float ssr_bottomtop_edge_fade : hint_range(0.0, 0.5) = 0.15;
uniform float ssr_camera_facing_fade : hint_range(0.0, 1.0) = 0.35;
uniform float ssr_travel_fade : hint_range(0.0, 1.0) = 0.35;
uniform float ssr_miss_strength : hint_range(0.0, 1.0) = 1.0;
uniform float ssr_fresnel_strength : hint_range(0.0, 1.0) = 1.0;
uniform float ssr_fresnel_f0 : hint_range(0.0, 1.0) = 0.02;
uniform float ssr_normal_influence : hint_range(0.0, 2.0) = 1.0;

uniform float reflections_blur_distance_fade_min = 0.0;
uniform float reflections_blur_distance_fade_max = 1000.0;
uniform float ReflectionBlurStrength : hint_range(0.0, 10.0) = 0.056;
uniform int ReflectionBlurRadius : hint_range(1, 64) = 12;
uniform float ReflectionMultiplier : hint_range(0.001, 10.0) = 0.5;
uniform float ReflectionPower : hint_range(0.001, 2.0) = 1.0;

float GetWaterHeight(vec2 positionA, vec2 positionB, vec2 positionC){
	return max(texture(WaveNoise, positionA / WaterUVScale).r * currentBaseWaveHeight * (1.0 - waveBlendPower), texture(WaveNoise, positionB / WaterUVScale).r * currentBaseWaveHeight * waveBlendPower) + (texture(LargeWaveNoise, positionC / LargeWaterUVScale).r * currentBaseLargeWaveHeight * worldHeightWaveScale);
}

vec3 GenerateWaterNormal(vec2 positionA, vec2 positionB, vec2 positionC){

	vec3 center = vec3(positionA.x,
		GetWaterHeight(positionA, positionB, positionC),
		positionA.y);

	vec3 left = vec3((positionA.x - NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x - NormalMapSampleRange, positionA.y), vec2(positionB.x - NormalMapSampleRange, positionB.y), vec2(positionC.x - NormalMapSampleRange, positionC.y)),
		positionA.y);

	vec3 right = vec3((positionA.x + NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x + NormalMapSampleRange, positionA.y), vec2(positionB.x + NormalMapSampleRange, positionB.y), vec2(positionC.x + NormalMapSampleRange, positionC.y)),
		positionA.y);

	vec3 up = vec3(positionA.x,
		GetWaterHeight(vec2(positionA.x, positionA.y - NormalMapSampleRange), vec2(positionB.x, positionB.y - NormalMapSampleRange), vec2(positionC.x, positionC.y - NormalMapSampleRange)),
		(positionA.y - NormalMapSampleRange));

	vec3 down = vec3(positionA.x,
		GetWaterHeight(vec2(positionA.x, positionA.y + NormalMapSampleRange), vec2(positionB.x, positionB.y + NormalMapSampleRange), vec2(positionC.x, positionC.y + NormalMapSampleRange)),
		(positionA.y + NormalMapSampleRange));

	vec3 upleft = vec3((positionA.x - NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x - NormalMapSampleRange, positionA.y - NormalMapSampleRange), vec2(positionB.x - NormalMapSampleRange, positionB.y - NormalMapSampleRange), vec2(positionC.x - NormalMapSampleRange, positionC.y - NormalMapSampleRange)),
		(positionA.y - NormalMapSampleRange));

	vec3 upright = vec3((positionA.x + NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x + NormalMapSampleRange, positionA.y - NormalMapSampleRange), vec2(positionB.x + NormalMapSampleRange, positionB.y - NormalMapSampleRange), vec2(positionC.x + NormalMapSampleRange, positionC.y - NormalMapSampleRange)),
		(positionA.y - NormalMapSampleRange));

	vec3 downleft = vec3((positionA.x - NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x - NormalMapSampleRange, positionA.y + NormalMapSampleRange), vec2(positionB.x - NormalMapSampleRange, positionB.y + NormalMapSampleRange), vec2(positionC.x - NormalMapSampleRange, positionC.y + NormalMapSampleRange)),
		(positionA.y + NormalMapSampleRange));

	vec3 downright = vec3((positionA.x + NormalMapSampleRange),
		GetWaterHeight(vec2(positionA.x + NormalMapSampleRange, positionA.y + NormalMapSampleRange), vec2(positionB.x + NormalMapSampleRange, positionB.y + NormalMapSampleRange), vec2(positionC.x + NormalMapSampleRange, positionC.y + NormalMapSampleRange)),
		(positionA.y + NormalMapSampleRange));


	vec3 leftVec = normalize(left - center);
	vec3 rightVec = normalize(right - center);
	vec3 upVec = normalize(up - center);
	vec3 downVec = normalize(down - center);
	vec3 upleftVec = normalize(upleft - center);
	vec3 uprightVec = normalize(upright - center);
	vec3 downleftVec = normalize(downleft - center);
	vec3 downrightVec = normalize(downright - center);


	vec3 finalVector = cross(rightVec,upVec);
	finalVector += cross(upVec, leftVec);
	finalVector += cross(leftVec, downVec);
	finalVector += cross(downVec, rightVec);

	finalVector += cross(uprightVec, upleftVec);
	finalVector += cross(upleftVec, downleftVec);
	finalVector += cross(downleftVec, downrightVec);
	finalVector += cross(downrightVec, uprightVec);

	return normalize(finalVector);
}

vec3 HeightBasedVec3Mix(vec3 colorA, vec3 colorB, float heightA, float heightB, float lerpvalue, float blendSoftness){
	heightA += 1.0 - lerpvalue;
	heightB += lerpvalue;

	float blendValue = max(heightA, heightB) - blendSoftness;

	heightA -= blendValue;
	heightB -= blendValue;

	heightA = max(heightA, 0.0);
	heightB = max(heightB, 0.0);

	colorA *= heightA;
	colorB *= heightB;

	return (colorA + colorB) / (heightA + heightB);
}

vec3 UnpackNormalMap(vec4 rgba)
{
	vec3 n = rgba.xyz * 2.0 - 1.0;
	return n;
}

float quadraticIn(float t) {
	return t * t;
}

float ssr_dither(vec2 pixel, float time) {
	return fract(sin(dot(pixel + fract(time) * 37.0, vec2(12.9898, 78.233))) * 43758.5453);
}

float ssr_edge_fade(vec2 uv) {
	vec2 fade = max(vec2(ssr_sides_edge_fade, ssr_bottomtop_edge_fade), vec2(1e-4));
	vec2 inner = smoothstep(vec2(0.0), fade, uv) * smoothstep(vec2(0.0), fade, vec2(1.0) - uv);
	return clamp(inner.x * inner.y, 0.0, 1.0);
}

vec2 ssr_screen_exit_uv(vec2 uv_start, vec2 uv_end) {
	vec2 delta = uv_end - uv_start;
	float exit_t = 1.0;
	if (abs(delta.x) > 1e-6) {
		exit_t = min(exit_t, max(-uv_start.x / delta.x, (1.0 - uv_start.x) / delta.x));
	}
	if (abs(delta.y) > 1e-6) {
		exit_t = min(exit_t, max(-uv_start.y / delta.y, (1.0 - uv_start.y) / delta.y));
	}
	return clamp(uv_start + delta * max(exit_t, 0.0), vec2(0.0), vec2(1.0));
}

vec3 ssr_view_position_at(vec3 q_start, vec3 q_end, float inv_w_start, float inv_w_end, float t) {
	float inv_w = mix(inv_w_start, inv_w_end, t);
	return mix(q_start, q_end, t) / max(inv_w, 1e-12);
}

struct SSRResult {
	vec2 uv;
	vec2 screen_dir;
	float confidence;
};

SSRResult trace_ssr(vec3 ray_origin_view, vec3 ray_direction_view, float dither,
		mat4 proj_m, mat4 inv_view_m, float water_height_world) {
	SSRResult result;
	result.uv = vec2(0.0);
	result.screen_dir = vec2(0.0, 1.0);
	result.confidence = 0.0;

	vec4 clip_start = proj_m * vec4(ray_origin_view, 1.0);
	if (clip_start.w <= 0.0) {
		return result;
	}

	vec3 ray_end_view = ray_origin_view + ray_direction_view * ssr_max_travel;
	vec4 clip_end = proj_m * vec4(ray_end_view, 1.0);

	float w_min = max(clip_start.w * 0.001, 1e-4);
	if (clip_end.w < w_min) {
		float clip_t = clamp((w_min - clip_start.w) / (clip_end.w - clip_start.w), 0.0, 1.0);
		ray_end_view = mix(ray_origin_view, ray_end_view, clip_t);
		clip_end = mix(clip_start, clip_end, clip_t);
	}

	vec2 uv_start = clip_start.xy / clip_start.w * 0.5 + 0.5;
	vec2 uv_end = clip_end.xy / clip_end.w * 0.5 + 0.5;
	vec2 uv_delta = uv_end - uv_start;

	float pixel_length = length(uv_delta * vec2(textureSize(Reflections, 0)));

	result.uv = ssr_screen_exit_uv(uv_start, uv_end);
	if (pixel_length < 2.0) {
		result.confidence = ssr_edge_fade(result.uv) * ssr_miss_strength;
		return result;
	}
	result.screen_dir = uv_delta / max(length(uv_delta), 1e-6);

	float inv_w_start = 1.0 / clip_start.w;
	float inv_w_end = 1.0 / clip_end.w;
	vec3 q_start = ray_origin_view * inv_w_start;
	vec3 q_end = ray_end_view * inv_w_end;

	int step_count = int(clamp(pixel_length, 4.0, float(ssr_max_steps)));
	float step_t = 1.0 / float(step_count);

	float t_bias = clamp(ssr_start_bias / pixel_length, 0.0, step_t);
	float t_jitter = dither * ssr_jitter;

	float t_previous = t_bias;
	float radial_previous = length(ssr_view_position_at(q_start, q_end, inv_w_start, inv_w_end, t_previous));

	bool hit = false;
	bool crossed_surface = false;
	for (int i = 1; i <= step_count; i++) {
		float t = min(t_bias + step_t * (float(i - 1) + t_jitter), 1.0);
		vec2 uv = mix(uv_start, uv_end, t);
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
			break;
		}

		float radial = length(ssr_view_position_at(q_start, q_end, inv_w_start, inv_w_end, t));
		float scene_radial = texture(Reflections, uv).a;

		if (scene_radial > 0.0 && radial > scene_radial) {
			float span = max(radial - radial_previous, 0.0);
			if (radial - scene_radial > max(ssr_thickness, span)) {
				if (!crossed_surface) {
					result.uv = uv;
				}
				break;
			}

			float t_low = t_previous;
			float t_high = t;
			for (int refine = 0; refine < ssr_refine_steps; refine++) {
				float t_mid = (t_low + t_high) * 0.5;
				vec2 uv_mid = mix(uv_start, uv_end, t_mid);
				float radial_mid = length(ssr_view_position_at(q_start, q_end, inv_w_start, inv_w_end, t_mid));
				if (radial_mid > texture(Reflections, uv_mid).a) {
					t_high = t_mid;
				} else {
					t_low = t_mid;
				}
			}

			if (ssr_reject_below_surface) {
				vec3 hit_position = ssr_view_position_at(q_start, q_end, inv_w_start, inv_w_end, t_high);
				if ((inv_view_m * vec4(hit_position, 1.0)).y < water_height_world - ssr_below_surface_bias) {
					crossed_surface = true;
					t_previous = t;
					radial_previous = radial;
					continue;
				}
			}

			result.uv = mix(uv_start, uv_end, t_high);
			result.confidence = ssr_edge_fade(result.uv)
				* (1.0 - smoothstep(1.0 - max(ssr_travel_fade, 1e-4), 1.0, t_high));
			hit = true;
			break;
		}

		t_previous = t;
		radial_previous = radial;
	}

	if (!hit) {
		result.confidence = ssr_edge_fade(result.uv) * ssr_miss_strength;
	}

	return result;
}

vec3 ssr_directional_blur(vec2 uv, vec2 direction, float radius, int quality) {
	vec3 color = texture(Reflections, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
	if (radius <= 0.0 || quality <= 0) {
		return color;
	}

	float total_weight = 1.0;
	float step_size = radius / float(quality);
	for (int i = 1; i <= quality; i++) {
		vec2 offset = direction * (step_size * float(i));
		float weight = 1.0 - quadraticIn(float(i) / float(quality + 1));
		color += texture(Reflections, clamp(uv + offset, vec2(0.0), vec2(1.0))).rgb * weight;
		color += texture(Reflections, clamp(uv - offset, vec2(0.0), vec2(1.0))).rgb * weight;
		total_weight += weight * 2.0;
	}
	return color / total_weight;
}

void vertex() {

	vec3 vertexWorldpos1 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	float cameraVertexDistance = length(MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec2 vertexWorldPos = vertexWorldpos1.xz;

	worldHeightWaveScale = smoothstep(0.0, 200.0, vertexWorldpos1.y);

	vertexPosA = vertexWorldPos + (WindDirection.xz * -1.0 * vec2(0.05, 0.1) * TIME * WindSpeed * 10.0);
	vertexPosB = vertexWorldPos + (WindDirection.xz * -1.0 * vec2(-0.2, -0.05) * TIME * WindSpeed * 4.0);

	currentBaseWaveHeight = WaveHeight * smoothstep(100.0, 50.0, cameraVertexDistance);
	currentBaseLargeWaveHeight = LargeWaveHeight * smoothstep(2000.0, 100.0, cameraVertexDistance);

	vertexPosC = vertexWorldPos + (WindDirection.xz * -1.0 * TIME * WindSpeed * 2.0);
	VERTEX.y += GetWaterHeight(vertexPosA, vertexPosB, vertexPosC);
}


void fragment() {

	ROUGHNESS = Roughness;
	SPECULAR = Specular;
	ALBEDO = HighlightColor;

	if(FRONT_FACING) {
		vec3 normalMapA = texture(WaveNoiseNormalMap, vertexPosA / WaterUVScale).rgb;
		float heightMapA = texture(WaveNoise, vertexPosA / WaterUVScale).r;
		vec3 normalMapB = texture(WaveNoiseNormalMap, vertexPosB / WaterUVScale).rgb;
		float heightMapB = texture(WaveNoise, vertexPosB / WaterUVScale).r;
		vec3 normalMapC = texture(LargeWaveNoiseNormalMap, vertexPosC / LargeWaterUVScale).rgb;
		float heightMapC = texture(LargeWaveNoise, vertexPosC / LargeWaterUVScale).r;

		vec3 resultNormalMap = HeightBasedVec3Mix(normalMapA, normalMapB, heightMapA, heightMapB, waveBlendPower, waveBlendSoftness);
		NORMAL_MAP = HeightBasedVec3Mix(resultNormalMap, normalMapC, max(heightMapA, heightMapB), heightMapC, waveBlendPower - 0.1, waveBlendSoftness);

		NORMAL = normalize((VIEW_MATRIX * vec4(GenerateWaterNormal(vertexPosA, vertexPosB, vertexPosC), 0.0)).xyz);

		vec3 ssr_n = NORMAL;
		vec3 ssr_t = TANGENT - ssr_n * dot(ssr_n, TANGENT);
		ssr_t = (dot(ssr_t, ssr_t) > 1e-8) ? normalize(ssr_t) : ssr_t;
		vec3 ssr_b = BINORMAL - ssr_n * dot(ssr_n, BINORMAL) - ssr_t * dot(ssr_t, BINORMAL);
		ssr_b = (dot(ssr_b, ssr_b) > 1e-8) ? normalize(ssr_b) : ssr_b;

		vec3 ssr_tangent_normal = UnpackNormalMap(vec4(NORMAL_MAP, 1.0));
		ssr_tangent_normal.xy *= ssr_normal_influence;
		vec3 ssr_normal = ssr_t * ssr_tangent_normal.x + ssr_b * ssr_tangent_normal.y + ssr_n * ssr_tangent_normal.z;
		ssr_normal = (dot(ssr_normal, ssr_normal) > 1e-8) ? normalize(ssr_normal) : ssr_n;

		vec3 view_to_camera = normalize(VIEW);
		vec3 reflect_vector_view_space = normalize(reflect(-view_to_camera, ssr_normal));

		SSRResult ssr = trace_ssr(VERTEX, reflect_vector_view_space, ssr_dither(FRAGCOORD.xy, TIME),
			PROJECTION_MATRIX, INV_VIEW_MATRIX, (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y);

		float toward_camera = clamp(dot(reflect_vector_view_space, view_to_camera), 0.0, 1.0);
		float facing_fade = 1.0 - smoothstep(0.0, max(ssr_camera_facing_fade, 1e-4), toward_camera);

		float blur_fade_max = max(reflections_blur_distance_fade_max, reflections_blur_distance_fade_min + 1e-4);
		float blurStrength = smoothstep(reflections_blur_distance_fade_min, blur_fade_max, length(VERTEX)) * ReflectionBlurStrength;
		vec3 resulting_color = ssr_directional_blur(ssr.uv, ssr.screen_dir, blurStrength, ReflectionBlurRadius);
		resulting_color = pow(max(resulting_color * ReflectionMultiplier, vec3(0.0)), vec3(ReflectionPower));

		float schlick = ssr_fresnel_f0 + (1.0 - ssr_fresnel_f0)
			* pow(1.0 - clamp(dot(ssr_normal, view_to_camera), 0.0, 1.0), 5.0);
		float reflection_weight = clamp(ssr.confidence * facing_fade * mix(1.0, schlick, ssr_fresnel_strength), 0.0, 1.0);

		EMISSION += clamp(resulting_color * reflection_weight, vec3(0.0), vec3(1.0));
	}
	else{
		ROUGHNESS = 1.0;
	}
	ALPHA = 1.0;
}
