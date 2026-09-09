#[compute]
#version 450
#define PI 3.141592
#define ABSORPTION_COEFFICIENT 0.9
#define HISTORY_CLAMP_STRENGTH 0.0
#define NEIGHBORHOOD_WIDEN 1.0
#define SUBPIXEL_JITTER 1.0
#define CLAMP_RELAX_PIXELS 0.5
#define OCCLUSION_BREAK_SLACK 1.5
#define CLOUD_OCCLUSION_MIN_DECAY 0.2
#define HISTORY_PIXEL_TOLERANCE 1.0
#define REBUILD_PIXEL_TOLERANCE 2.0
#define GOLDEN_RATIO_FRACT 0.6180339887498949

#include "./CloudsInc.comp"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, binding = 0) uniform image2D output_data_image;
layout(rgba32f, binding = 1) uniform image2D output_color_image;

layout(rgba32f, binding = 2) uniform image2D accum_1A_image;
layout(rgba32f, binding = 3) uniform image2D accum_1B_image;

layout(rgba32f, binding = 4) uniform image2D accum_2A_image;
layout(rgba32f, binding = 5) uniform image2D accum_2B_image;

layout(binding = 6) uniform sampler2D depth_image;
layout(binding = 7) uniform sampler2D extra_large_noise;
layout(binding = 8) uniform sampler3D large_noise;
layout(binding = 9) uniform sampler3D noise_medium;
layout(binding = 10) uniform sampler3D noise_small;
layout(binding = 11) uniform sampler3D curl_noise;
layout(binding = 13) uniform sampler2D heightmask;

layout(binding = 14) uniform uniformBuffer {
	GenericData data;
} genericData;

layout(binding = 15) uniform LightsBuffer {
	DirectionalLight directionalLights[4];
	PointLight pointLights[128];
	PointEffector pointEffectors[64];
};

layout(binding = 16, std430) restrict buffer SamplePointsBuffer {
	vec4 SamplePoints[32];
};

layout(binding = 17, std140) uniform SceneDataBlock {
	CameraData data;
	CameraData prev_data;
} scene_data_block;

// layout(push_constant, std430) uniform Params {
// 	vec2 raster_size;
// 	float large_noise_scale;
// 	float medium_noise_scale;

// 	float time;
// 	float cloud_coverage;
// 	float cloud_density;
// 	float small_noise_strength;

// 	float cloud_lighting_power;
// 	float accumilation_decay;
// 	vec2 cameraRotation;

const int BayerFilter16[16] =
{
    0, 8, 2, 10,
    12, 4, 14, 6,
    3, 11, 1, 9,
    15, 7, 13, 5
};
const int BayerFilter4[4] =
{
    0, 1,
    3, 2,
};

const mat4 bayer_matrix = mat4(
    vec4(00.0 / 16.0, 12.0 / 16.0, 03.0 / 16.0, 15.0 / 16.0),
    vec4(08.0 / 16.0, 04.0 / 16.0, 11.0 / 16.0, 07.0 / 16.0),
    vec4(02.0 / 16.0, 14.0 / 16.0, 01.0 / 16.0, 13.0 / 16.0),
    vec4(10.0 / 16.0, 06.0 / 16.0, 09.0 / 16.0, 05.0 / 16.0));

float quadraticOut(float t) {
  return -t * (t - 2.0);
}

float quadraticIn(float t) {
  return t * t;
}

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 hash33(vec3 p3){
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

float get_dither_value(vec2 pixel) {
    int x = int(pixel.x - 4.0 * floor(pixel.x / 4.0));
    int y = int(pixel.y - 4.0 * floor(pixel.y / 4.0));
    return bayer_matrix[x][y];
}

float remap(float value, float min1, float max1, float min2, float max2) {
  return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
}

float BeersLaw (float dist, float absorption) {
  return exp(-dist * absorption);
}

float Powder (float dist, float absorption) {
  return 1.0 - exp(-dist * absorption * 2.0);
}

float HenyeyGreenstein(float g, float costh)
{
    return (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * costh, 3.0/2.0));
}

bool renderBayer(ivec2 fragCoord, int framecount)
{
	//int BAYER = 16;
    //int index = framecount % BAYER;
    
    return (fragCoord.x + 4 * fragCoord.y) % 16 == BayerFilter16[framecount];
}

float sampleEffectorAdditive(vec3 worldPosition) {
	float effectorAdditive = 0.0;
	for (int i = 0; i < int(genericData.data.pointEffectorCount); i++) {
		float effectorDistance = distance(pointEffectors[i].position, worldPosition);
		if (effectorDistance < pointEffectors[i].radius){
			effectorAdditive += mix(pointEffectors[i].power, 0.0, effectorDistance / pointEffectors[i].radius);
		}
	}
	return effectorAdditive;
}

float sampleScene(
	vec3 largeNoisePos, 
	vec3 mediumNoisePos, 
	vec3 smallNoisePos, 
	vec3 worldPosition, 
	float cloudceiling, 
	float cloudfloor, 
	float extralargeNoiseValue,
	float largenoisescale, 
	float mediumnoisescale, 
	float smallnoisescale, 
	float coverage, 
	float smallscalePower, 
	float curlPower, 
	float lod, 
	bool ambientsample)
	{
	float clampedWorldHeight = remap(worldPosition.y, cloudfloor, cloudceiling, 0.0, 1.0);
	vec4 gradientSample = texture(heightmask, vec2(clampedWorldHeight, 0.5)).rgba;
	
	float edgeFade = min(smoothstep(0.0, 0.1, clampedWorldHeight), smoothstep(1.0, 0.9, clampedWorldHeight));

	if (edgeFade <= 0.0){
		return 0.0;
	}

	float extraLargeShape = extralargeNoiseValue * gradientSample.b;

	vec3 smallShapeUV = (worldPosition - smallNoisePos) / smallnoisescale;

	float curlHeightSample = (1.0 - gradientSample.a);

	float effectorAdditive = 0.0;
	vec2 WindDirection = genericData.data.WindDirection;
	vec3 windVector = vec3(WindDirection.x, 0.0, WindDirection.y);
	worldPosition += windVector * genericData.data.windSweptPower * quadraticIn(1.0 - clamp(clampedWorldHeight / genericData.data.windSweptRange, 0.0, 1.0));

	if (lod > 0.0){
		effectorAdditive = sampleEffectorAdditive(worldPosition) * edgeFade;

		if (!ambientsample && curlHeightSample > 0.0 && min(curlPower, lod) > 0.5){

			float curlLod = remap(lod, 0.5, 1.0, 0.0, 1.0);
			float curlStrength = curlPower * curlHeightSample * curlLod;
			vec3 curlWindBias = windVector * 0.9;
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + curlWindBias) * curlStrength;
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + curlWindBias) * curlStrength;
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + curlWindBias) * curlStrength;

			clampedWorldHeight = remap(worldPosition.y, cloudfloor, cloudceiling, 0.0, 1.0);
			gradientSample = texture(heightmask, vec2(clampedWorldHeight, 0.5)).rgba;
		}
	}

	float largeShape = texture(large_noise, (worldPosition - largeNoisePos) / largenoisescale).r * extraLargeShape;
	largeShape = smoothstep(coverage , coverage - 0.1, 1.0 - (largeShape * gradientSample.r)) + max(effectorAdditive, 0.0);

	if (largeShape <= 0.0){
		return 0.0;
	}

	float smallShape = texture(noise_small, smallShapeUV).r;
	vec4 mediumShapes = texture(noise_medium, (worldPosition - mediumNoisePos) / mediumnoisescale).rgba;
	float mediumshape = 1.0 - mediumShapes.b;
	smallShape = smallShape * gradientSample.g * pow((1.0 - mediumshape), smallscalePower);
	
	float shape = mediumshape + max(effectorAdditive, 0.0);
	shape = clamp(remap(shape, 1.0 - largeShape, 1.0, 0.0, 1.0), 0.0, 1.0);
	shape = clamp(remap(shape, smallShape, 1.0, 0.0, 1.0), 0.0, 1.0);
	shape += min(effectorAdditive, 0.0);

	return clamp((shape * edgeFade), 0.0, 1.0);
}

float sampleSceneCoarse(
	vec3 largeNoisePos, 
	vec3 worldPosition, 
	float cloudceiling, 
	float cloudfloor, 
	float extralargeNoiseValue,
	float largenoisescale, 
	float coverage,
	float lod)
	{
	float clampedWorldHeight = remap(worldPosition.y, cloudfloor, cloudceiling, 0.0, 1.0);
	vec4 gradientSample = texture(heightmask, vec2(clampedWorldHeight, 0.5)).rgba;

	float edgeFade = min(smoothstep(0.0, 0.1, clampedWorldHeight), smoothstep(1.0, 0.9, clampedWorldHeight));
	float extraLargeShape = extralargeNoiseValue * gradientSample.b;

	float effectorAdditive = 0.0;
	vec2 WindDirection = genericData.data.WindDirection;
	worldPosition += vec3(WindDirection.x, 0.0, WindDirection.y) * genericData.data.windSweptPower * quadraticIn(1.0 - clamp(clampedWorldHeight / genericData.data.windSweptRange, 0.0, 1.0));

	if (lod > 0.0){
		effectorAdditive = sampleEffectorAdditive(worldPosition) * edgeFade;
	}

	float largeShape = texture(large_noise, (worldPosition - largeNoisePos) / largenoisescale).r * extraLargeShape;
	largeShape = smoothstep(coverage , coverage - 0.1, 1.0 - (largeShape * gradientSample.r)) + max(effectorAdditive, 0.0);

	float shape = largeShape + effectorAdditive;
	return clamp((shape * edgeFade), 0.0, 1.0);
}

float sampleLighting(
	int stepCount, 
	vec3 worldPosition,
	vec3 extralargeNoisePos, 
	vec3 largeNoisePos, 
	vec3 mediumNoisePos, 
	vec3 smallNoisePos, 
	vec3 sunDirection,
	float densityMultiplier,
	float sunUpWeight, 
	float stepDistance,  
	float cloudceiling, 
	float cloudfloor, 
	float extralargenoisescale,
	float largenoisescale, 
	float mediumnoisescale, 
	float smallnoisescale, 
	float coverage, 
	float smallscalePower, 
	float curlPower, 
	float lod,
	float ditherOffset)
	{
	float density = 0.0;
	float stepCountFloat = max(float(stepCount) * lod, 2.0);
	float actualDistance = mix(stepDistance * 4.0, stepDistance, lod);

	
	float marchDistance = actualDistance;
	if (abs(sunDirection.y) > 0.0001){
		float slabEdge = sunDirection.y > 0.0 ? cloudceiling : cloudfloor;
		marchDistance = min(marchDistance, max((slabEdge - worldPosition.y) / sunDirection.y, 0.0));
	}

	if (marchDistance <= 0.0){
		return 0.0;
	}

	float eachShortStep = marchDistance / float(stepCount);
	float sunUpValue = 1.0 - sunUpWeight;
	
	float fullSpan = actualDistance - actualDistance / float(stepCount);
	float weightNormalizer = 1.0 / max(fullSpan, 0.0001);

	float heightGradient = 0.0;
	float thisDensity = 0.0;
	float segmentStart = eachShortStep;

	
	float jitterWidth = clamp((stepCountFloat - 2.0) * 0.25, 0.0, 1.0);

	vec3 curPos = worldPosition;
	for (float i = 0.0; i < stepCountFloat; i++) {
		float segmentEnd = mix(eachShortStep, marchDistance, clamp(quadraticOut((i + 1.0) / stepCountFloat), 0.0, 1.0));
		float eachStepWeight = (segmentEnd - segmentStart) * weightNormalizer;

		
		float stepDither = fract(ditherOffset + i * GOLDEN_RATIO_FRACT);
		curPos = worldPosition + sunDirection * mix(segmentStart, segmentEnd, mix(0.5, stepDither, jitterWidth));
		segmentStart = segmentEnd;

		heightGradient = remap(curPos.y, cloudfloor, cloudceiling, 0.0, 1.0);
		heightGradient = clamp(smoothstep(sunUpValue - 0.1, sunUpValue, heightGradient), 0.0, 1.0);
		float extraLargeShape = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoisescale).a;

		thisDensity = sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, extraLargeShape, largenoisescale, mediumnoisescale, smallnoisescale, coverage, smallscalePower, curlPower, lod, true) * densityMultiplier;
		density += eachStepWeight * mix(1.0, thisDensity, heightGradient);

		if (density >= 1.0){
			break;
		}
	}

	return density;
}

float sampleAO(
	vec3 extralargeNoisePos,
	vec3 largeNoisePos, 
	vec3 mediumNoisePos, 
	vec3 smallNoisePos, 
	vec3 worldPosition, 
	float lightingSampleRange, 
	float cloudceiling, 
	float cloudfloor,
	float extralargenoisescale,
	float largenoisescale, 
	float mediumnoisescale, 
	float smallnoisescale, 
	float coverage, 
	float smallscalePower, 
	float curlPower, 
	float lod)
	{
	vec3 samplePos = worldPosition;
	samplePos.y += lightingSampleRange * 0.5;
	samplePos.y += lightingSampleRange * (rand(samplePos.xz) * 2.0 - 1.0);
	samplePos.x += lightingSampleRange * (rand(samplePos.zy) * 2.0 - 1.0);
	samplePos.z += lightingSampleRange * (rand(samplePos.yx) * 2.0 - 1.0);

	float extraLargeShape = texture(extra_large_noise, (samplePos.xz - extralargeNoisePos.xz) / extralargenoisescale).a;
	return sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, samplePos, cloudceiling, cloudfloor, extraLargeShape, largenoisescale, mediumnoisescale, smallnoisescale, coverage, smallscalePower, curlPower, lod, true);
}

#define CLOUD_SHADOW_STRENGTH 1.0
#define CLOUD_SHADOW_MAX_SLANT 3.0
#define CLOUD_SHADOW_LOCAL_DISTANCE 5000.0
#define GEOMETRY_SHADOW_CLOUD_HIDE_START 0.95
#define GEOMETRY_SHADOW_DISTANCE_PIN_FADE 0.2

float cloudSunShadow(
	vec3 startPos,
	vec3 sunDirection,
	vec3 extralargeNoisePos,
	vec3 largeNoisePos,
	vec3 mediumNoisePos,
	vec3 smallNoisePos,
	float extralargenoisescale,
	float largenoisescale,
	float mediumnoisescale,
	float smallnoisescale,
	float cloudfloor,
	float cloudceiling,
	float coverage,
	float smallscalePower,
	float curlPower,
	float densityMultiplier,
	float sharpness,
	float referenceStep,
	float ditherOffset)
	{
	if (sunDirection.y <= 0.001){
		return 1.0;
	}

	float toFloor = (cloudfloor - startPos.y) / sunDirection.y;
	float toCeiling = (cloudceiling - startPos.y) / sunDirection.y;
	float enterDistance = max(min(toFloor, toCeiling), 0.0);
	float exitDistance = max(toFloor, toCeiling);

	if (exitDistance <= enterDistance){
		return 1.0;
	}

	float deckThickness = max(cloudceiling - cloudfloor, 1.0);
	exitDistance = min(exitDistance, enterDistance + deckThickness * CLOUD_SHADOW_MAX_SLANT);

	int shadowSteps = max(int(genericData.data.cloud_shadow_steps), 1);
	float stepSize = (exitDistance - enterDistance) / float(shadowSteps);
	float opticalDepth = 0.0;

	for (int i = 0; i < shadowSteps; i++){
		vec3 curPos = startPos + sunDirection * (enterDistance + (float(i) + ditherOffset) * stepSize);
		float maskSample = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoisescale).a;
		float sampled = sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, maskSample, largenoisescale, mediumnoisescale, smallnoisescale, coverage, smallscalePower, curlPower, 1.0, true);
		opticalDepth += pow(max(sampled * densityMultiplier, 0.0), sharpness);
	}

	opticalDepth *= stepSize / max(referenceStep, 1.0);
	return exp(-opticalDepth * CLOUD_SHADOW_STRENGTH);
}

vec3 cameraRayDirection(vec2 screenUV){
	vec4 clipPos = vec4(screenUV * 2.0 - 1.0, 0.0, 1.0);
	vec4 viewPos = scene_data_block.data.inv_projection_matrix * clipPos;
	viewPos.xyz /= viewPos.w;
	return normalize(mat3(scene_data_block.data.main_cam_inv_view_matrix) * normalize(viewPos.xyz));
}

shared vec4 s_tileColor[64];
shared vec4 s_tileDistance[64];
shared float s_tileAnchor[64];

float historyAnchorDisparity(vec4 storedColor, vec4 storedData){
	float alpha = clamp(storedColor.a, 0.0, 1.0);
	return alpha / max(storedData.b, 1.0) + (1.0 - alpha) / max(storedData.a, 1.0);
}

void resolveHistory(
	vec4 c00, vec4 c10, vec4 c01, vec4 c11,
	vec4 d00, vec4 d10, vec4 d01, vec4 d11,
	vec2 frac, float expectedDisparity, float pixelScale, float tolerance,
	out vec4 outColor, out vec4 outData, out float confidence)
{
	float b00 = (1.0 - frac.x) * (1.0 - frac.y);
	float b10 = frac.x * (1.0 - frac.y);
	float b01 = (1.0 - frac.x) * frac.y;
	float b11 = frac.x * frac.y;

	float far = tolerance * 3.0;
	float a00 = 1.0 - smoothstep(tolerance, far, abs(historyAnchorDisparity(c00, d00) - expectedDisparity) * pixelScale);
	float a10 = 1.0 - smoothstep(tolerance, far, abs(historyAnchorDisparity(c10, d10) - expectedDisparity) * pixelScale);
	float a01 = 1.0 - smoothstep(tolerance, far, abs(historyAnchorDisparity(c01, d01) - expectedDisparity) * pixelScale);
	float a11 = 1.0 - smoothstep(tolerance, far, abs(historyAnchorDisparity(c11, d11) - expectedDisparity) * pixelScale);

	float w00 = b00 * a00;
	float w10 = b10 * a10;
	float w01 = b01 * a01;
	float w11 = b11 * a11;
	float total = w00 + w10 + w01 + w11;

	confidence = clamp(total, 0.0, 1.0);

	if (total > 1e-5){
		float inv = 1.0 / total;
		outColor = (c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11) * inv;
		outData  = (d00 * w00 + d10 * w10 + d01 * w01 + d11 * w11) * inv;
	}
	else{
		outColor = mix(mix(c00, c10, frac.x), mix(c01, c11, frac.x), frac.y);
		outData  = mix(mix(d00, d10, frac.x), mix(d01, d11, frac.x), frac.y);
		confidence = 0.0;
	}
}

void blendAccumulation(
	vec4 lightColor,
	vec4 currentDistances,
	vec4 spatialColor,
	vec4 spatialDistance,
	float historyConfidence,
	float accumdecay,
	float travelspeed,
	float expectedPrevGeometry,
	bool hardReset,
	inout vec4 accumColor,
	inout vec4 accumData)
{
	if (hardReset){
		accumColor = spatialColor;
		accumData.rgb = spatialDistance.rgb;
		accumData.a = currentDistances.a;
		return;
	}

	vec4 historyColor = mix(spatialColor, accumColor, historyConfidence);
	vec4 historyData = accumData;
	historyData.rgb = mix(spatialDistance.rgb, accumData.rgb, historyConfidence);

	float surfaceTransmittance = 1.0 - min(clamp(lightColor.a, 0.0, 1.0), clamp(historyColor.a, 0.0, 1.0));
	float occlusionBreak = surfaceTransmittance * smoothstep(OCCLUSION_BREAK_SLACK, OCCLUSION_BREAK_SLACK + 1.0, abs(expectedPrevGeometry - accumData.a) / max(travelspeed, 0.001));

	float effectiveDecay = mix(accumdecay, min(accumdecay, CLOUD_OCCLUSION_MIN_DECAY), occlusionBreak);

	accumColor = (historyColor * effectiveDecay) + lightColor * (1.0 - effectiveDecay);

	float depthJump = smoothstep(0.0, max(travelspeed, 0.001), abs(currentDistances.b - historyData.b));
	float distanceDecay = effectiveDecay * (1.0 - depthJump);

	accumData.r = mix(historyData.r, currentDistances.r, 1.0 - distanceDecay);
	accumData.g = mix(historyData.g, currentDistances.g, 1.0 - distanceDecay);
	accumData.b = mix(historyData.b, currentDistances.b, 1.0 - distanceDecay);
	accumData.a = currentDistances.a;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(genericData.data.raster_size);

	bool inBounds = (uv.x < size.x && uv.y < size.y);
	uv = min(uv, size - ivec2(1));
	
	vec2 depthUV = (uv + 0.5) / vec2(size);
	float depth = texture(depth_image, depthUV).r;

	vec4 view = scene_data_block.data.inv_projection_matrix * vec4(depthUV*2.0-1.0,depth,1.0);
	view.xyz /= view.w;
	float linear_depth = length(view);
	if (depth <= 0.0){
		linear_depth = 1e9;
	}
	
	vec3 whiteNoise = hash33(vec3(vec2(uv), genericData.data.time));

	vec2 subPixelJitter = (whiteNoise.xy - 0.5) * SUBPIXEL_JITTER;

	vec2 rayUV = depthUV + subPixelJitter / vec2(size);

	vec2 ndc = vec2(0.0);

	vec3 raydirection = cameraRayDirection(rayUV);
	vec3 rayDirectionCenter = cameraRayDirection(depthUV);
	vec3 rayOrigin = scene_data_block.data.main_cam_inv_view_matrix[3].xyz;

	// vec3 ign_noise_uv = vec3(float(uv.x), fract(genericData.data.time) * 2.0 - 1.0, float(uv.y));
	// float ign_noise = fract(52.9829189 * fract(dot(ign_noise_uv, vec3(0.006711056, 0.00583715, 1.61803398875))));
	// float ditherValue = ign_noise;

	float ditherValue = whiteNoise.z;

	vec3 ambientfogdistancecolor = genericData.data.ambientfogdistancecolor.rgb * genericData.data.ambientfogdistancecolor.a;
	float atmosphericDensity = genericData.data.atmospheric_density;

	int stepCount = int(genericData.data.max_step_count);
	int lightingStepCount = int(genericData.data.max_lighting_step_count);
	int directionalLightCount = int(genericData.data.directionalLightsCount);
	int pointLightCount = int(genericData.data.pointLightsCount);

	vec3 extralargeNoisePos = genericData.data.extralargenoiseposition;
	vec3 largeNoisePos = genericData.data.largenoiseposition;
	vec3 mediumNoisePos = genericData.data.mediumnoiseposition;
	vec3 smallNoisePos = genericData.data.smallnoiseposition;

	float extralargenoiseScale = genericData.data.extralargenoisescale;
	float largenoiseScale = genericData.data.large_noise_scale;
	float mediumnoiseScale = genericData.data.medium_noise_scale;
	float smallnoiseScale = genericData.data.small_noise_scale;

	float minstep = genericData.data.min_step_distance;
	float maxstep = genericData.data.max_step_distance;
	
	float curlPower = genericData.data.curlPower;
	float lightingStepDistance = genericData.data.lighting_step_distance;
	float cloudfloor = genericData.data.cloud_floor;
	float cloudceiling = genericData.data.cloud_ceiling;

	float densityMultiplier = genericData.data.cloud_density;
	float sharpness = clamp(1.0 - genericData.data.cloud_sharpness, 0.001, 1.0) * 2.0;
	float lightingSharpness = genericData.data.cloud_lighting_sharpness;
	float smallNoiseMultiplier = genericData.data.small_noise_strength;

	float coverage = genericData.data.cloud_coverage * 1.01;
	float lightingdensityMultiplier = genericData.data.cloud_lighting_power;
	lightingdensityMultiplier += lightingdensityMultiplier * 3.0 * coverage;

	vec4 aobase = genericData.data.ambientGroundLightColor;
	
	//bool debugCollisions = false;
	//int frameIndex = int(genericData.data.filterIndex);
	
	bool override = false;
	bool densityBreak = false;
	bool depthBreak = false;

	float maxTheoreticalStep = float(stepCount) * maxstep;
	
	float visibleDistanceSum = 0.0;
	float visibleDisparitySum = 0.0;
	float visibleDistanceWeight = 0.0;
	//float ceilingSample = cloudceiling;
	float lodMaxDistance = maxstep * float(stepCount) * genericData.data.lod_bias;
	//float halfcloudThickness = (cloudceiling - cloudfloor) * 0.5;
	//float halfCeiling = cloudceiling - halfcloudThickness;
	
	float newStep = maxstep * ditherValue;
	float traveledDistance = newStep;

	vec4 currentColorAccumilation = vec4(0.0);
	vec4 currentDataAccumilation = vec4(0.0);

				//bool rebuildFrame = renderBayer(uv, frameIndex);
				// bool rebuildFrame = true;
				
				// if (!rebuildFrame){
				// 	vec4 niaveDataRetreval = vec4(0.0);
				// 	float usingaccumA = genericData.data.isAccumulationA;
				// 	if (usingaccumA > 0.0){
				// 		niaveDataRetreval = imageLoad(accum_2A_image, uv).rgba;
				// 	}
				// 	else{
				// 		niaveDataRetreval = imageLoad(accum_2B_image, uv).rgba;
				// 	}
				// 	//depthBreak = niaveDataRetreval.r > linear_depth;

				// 	vec3 worldFinalPos = curPos + raydirection * niaveDataRetreval.g;
				// 	worldFinalPos += (rayOrigin - genericData.data.prevview[3].xyz);
				// 	vec4 reprojectedClipPos = inverse(genericData.data.prevview) * vec4(worldFinalPos, 1.0);
					
				// 	if (reprojectedClipPos.z > 0.0){
				// 		override = true;
				// 	}
				// 	else{
				// 		vec4 reprojectedScreenPos = genericData.data.prevproj * reprojectedClipPos;
						
				// 		ndc = (reprojectedScreenPos.xy / reprojectedScreenPos.w);

				// 		vec2 screen_position = ndc * 0.5 + 0.5;
				// 		//screen_position = clamp(screen_position, vec2(0.0), vec2(1.0));
				// 		screen_position = screen_position - depthUV;
				// 		ivec2 adjustedUV = ivec2(int(screen_position.x * size.x), int(screen_position.y * size.y));
				// 		//float change = length(vec2(adjustedUV));
						
				// 		float accumdecay = genericData.data.accumilation_decay;

				// 		float actualDepth = abs(reprojectedClipPos.z);
						
				// 		if (usingaccumA > 0.0){
				// 			currentDataAccumilation = imageLoad(accum_2A_image, adjustedUV).rgba;
				// 			bool lastDepthBreak = currentDataAccumilation.a < 0.0;
				// 			float sampledDepth = currentDataAccumilation.r;
				// 			depthBreak = actualDepth > sampledDepth;
				// 			if (clampedUV != adjustedUV || depthBreak != lastDepthBreak){
				// 				override = true;
				// 				//debugCollisions = true;
				// 			}
				// 			else{
				// 				imageStore(accum_1B_image, uv, imageLoad(accum_1A_image, adjustedUV));
				// 				imageStore(accum_2B_image, uv, currentDataAccumilation);
				// 			}
							
				// 		}
				// 		else{
				// 			currentDataAccumilation = imageLoad(accum_2B_image, adjustedUV).rgba;
				// 			bool lastDepthBreak = currentDataAccumilation.a < 0.0;
				// 			float sampledDepth = abs(currentDataAccumilation.r);
				// 			depthBreak = actualDepth > sampledDepth;
				// 			if (clampedUV != adjustedUV || depthBreak != lastDepthBreak){
				// 				override = true;
				// 				//debugCollisions = true;
				// 			}
				// 			else{
				// 				imageStore(accum_1A_image, uv, imageLoad(accum_1B_image, adjustedUV));
				// 				imageStore(accum_2A_image, uv, currentDataAccumilation);

				// 			}
				// 		}
				// 	}

				// }
				
	vec3 directionalLightSunUpPower[4] = vec3[4](vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
	vec3 directionalLightLinearColor[4] = vec3[4](vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
	vec4 directionalLightSunBase[4] = vec4[4](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
	vec4 directionalLightSunTop[4] = vec4[4](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
	float directionalLightPhase[4] = float[4](0.0, 0.0, 0.0, 0.0);
	int directionalLightSteps[4] = int[4](0, 0, 0, 0);
	float totalLightPower = 0.0;
	float anisotropyExponent = mix(1.0, 2.0, 1.0 - genericData.data.anisotropy);

	for (int lightI = 0; lightI < directionalLightCount; lightI++){
		if (directionalLights[lightI].color.a > 0.0){

			float sunCosZenith = directionalLights[lightI].direction.y;
			directionalLightSunBase[lightI] = atmosphereSunLight(cloudfloor, sunCosZenith, atmosphericDensity);
			directionalLightSunTop[lightI] = atmosphereSunLight(cloudceiling, sunCosZenith, atmosphericDensity);

			directionalLightSunUpPower[lightI].r = 0.5 * (directionalLightSunBase[lightI].a + directionalLightSunTop[lightI].a);
			totalLightPower += directionalLights[lightI].color.a * directionalLightSunUpPower[lightI].r;

			directionalLightSunUpPower[lightI].b = dot(directionalLights[lightI].direction.xyz, raydirection);
		}

		directionalLightPhase[lightI] = pow(HenyeyGreenstein(genericData.data.anisotropy, directionalLightSunUpPower[lightI].b), anisotropyExponent);
		directionalLightLinearColor[lightI] = pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a, vec3(2.2));
		directionalLightSteps[lightI] = min(int(directionalLights[lightI].direction.w), lightingStepCount);
	}

	float lightingDensityScale = densityMultiplier * lightingdensityMultiplier;
	float powderExponent = genericData.data.powderStrength * 2.0;
	
	vec4 lightColor = vec4(0.0);
	vec3 paintedColor = vec3(0.0);
	float initialdistanceSample = 0.0;

	float lightingSamples = 0.0;
	float atmoSamples = 0.0;

	float density = 0.0;
	float ambient = 0.0;
	float depthFade = 1.0;
	float newdensity = 0.0;
	vec3 curPos = vec3(0.0);
	
	float curLod = 1.0;
	float samplePosCount = genericData.data.samplePointsCount;

	if (samplePosCount > 0 && uv == ivec2(0)){
		for (int i = 0; i < samplePosCount; i++){
			curPos = SamplePoints[i].xyz;
			vec4 maskSample = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoiseScale);
			//ceilingSample = mix(halfCeiling, cloudceiling, maskSample.a);
			//ceilingSample = cloudceiling;
			
			SamplePoints[i].w = pow(sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, 1.0, false) * densityMultiplier, sharpness);
		}
	}

	for (int i = 0; i < stepCount; i++) {
		
		if (traveledDistance > linear_depth){
			depthFade = clamp((linear_depth - (traveledDistance - newStep)) / max(newStep, 0.001), 0.0, 1.0);

			traveledDistance = min(traveledDistance, linear_depth);
			depthBreak = true;
		}
		
		curPos = rayOrigin + raydirection * traveledDistance;
		
		vec4 maskSample = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoiseScale);
		//ceilingSample = mix(halfCeiling, cloudceiling, maskSample.a);
		//ceilingSample = cloudceiling;
		
		atmoSamples += 1.0;
		if (clamp(curPos.y, cloudfloor, cloudceiling) == curPos.y){

			curLod = 1.0 - clamp(traveledDistance / lodMaxDistance, 0.0, 1.0);
			// newdensity = sampleSceneCoarse(largeNoisePos, curPos, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, coverage, curLod);
			newdensity = pow(sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, false) * densityMultiplier, sharpness) * depthFade;
			// if (newdensity > 0.0) {
			// 	newdensity = pow(sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, false) * densityMultiplier, sharpness) * depthFade;
			// }
			
			if (newdensity > 0.0){
				if (initialdistanceSample == 0.0){
					initialdistanceSample = traveledDistance;
				}

				float powderEffect = pow(newdensity, powderExponent);

				float lightingWeight = newdensity * clamp(1.0 - density, 0.0, 1.0);

				paintedColor += maskSample.rgb * lightingWeight;
				lightingSamples += lightingWeight;
				float cloudAltitudeBlend = clamp((curPos.y - cloudfloor) / max(cloudceiling - cloudfloor, 1.0), 0.0, 1.0);
				for (int lightI = 0; lightI < directionalLightCount; lightI++){
					vec3 sundir = directionalLights[lightI].direction.xyz;
					vec4 sunAtAltitude = mix(directionalLightSunBase[lightI], directionalLightSunTop[lightI], cloudAltitudeBlend);
					float sunUpWeight = sunAtAltitude.a;

					float densitySample = sampleLighting(directionalLightSteps[lightI], curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, sundir, lightingDensityScale, sunUpWeight, lightingStepDistance, cloudceiling, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, ditherValue);
					densitySample = BeersLaw(lightingStepDistance, densitySample * directionalLightPhase[lightI]);
					//densitySample = Powder(lightingStepDistance, densitySample);
					float thisStepLightingWeight = (pow(densitySample, lightingSharpness)) * sunUpWeight;

					lightColor.rgb += directionalLightLinearColor[lightI] * sunAtAltitude.rgb * pow(thisStepLightingWeight, 2.2) * powderEffect;
					directionalLightSunUpPower[lightI].g += directionalLights[lightI].color.a * thisStepLightingWeight;
					// if (thislightingStepCount > 0){
					// 	float henyeygreenstein =  pow(HenyeyGreenstein(genericData.data.anisotropy, directionalLightSunUpPower[lightI].b), mix(1.0, 2.0, 1.0 - genericData.data.anisotropy)); 
					// 	float densitySample = sampleLighting(thislightingStepCount, curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, sundir, densityMultiplier * lightingdensityMultiplier, sunUpWeight, lightingStepDistance, ceilingSample, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod);
					// 	densitySample = BeersLaw(lightingStepDistance, densitySample * henyeygreenstein);
					// 	//densitySample = Powder(lightingStepDistance, densitySample);
					// 	float thisStepLightingWeight = (clamp(pow(densitySample, lightingSharpness), 0.0, 1.0)) * sunUpWeight;
						
					// 	lightColor.rgb += pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a * thisStepLightingWeight, vec3(2.2)) * powderEffect;
					// 	directionalLightSunUpPower[lightI].g += directionalLights[lightI].color.a * thisStepLightingWeight;
					// }
					// else{
					// 	lightColor.rgb += pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a * sunUpWeight, vec3(2.2)) * powderEffect;
					// 	directionalLightSunUpPower[lightI].g += directionalLights[lightI].color.a * sunUpWeight;
					// }
					// if (directionalLights[lightI].color.a > 0.0){
						
					// 	vec3 sundir = directionalLights[lightI].direction.xyz;
					// 	float sunUpWeight = directionalLightSunUpPower[lightI].r;

					// 	int thislightingStepCount = min(int(directionalLights[lightI].direction.w), lightingStepCount);
					// 	if (thislightingStepCount > 0){
					// 		float henyeygreenstein =  pow(HenyeyGreenstein(genericData.data.anisotropy, directionalLightSunUpPower[lightI].b), mix(1.0, 2.0, 1.0 - genericData.data.anisotropy)); 
					// 		float densitySample = sampleLighting(thislightingStepCount, curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, sundir, densityMultiplier * lightingdensityMultiplier, sunUpWeight, lightingStepDistance, ceilingSample, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod);
					// 		densitySample = BeersLaw(lightingStepDistance, densitySample * henyeygreenstein);
					// 		//densitySample = Powder(lightingStepDistance, densitySample);
					// 		float thisStepLightingWeight = (clamp(pow(densitySample, lightingSharpness), 0.0, 1.0)) * sunUpWeight;
							
					// 		lightColor.rgb += pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a * thisStepLightingWeight, vec3(2.2)) * powderEffect;
					// 		directionalLightSunUpPower[lightI].g += directionalLights[lightI].color.a * thisStepLightingWeight;
					// 	}
					// 	else{
					// 		lightColor.rgb += pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a * sunUpWeight, vec3(2.2)) * powderEffect;
					// 		directionalLightSunUpPower[lightI].g += directionalLights[lightI].color.a * sunUpWeight;
					// 	}

					// }
				}

				for (int lightI = 0; lightI < pointLightCount; lightI++){
					if (pointLights[lightI].color.a <= 0.0){
						continue;
					}
					vec3 lightToOriginDelta = pointLights[lightI].position.xyz - curPos;
					float lightDistanceWeight = length(lightToOriginDelta);
					if (lightDistanceWeight < pointLights[lightI].position.w){
						lightToOriginDelta = normalize(lightToOriginDelta);
						//float densitySample = 1.0 - newdensity;
						float densitySample = sampleLighting(3, curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, lightToOriginDelta, densityMultiplier, 1.0, min(maxstep, lightDistanceWeight), cloudceiling, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, ditherValue);
						
						float henyeygreenstein = pow(HenyeyGreenstein(genericData.data.anisotropy, dot(lightToOriginDelta, raydirection)), anisotropyExponent); 
						densitySample = BeersLaw(lightDistanceWeight, densitySample * henyeygreenstein);
						densitySample = mix(densitySample, newdensity, 0.5) * powderEffect;
						lightDistanceWeight = lightDistanceWeight / pointLights[lightI].position.w;
						lightDistanceWeight = pointLights[lightI].color.a * pow((1.0 - lightDistanceWeight), 2.2) * densitySample;

						lightColor.rgb += pow(pointLights[lightI].color.rgb * lightDistanceWeight, vec3(2.2));
					}
				}
				
				if (aobase.a > 0.0){
					ambient += sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos + vec3(0.0, 1.0, 0.0) * minstep, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, true) * densityMultiplier * lightingdensityMultiplier * lightingWeight;
				}

				newStep = mix(mix(maxstep, minstep, pow(newdensity, 0.1)), maxstep, float(i) / float(stepCount));
			}
			else{
				newStep = maxstep;
			}

			if (i == 0){
				newdensity = mix(newdensity, 0.0, traveledDistance / maxstep);
			}

			float visibleWeight = newdensity * clamp(1.0 - density, 0.0, 1.0);
			visibleDistanceSum += visibleWeight * traveledDistance;
			visibleDisparitySum += visibleWeight / max(traveledDistance, 1.0);
			visibleDistanceWeight += visibleWeight;

			density += newdensity;
			if (density >= 1.0){
				densityBreak = true;
				break;
			}
		}
		else{
			if (min(curPos.y - cloudceiling, raydirection.y) > 0.0 || max(curPos.y - cloudfloor, raydirection.y) < 0.0){
				
				traveledDistance = min(maxTheoreticalStep, linear_depth);
				curPos = rayOrigin + raydirection * traveledDistance;
				
				//debugCollisions = true;
				break;
			}
			
			newStep = maxstep;
		}
		
		traveledDistance += newStep;
		if (depthBreak){
			break;
		}
		
	}

	density *= clamp(smoothstep(maxstep * stepCount, minstep * stepCount, traveledDistance), 0.0, 1.0);

	if (lightingSamples > 0.0){
		ambient = clamp(ambient / lightingSamples, 0.0, 1.0);
		paintedColor = clamp(paintedColor / lightingSamples, 0.0, 1.0);
	}
	else{
		ambient = 0.0;
		paintedColor = vec3(0.0);
	}

	vec3 ambientLight = genericData.data.ambientLightColor.rgb * totalLightPower;
	ambientLight = mix(ambientLight, ambientLight * aobase.rgb, ambient * aobase.a) * paintedColor;
	lightColor.rgb += ambientLight;
	// lightColor.rgb = ambientLight + clamp(lightColor.rgb / lightingSamples, vec3(0.0), vec3(1.0));
	float geometryShadowStrength = genericData.data.geometry_shadow_strength;
	float geometryShadowSharpness = max(genericData.data.geometry_shadow_sharpness, 0.01);
	float geometryShadowDistance = smoothstep(0.0, max(genericData.data.geometry_shadow_distance_fade, 0.001), linear_depth);
	float geometryShadow = 0.0;
	float geometryShadowFade = (1.0 - smoothstep(GEOMETRY_SHADOW_CLOUD_HIDE_START, 1.0, density)) * geometryShadowDistance;
	if (geometryShadowStrength > 0.0 && geometryShadowFade > 0.0 && linear_depth < maxTheoreticalStep){
		vec3 groundPos = rayOrigin + rayDirectionCenter * linear_depth;
		if (groundPos.y < cloudceiling){
			float sunReference = 0.0;
			for (int lightI = 0; lightI < directionalLightCount; lightI++){
				float lightPower = directionalLights[lightI].color.a;
				if (lightPower <= 0.0){
					continue;
				}
				sunReference += lightPower;

				vec4 sunAtGround = atmosphereSunLight(groundPos.y, directionalLights[lightI].direction.y, atmosphericDensity);
				float sunEnergy = lightPower * sunAtGround.a * dot(sunAtGround.rgb, vec3(1.0 / 3.0));
				if (sunEnergy <= 0.0){
					continue;
				}

				float sunlit = cloudSunShadow(
					groundPos, directionalLights[lightI].direction.xyz,
					extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos,
					extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale,
					cloudfloor, cloudceiling, coverage, smallNoiseMultiplier, curlPower,
					densityMultiplier, sharpness, maxstep, ditherValue);

				geometryShadow += pow(clamp(1.0 - sunlit, 0.0, 1.0), geometryShadowSharpness) * sunEnergy;
			}
			geometryShadow = clamp(geometryShadow / max(sunReference, 1e-5), 0.0, 1.0)
				* geometryShadowFade * geometryShadowStrength;
		}
	}

	float combinedAlpha = geometryShadow + density * (1.0 - geometryShadow);
	float cloudAlphaShare = density / max(combinedAlpha, 1e-5);
	lightColor.rgb *= cloudAlphaShare;
	lightColor.a = combinedAlpha;

	float visibleDistance = traveledDistance;
	if (visibleDistanceWeight > 0.0){
		visibleDistance = visibleDistanceSum / visibleDistanceWeight;
	}

	vec3 atmoSunDirections[4];
	vec3 atmoSunColors[4];
	float atmoSunShadows[4] = float[4](1.0, 1.0, 1.0, 1.0);
	int atmoLightCount = min(directionalLightCount, 4);
	vec3 atmoShadowOrigin = rayOrigin + raydirection * min(visibleDistance * 0.5, CLOUD_SHADOW_LOCAL_DISTANCE);
	for (int i = 0; i < atmoLightCount; i++){
		atmoSunDirections[i] = directionalLights[i].direction.xyz;
		atmoSunColors[i] = directionalLights[i].color.rgb * directionalLights[i].color.a * ATMOSPHERE_SUN_INTENSITY;
		atmoSunShadows[i] = cloudSunShadow(
			atmoShadowOrigin, atmoSunDirections[i],
			extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos,
			extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale,
			cloudfloor, cloudceiling, coverage, smallNoiseMultiplier, curlPower,
			densityMultiplier, sharpness, maxstep, ditherValue);
	}

	AerialPerspective cloudAerial = computeAerialPerspective(
		rayOrigin, raydirection, visibleDistance, atmosphericDensity,
		atmoLightCount, atmoSunDirections, atmoSunColors, atmoSunShadows, ambientfogdistancecolor);

	vec3 physicalFogColor = lightColor.rgb * cloudAerial.transmittance + cloudAerial.inscatter;
	float fogweight = aerialPerspectiveOpacity(cloudAerial);

	lightColor.rgb = mix(physicalFogColor, mix(lightColor.rgb, ambientfogdistancecolor, fogweight),  genericData.data.atmosphere_simple_blend);

	if (initialdistanceSample <= 0.0){
		initialdistanceSample = maxTheoreticalStep;
	}

	float geometryDistance = min(linear_depth, maxTheoreticalStep);

	vec3 cameraDelta = rayOrigin - scene_data_block.prev_data.main_cam_inv_view_matrix[3].xyz;
	float travelspeed = length(cameraDelta) + maxstep;

	float backgroundWeight = clamp(1.0 - density, 0.0, 1.0);
	float anchorWeight = visibleDistanceWeight + backgroundWeight;
	float anchorDisparity = 1.0 / max(geometryDistance, 1.0);
	if (anchorWeight > 0.0){
		anchorDisparity = (visibleDisparitySum + backgroundWeight / max(geometryDistance, 1.0)) / anchorWeight;
	}
	float anchorDistance = clamp(1.0 / max(anchorDisparity, 1.0 / maxTheoreticalStep), minstep, maxTheoreticalStep);

	float focalPixels = 0.5 * float(size.y) * abs(scene_data_block.data.projection_matrix[1][1]);

	// How far a unit of disparity error slides the reprojected sample, in pixels. Scaling
	// by the raw translation length treats every direction of travel as full parallax, but
	// a wrong depth only moves the reprojection by the part of the translation that is
	// perpendicular to the ray: travel straight along a ray and the depth along it does
	// not change where the sample lands at all. The overestimate is unbounded as the
	// motion lines up with the view, so flying through a cloud layer drove both agreement
	// tests below past their pixel tolerance on every tap and every history sample at
	// once, leaving the raw dithered march as the only surviving source. Resolve the
	// translation against the ray in the previous camera's basis, and divide by the
	// off-axis foreshortening the perspective divide applies.
	vec3 prevViewDelta = mat3(scene_data_block.prev_data.view_matrix) * cameraDelta;
	vec3 prevViewRay = mat3(scene_data_block.prev_data.view_matrix) * rayDirectionCenter;
	vec2 parallaxPerpendicular = vec2(
		prevViewDelta.z * prevViewRay.x - prevViewRay.z * prevViewDelta.x,
		prevViewDelta.z * prevViewRay.y - prevViewRay.z * prevViewDelta.y);
	float parallaxPixelScale = length(parallaxPerpendicular)
		/ max(prevViewRay.z * prevViewRay.z, 0.01) * focalPixels;

	uint tileIndex = gl_LocalInvocationIndex;
	s_tileColor[tileIndex] = lightColor;
	s_tileDistance[tileIndex] = vec4(initialdistanceSample, traveledDistance, visibleDistance, geometryDistance);
	s_tileAnchor[tileIndex] = anchorDisparity;

	memoryBarrierShared();
	barrier();

	vec4 spatialColor = vec4(0.0);
	vec4 spatialDistance = vec4(0.0);
	float spatialWeight = 0.0;
	float spatialDistanceWeight = 0.0;
	vec4 wideColor = vec4(0.0);
	float wideWeight = 0.0;
	float rebuildFar = REBUILD_PIXEL_TOLERANCE * 3.0;

	vec4 colorMin = vec4(1e30);
	vec4 colorMax = vec4(-1e30);
	vec4 distMin = vec4(1e30);
	vec4 distMax = vec4(-1e30);

	ivec2 windowCenter = ivec2(gl_LocalInvocationID.xy);
	for (int ny = -1; ny <= 1; ny++){
		for (int nx = -1; nx <= 1; nx++){
			ivec2 tapLocal = windowCenter + ivec2(nx, ny);
			// The tile only holds this workgroup, so drop taps that fall outside it.
			// Clamping the window instead would shift it by a pixel along every tile
			// border and stamp an 8x8 grid into the spatial filter.
			if (any(lessThan(tapLocal, ivec2(0))) || any(greaterThan(tapLocal, ivec2(7)))){
				continue;
			}
			int tapIndex = tapLocal.y * 8 + tapLocal.x;

			vec4 tapColor = s_tileColor[tapIndex];
			colorMin = min(colorMin, tapColor);
			colorMax = max(colorMax, tapColor);

			vec4 tapDistance = s_tileDistance[tapIndex];
			distMin = min(distMin, tapDistance);
			distMax = max(distMax, tapDistance);

			float tapAgreement = 1.0 - smoothstep(REBUILD_PIXEL_TOLERANCE, rebuildFar, abs(s_tileAnchor[tapIndex] - anchorDisparity) * parallaxPixelScale);
			spatialColor += tapColor * tapAgreement;
			spatialWeight += tapAgreement;

			float tapDensityWeight = tapAgreement * clamp(tapColor.a, 0.0, 1.0);
			spatialDistance += tapDistance * tapDensityWeight;
			spatialDistanceWeight += tapDensityWeight;

			wideColor += tapColor;
			wideWeight += 1.0;
		}
	}

	if (spatialWeight > 0.0){
		spatialColor /= spatialWeight;
	}
	else{
		spatialColor = lightColor;
	}

	if (wideWeight > 0.0){
		wideColor /= wideWeight;
	}
	else{
		wideColor = lightColor;
	}

	if (spatialDistanceWeight > 0.0){
		spatialDistance /= spatialDistanceWeight;
	}
	else{
		spatialDistance = vec4(initialdistanceSample, traveledDistance, visibleDistance, geometryDistance);
	}

	vec4 boxCenter = (colorMin + colorMax) * 0.5;
	vec4 boxExtent = (colorMax - colorMin) * 0.5 * NEIGHBORHOOD_WIDEN;

	vec4 neighborhoodMin = boxCenter - boxExtent;
	vec4 neighborhoodMax = boxCenter + boxExtent;

	vec3 worldFinalPos = rayOrigin + rayDirectionCenter * anchorDistance;
	vec3 prevCameraPos = scene_data_block.prev_data.main_cam_inv_view_matrix[3].xyz;

	vec4 reprojectedScreenPos = vec4(0.0);
	vec4 reprojectedClipPos = scene_data_block.prev_data.view_matrix * vec4(worldFinalPos, 1.0);

	reprojectedClipPos.z -= 0.01;
	if (reprojectedClipPos.z > 0.0){
		override = true;
	}

	reprojectedScreenPos = scene_data_block.prev_data.projection_matrix * reprojectedClipPos;

	ndc = (reprojectedScreenPos.xy / reprojectedScreenPos.w);

	vec2 historyPixel = (ndc * 0.5 + 0.5) * vec2(size) - 0.5;

	vec2 historyBase = floor(historyPixel);
	vec2 historyFrac = historyPixel - historyBase;

	float historyShift = length(historyPixel - vec2(uv));
	float historyTrust = 1.0 - smoothstep(0.0, CLAMP_RELAX_PIXELS, historyShift);

	float expectedPrevDisparity = 1.0 / max(length(worldFinalPos - prevCameraPos), 1.0);
	float expectedPrevGeometry = length(rayOrigin + rayDirectionCenter * geometryDistance - prevCameraPos);

	ivec2 adjustedUV = ivec2(historyBase);

	ivec2 clampedUV = clamp(adjustedUV, ivec2(0), size - ivec2(1));
	ivec2 accumMaxUV = size - ivec2(1);

	ivec2 tap00 = clamp(clampedUV,               ivec2(0), accumMaxUV);
	ivec2 tap10 = clamp(clampedUV + ivec2(1, 0), ivec2(0), accumMaxUV);
	ivec2 tap01 = clamp(clampedUV + ivec2(0, 1), ivec2(0), accumMaxUV);
	ivec2 tap11 = clamp(clampedUV + ivec2(1, 1), ivec2(0), accumMaxUV);

	float accumdecay = genericData.data.accumilation_decay;

	float usingaccumA = genericData.data.isAccumulationA;

	vec4 currentDistances = vec4(initialdistanceSample, traveledDistance, visibleDistance, geometryDistance);
	float historyConfidence = 1.0;
	bool hardReset = override || clampedUV != adjustedUV;

	if (usingaccumA > 0.0){
		resolveHistory(
			imageLoad(accum_1A_image, tap00), imageLoad(accum_1A_image, tap10),
			imageLoad(accum_1A_image, tap01), imageLoad(accum_1A_image, tap11),
			imageLoad(accum_2A_image, tap00), imageLoad(accum_2A_image, tap10),
			imageLoad(accum_2A_image, tap01), imageLoad(accum_2A_image, tap11),
			historyFrac, expectedPrevDisparity, parallaxPixelScale, HISTORY_PIXEL_TOLERANCE,
			currentColorAccumilation, currentDataAccumilation, historyConfidence);
	}
	else{
		resolveHistory(
			imageLoad(accum_1B_image, tap00), imageLoad(accum_1B_image, tap10),
			imageLoad(accum_1B_image, tap01), imageLoad(accum_1B_image, tap11),
			imageLoad(accum_2B_image, tap00), imageLoad(accum_2B_image, tap10),
			imageLoad(accum_2B_image, tap01), imageLoad(accum_2B_image, tap11),
			historyFrac, expectedPrevDisparity, parallaxPixelScale, HISTORY_PIXEL_TOLERANCE,
			currentColorAccumilation, currentDataAccumilation, historyConfidence);
	}

	historyConfidence = max(historyConfidence, historyTrust);

	// Both agreement tests key off the same reprojection estimate, so wherever the history
	// is rejected the depth weighted neighbourhood has usually collapsed onto the centre
	// tap too - it is the only tap that agrees with itself exactly. That makes the rebuild
	// source a single raw march, dither and all. Widen it toward the plain neighbourhood
	// mean as confidence falls so the fallback is the whole window rather than one sample.
	// Distances are left on the agreement weighted average to keep occlusion edges sharp.
	float rebuildWiden = hardReset ? 1.0 : clamp(1.0 - historyConfidence, 0.0, 1.0);
	spatialColor = mix(spatialColor, wideColor, rebuildWiden);

	currentColorAccumilation = mix(currentColorAccumilation, clamp(currentColorAccumilation, neighborhoodMin, neighborhoodMax), HISTORY_CLAMP_STRENGTH * (1.0 - historyTrust));

	currentDataAccumilation.rgb = mix(clamp(currentDataAccumilation.rgb, distMin.rgb, distMax.rgb), currentDataAccumilation.rgb, historyTrust);

	blendAccumulation(
		lightColor, currentDistances, spatialColor, spatialDistance,
		historyConfidence, accumdecay, travelspeed, expectedPrevGeometry, hardReset,
		currentColorAccumilation, currentDataAccumilation);


	float surfaceShadowWeight = clamp(geometryShadow * (1.0 - density) / max(combinedAlpha, 1e-5), 0.0, 1.0);
	surfaceShadowWeight *= 1.0 - smoothstep(0.0, GEOMETRY_SHADOW_DISTANCE_PIN_FADE, density);
	if (surfaceShadowWeight > 0.0){
		currentDataAccumilation.r = mix(currentDataAccumilation.r, geometryDistance, surfaceShadowWeight);
		currentDataAccumilation.b = mix(currentDataAccumilation.b, geometryDistance, surfaceShadowWeight);
	}

	if (inBounds){
		if (usingaccumA > 0.0){
			imageStore(accum_1B_image, uv, currentColorAccumilation);
			imageStore(accum_2B_image, uv, currentDataAccumilation);
		}
		else{
			imageStore(accum_1A_image, uv, currentColorAccumilation);
			imageStore(accum_2A_image, uv, currentDataAccumilation);
		}
	}
	// if (linear_depth < maxTheoreticalStep){
	// 	float nearby_blend = smoothstep(maxstep, minstep, abs(currentDataAccumilation.b - linear_depth));
	// 	depthFade = 1.0 - clamp(linear_depth - maxstep - currentDataAccumilation.b, 0.0, minstep) / minstep;
		
	// 	currentColorAccumilation.a = mix(currentColorAccumilation.a, 0.0, nearby_blend);
	// 	// currentDataAccumilation.g = mix(currentDataAccumilation.g, maxTheoreticalStep, clamp(finalDensityDistance - linear_depth, 0.0, 1.0) * depthFade * nearby_blend);
	// 	//currentColorAccumilation.rgb = mix(currentColorAccumilation.rgb, vec3(1.0, 0.0, 0.0), float(depthFade));
	// }
	// // currentDataAccumilation.g = mix(currentDataAccumilation.g, maxTheoreticalStep, clamp(finalDensityDistance - linear_depth, 0.0, 1.0) * depthFade);
	
	// if (depthBreak){
	// 	currentColorAccumilation.rgb = vec3(1.0, 0.0, 0.0);
	// }

	// currentDataAccumilation.g += maxTheoreticalStep * float(depthBreak);

	currentDataAccumilation.r = min(currentDataAccumilation.r, initialdistanceSample);
	
	if (!inBounds){
		return;
	}

	imageStore(output_color_image, uv, currentColorAccumilation);
	imageStore(output_data_image, uv, min(currentDataAccumilation, vec4(DATA_DISTANCE_MAX)));
	//}
}
