#[compute]
#version 450
#define PI 3.141592
#define ABSORPTION_COEFFICIENT 0.9

#include "./CloudsInc.comp"

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, binding = 0) uniform image2D output_data_image;
layout(rgba16f, binding = 1) uniform image2D output_color_image;

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
layout(binding = 12) uniform sampler3D dither_small;
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
	SceneData data;
	SceneData prev_data;
} scene_data_block;

// Our push constant
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
// } params;

//Helpers
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

//Sample functions

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
	// float extraLargeShape = extralargeNoiseValue * gradientSample.b;

	float smallShape = texture(noise_small, (worldPosition - smallNoisePos) / smallnoisescale).r;

	float curlHeightSample = (1.0 - gradientSample.a);

	float effectorAdditive = 0.0;
	vec2 WindDirection = genericData.data.WindDirection;
	worldPosition += vec3(WindDirection.x, 0.0, WindDirection.y) * genericData.data.windSweptPower * quadraticIn(1.0 - clamp(clampedWorldHeight / genericData.data.windSweptRange, 0.0, 1.0));

	if (lod > 0.0){
		effectorAdditive = sampleEffectorAdditive(worldPosition) * edgeFade;

		if (!ambientsample && curlHeightSample > 0.0 && min(curlPower, lod) > 0.5){
			
			float curlLod = remap(lod, 0.5, 1.0, 0.0, 1.0);
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + vec3(WindDirection.x, 0.0, WindDirection.y) * 0.9) * curlPower * curlHeightSample * curlLod;
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + vec3(WindDirection.x, 0.0, WindDirection.y) * 0.9) * curlPower * curlHeightSample * curlLod;
			worldPosition += (((texture(curl_noise, (worldPosition - mediumNoisePos) / mediumnoisescale).xyz * 2.0) - 1.0) * vec3(1.0, 0.2, 1.0) + vec3(WindDirection.x, 0.0, WindDirection.y) * 0.9) * curlPower * curlHeightSample * curlLod;
			
			clampedWorldHeight = remap(worldPosition.y, cloudfloor, cloudceiling, 0.0, 1.0);
			gradientSample = texture(heightmask, vec2(clampedWorldHeight, 0.5)).rgba;
		}
	}

	float largeShape = texture(large_noise, (worldPosition - largeNoisePos) / largenoisescale).r * 1.0;
	largeShape = smoothstep(coverage , coverage - 0.1, 1.0 - (largeShape * gradientSample.r)) + max(effectorAdditive, 0.0);
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
	// float extraLargeShape = extralargeNoiseValue * gradientSample.b;

	float effectorAdditive = 0.0;
	vec2 WindDirection = genericData.data.WindDirection;
	worldPosition += vec3(WindDirection.x, 0.0, WindDirection.y) * genericData.data.windSweptPower * quadraticIn(1.0 - clamp(clampedWorldHeight / genericData.data.windSweptRange, 0.0, 1.0));

	if (lod > 0.0){
		effectorAdditive = sampleEffectorAdditive(worldPosition) * edgeFade;
	}

	float largeShape = texture(large_noise, (worldPosition - largeNoisePos) / largenoisescale).r * 1.0;
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
	float lod)
	{
	float density = 0.0;
	float stepCountFloat = max(float(stepCount) * lod, 2.0);
	float actualDistance = mix(stepDistance * 4.0, stepDistance, lod);
	float eachShortStep = actualDistance / (float(stepCount) / stepCountFloat) / stepCountFloat;
	float traveledDistance = 0.0;
	
	float sunUpValue = 1.0 - sunUpWeight;
	float eachStepWeight = 1.0 / stepCountFloat;

	float heightGradient = 0.0;
	float thisDensity = 0.0;
	float count = 0.0;
	vec3 curPos = worldPosition;
	for (float i = 0.0; i < stepCountFloat; i++) {
		traveledDistance = mix(eachShortStep, actualDistance, clamp(quadraticOut(i / stepCountFloat), 0.0, 1.0));
		curPos = worldPosition + sunDirection * traveledDistance;

		if (density < 1.0 && clamp(curPos.y, cloudfloor, cloudceiling) == curPos.y){
			heightGradient = remap(curPos.y, cloudfloor, cloudceiling, 0.0, 1.0);
			
			heightGradient = clamp(smoothstep(sunUpValue - 0.1, sunUpValue, heightGradient), 0.0, 1.0);
			// float extraLargeShape = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoisescale).a;

			thisDensity = sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos, cloudceiling, cloudfloor, 1.0, largenoisescale, mediumnoisescale, smallnoisescale, coverage, smallscalePower, curlPower, lod, true) * densityMultiplier * eachStepWeight;
			// if (thisDensity <= 0.0){
			// 	break;
			// }
			density += mix(1.0, thisDensity, heightGradient);
		}
		else{
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

	// float extraLargeShape = texture(extra_large_noise, (samplePos.xz - extralargeNoisePos.xz) / extralargenoisescale).a;
	return sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, samplePos, cloudceiling, cloudfloor, 1.0, largenoisescale, mediumnoisescale, smallnoisescale, coverage, smallscalePower, curlPower, lod, true);
}

void sampleAtmospherics(
	vec3 curPos, 
	float atmosphericHeight, 
	float distanceTraveled,
	float Rayleighscaleheight, 
	float Miescaleheight, 
	vec3 RayleighScatteringCoef, 
	float MieScatteringCoef, 
	float atmosphericDensity, 
	float density, 
	inout vec3 totalRlh, 
	inout vec3 totalMie, 
	inout float iOdRlh, 
	inout float iOdMie)
	{
	float iHeight = curPos.y / atmosphericHeight;
	float odStepRlh = exp(-iHeight / Rayleighscaleheight) * distanceTraveled;
	float odStepMie = exp(-iHeight / Miescaleheight) * distanceTraveled;
	iOdRlh += odStepRlh;
	iOdMie += odStepMie;

	vec3 attn = exp(-(MieScatteringCoef * (iOdMie + Miescaleheight) + RayleighScatteringCoef * (iOdRlh + Rayleighscaleheight))) * atmosphericDensity * (1.0 - clamp(iHeight, 0.0, 1.0));
	totalRlh += odStepRlh * attn * (1.0 - density);
	totalMie += odStepMie * attn * (1.0 - density);
}


vec4 sampleAllAtmospherics(
	vec3 worldPos, 
	vec3 rayDirection,
	float linear_depth,
	float highestDensityDistance,
	float density,
	float stepDistance,
	float stepCount,
	float atmosphericDensity, 
	vec3 sunDirection, 
	vec3 sunlightColor, 
	vec3 ambientLight)
	{
	vec3 totalRlh = vec3(0,0,0);
    vec3 totalMie = vec3(0,0,0);
	float iOdRlh = 0.0;
    float iOdMie = 0.0;
	// float odStepRlh = 0.0;
	// float odStepMie = 0.0;

	const float atmosphericHeight = 40000.0;
	const vec3 RayleighScatteringCoef = vec3(5.5e-6, 13.0e-6, 22.4e-6);
	const float Rayleighscaleheight = 8e3;
	const float MieScatteringCoef = 21e-6;
	const float Miescaleheight = 1.2e3;
	const float MieprefferedDirection = 0.758;

	// Calculate the Rayleigh and Mie phases.
    float mu = dot(rayDirection, sunDirection);
    float mumu = mu * mu;
    float gg = MieprefferedDirection * MieprefferedDirection;
    float pRlh = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pMie = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * MieprefferedDirection, 1.5) * (2.0 + gg));

	vec3 curPos = vec3(0.0);
	float traveledDistance = 0.0;
	//bool sampledDistanceAtmo = false;
	float currentWeight = 0.0;
	float sampleCount = 0.0;

	for (float i = 0.0; i < stepCount; i++) {
		traveledDistance = stepDistance * (i + 1);
		
		currentWeight = density * (1.0 - (highestDensityDistance - traveledDistance) / stepDistance);

		if (traveledDistance > linear_depth || currentWeight >= 1.0){
			traveledDistance = traveledDistance - stepDistance;
			currentWeight = 1.0 - clamp((linear_depth - traveledDistance) / stepDistance, 0.0, 1.0);
			sampleAtmospherics(curPos, atmosphericHeight, stepDistance, Rayleighscaleheight, Miescaleheight, RayleighScatteringCoef, MieScatteringCoef, atmosphericDensity, currentWeight, totalRlh, totalMie, iOdRlh, iOdMie); 
			break;
		}
		sampleCount += 1.0;
		
		curPos = worldPos + rayDirection * traveledDistance;
		
		sampleAtmospherics(curPos, atmosphericHeight, stepDistance, Rayleighscaleheight, Miescaleheight, RayleighScatteringCoef, MieScatteringCoef, atmosphericDensity, currentWeight, totalRlh, totalMie, iOdRlh, iOdMie); 
	}

	// pRlh *= (1.0 - lightingWeight);
	// pMie *= (1.0 - lightingWeight);

	float AtmosphericsDistancePower = length(vec3(RayleighScatteringCoef * totalRlh + MieScatteringCoef * totalMie));
	vec3 atmospherics = 22.0 * (ambientLight * RayleighScatteringCoef * totalRlh + pMie * MieScatteringCoef * sunlightColor * totalMie) / sampleCount;
	return vec4(atmospherics, AtmosphericsDistancePower);
}


void main() {
	//SETTING UP UVS/RAY DATA
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(genericData.data.raster_size);

	// Prevent reading/writing out of bounds.
	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}
	
	// vec2 depthUV = (uv + 0.5) / vec2(size);


	int resolutionScale = int(genericData.data.resolutionscale);
    ivec2 sizescaled = size * resolutionScale;

    int adjustedScale = resolutionScale * 2;
    int halfScale = int(floor(float(adjustedScale) * 0.5));
    ivec2 starting_uv = ivec2(floor(vec2(uv) * float(resolutionScale)));
    ivec2 current_uv = starting_uv;

    vec2 depthUV = vec2(0.0);

    float furthestDepth = 10000000000000000.0;
    for (int x = 0; x < adjustedScale; x++) {
        for(int y = 0; y < adjustedScale; y++) {
            current_uv = starting_uv + ivec2(x, y);
            if (current_uv.x >= sizescaled.x || current_uv.y >= sizescaled.y) {
                continue;
            }

            depthUV = vec2((float(current_uv.x) + 0.5) / float(sizescaled.x), (float(current_uv.y) + 0.5) / float(sizescaled.y));

            furthestDepth = min(texture(depth_image, depthUV).r, furthestDepth);
        }
    }

	float depth = furthestDepth;
	depthUV = (uv + 0.5) / vec2(size);
	// float depth = texture(depth_image, depthUV).r;





	vec4 view = scene_data_block.data.inv_projection_matrix * vec4(depthUV*2.0-1.0,depth,1.0);
	view.xyz /= view.w;
	float linear_depth = length(view); //used to calculate depth based on the view angle, idk just works.
	//4.4 doesn't work with this
	if (linear_depth >= scene_data_block.data.z_far){ 
		linear_depth *= 100.0;
	}
	
	// Convert screen coordinates to normalized device coordinates
	vec2 clipUV = vec2(depthUV.x, depthUV.y);
	vec2 ndc = clipUV * 2.0 - 1.0;	
	// Convert NDC to view space coordinates
	vec4 clipPos = vec4(ndc, 0.0, 1.0);
	vec4 viewPos = scene_data_block.data.inv_projection_matrix * clipPos;
	viewPos.xyz /= viewPos.w;
	
	vec3 rd_world = normalize(viewPos.xyz);
	rd_world = mat3(scene_data_block.data.main_cam_inv_view_matrix) * rd_world;
	// Define the ray properties
	
	vec3 raydirection = normalize(rd_world);
	vec3 rayOrigin = scene_data_block.data.main_cam_inv_view_matrix[3].xyz; //center of camera for the ray origin, not worried about the screen width playing in, as it's for clouds.


	//DITHER

	// expirements with interleved gradient noise.
	// float ditherScale = 40.037;
	// vec3 ditherUV = vec3(depthUV.x * ditherScale , depthUV.y * ditherScale , genericData.data.time);
	// float smallNoise = texture(dither_small, ditherUV).r;
	// vec3 ign_noise_uv = vec3(float(uv.x), fract(genericData.data.time) * 2.0 - 1.0, float(uv.y));
	// float ign_noise = fract(52.9829189 * fract(dot(ign_noise_uv, vec3(0.006711056, 0.00583715, 1.61803398875))));
	// float ditherValue = ign_noise;

	float ditherScale = 40.037;
	vec3 ditherUV = vec3(depthUV.x * ditherScale , depthUV.y * ditherScale , genericData.data.time);
	float smallNoise = texture(dither_small, ditherUV).r;

	float ditherValue = smallNoise;

	//ATMOSPHERICS
	vec3 ambientfogdistancecolor = genericData.data.ambientfogdistancecolor.rgb;
	vec3 totalRlh = vec3(0,0,0);
    vec3 totalMie = vec3(0,0,0);
	float iOdRlh = 0.0;
    float iOdMie = 0.0;
	float atmosphericDensity = genericData.data.atmospheric_density;

	const float atmosphericHeight = 40000.0;
	const vec3 RayleighScatteringCoef = vec3(5.5e-6, 13.0e-6, 22.4e-6);
	const float Rayleighscaleheight = 8e3;
	const float MieScatteringCoef = 21e-6;
	const float Miescaleheight = 1.2e3;
	const float MieprefferedDirection = 0.758;

	//IMPORTED DATA
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
	
	//REUSABLE VARIABLES
	bool override = false;
	bool densityBreak = false;
	bool depthBreak = false;

	float maxTheoreticalStep = float(stepCount) * maxstep;
	float highestDensity = 0.0;
	float highestDensityDistance = maxTheoreticalStep;
	//float ceilingSample = cloudceiling;
	float lodMaxDistance = maxstep * float(stepCount) * genericData.data.lod_bias;
	//float halfcloudThickness = (cloudceiling - cloudfloor) * 0.5;
	//float halfCeiling = cloudceiling - halfcloudThickness;
	

	float newStep = maxstep * ditherValue;
	float traveledDistance = newStep;

	vec4 currentColorAccumilation = vec4(0.0);
	vec4 currentDataAccumilation = vec4(0.0);




	//Used for interlaced rendering, not currently enabled due to it's long accumilation time, results in a lot of noticable artifacts.
	//Though it does improve performance, so maybe for some people it will be helpful.

				//bool rebuildFrame = renderBayer(uv, frameIndex);
				// bool rebuildFrame = true;
				
				// if (!rebuildFrame){
				// 	//accumulation preperation:
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
				// 	//Prevview is already actually the inv_view (due to the way retrieving the transform works), so inversing it here is making it the equalivant of View_Matrix.
				// 	vec4 reprojectedClipPos = inverse(genericData.data.prevview) * vec4(worldFinalPos, 1.0);
					
					
				// 	if (reprojectedClipPos.z > 0.0){
				// 		override = true;
				// 	}
				// 	else{
				// 		vec4 reprojectedScreenPos = genericData.data.prevproj * reprojectedClipPos;
						
				// 		// Convert clip space to normalized device coordinates
				// 		ndc = (reprojectedScreenPos.xy / reprojectedScreenPos.w);

				// 		// Convert normalized device coordinates to screen space
				// 		vec2 screen_position = ndc * 0.5 + 0.5;
				// 		//screen_position = clamp(screen_position, vec2(0.0), vec2(1.0));
				// 		screen_position = screen_position - depthUV;
				// 		ivec2 adjustedUV = ivec2(int(screen_position.x * size.x), int(screen_position.y * size.y));
				// 		//float change = length(vec2(adjustedUV));
				// 		adjustedUV += uv; //Size is the screen resolution.
						
				// 		ivec2 clampedUV = clamp(adjustedUV, ivec2(0), size - ivec2(1)); //having two lets me check if clamping it changed the reprojected uv, if it did that means it was offscreen, so rebuild data.

				// 		//execute accumilation.
				// 		float accumdecay = genericData.data.accumilation_decay;

				// 		//alternate back and forth to avoid stepping on pixels being written too.
						
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
				
	// END INTERLACED RENDERING


	
	//if (rebuildFrame || override){ //Re-enable for interlaced rendering
	//If it is our render, build the data for this pixel
	
	
	vec3 directionalLightSunUpPower[4] = vec3[4](vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
	float totalLightPower = 0.0;

	for (int lightI = 0; lightI < directionalLightCount; lightI++){
		if (directionalLights[lightI].color.a > 0.0){
			
			directionalLightSunUpPower[lightI].r = smoothstep(-0.03, 0.07, dot(directionalLights[lightI].direction.xyz, vec3(0.0, 1.0, 0.0)));
			totalLightPower += directionalLights[lightI].color.a * directionalLightSunUpPower[lightI].r;

			directionalLightSunUpPower[lightI].b = dot(directionalLights[lightI].direction.xyz, raydirection);
		}
	}
	

	
	
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
			// depthFade = 1.0 - smoothstep(linear_depth - newStep, linear_depth, traveledDistance);
			depthBreak = true;
		}
		
		curPos = rayOrigin + raydirection * traveledDistance;
		
		vec4 maskSample = texture(extra_large_noise, (curPos.xz - extralargeNoisePos.xz) / extralargenoiseScale);
		//ceilingSample = mix(halfCeiling, cloudceiling, maskSample.a);
		//ceilingSample = cloudceiling;
		
		//sampleAtmospherics(curPos, atmosphericHeight, newStep, Rayleighscaleheight, Miescaleheight, RayleighScatteringCoef, MieScatteringCoef, atmosphericDensity, density, totalRlh, totalMie, iOdRlh, iOdMie); 
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

				float powderEffect = pow(newdensity, genericData.data.powderStrength * 2.0);

				paintedColor += maskSample.rgb;
				lightingSamples += 1.0;
				for (int lightI = 0; lightI < directionalLightCount; lightI++){
					vec3 sundir = directionalLights[lightI].direction.xyz;
					float sunUpWeight = directionalLightSunUpPower[lightI].r;

					int thislightingStepCount = min(int(directionalLights[lightI].direction.w), lightingStepCount);
					float henyeygreenstein =  pow(HenyeyGreenstein(genericData.data.anisotropy, directionalLightSunUpPower[lightI].b), mix(1.0, 2.0, 1.0 - genericData.data.anisotropy)); 
					float densitySample = sampleLighting(thislightingStepCount, curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, sundir, densityMultiplier * lightingdensityMultiplier, sunUpWeight, lightingStepDistance, cloudceiling, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod);
					densitySample = BeersLaw(lightingStepDistance, densitySample * henyeygreenstein);
					//densitySample = Powder(lightingStepDistance, densitySample);
					float thisStepLightingWeight = (pow(densitySample, lightingSharpness)) * sunUpWeight;
					

					lightColor.rgb += pow(directionalLights[lightI].color.rgb * directionalLights[lightI].color.a * thisStepLightingWeight, vec3(2.2)) * powderEffect;
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
					vec3 lightToOriginDelta = pointLights[lightI].position.xyz - curPos;
					float lightDistanceWeight = length(lightToOriginDelta); 
					if (pointLights[lightI].color.a > 0.0 && lightDistanceWeight < pointLights[lightI].position.w){
						lightToOriginDelta = normalize(lightToOriginDelta);
						//float densitySample = 1.0 - newdensity;
						float densitySample = sampleLighting(3, curPos, extralargeNoisePos, largeNoisePos, mediumNoisePos, smallNoisePos, lightToOriginDelta, densityMultiplier, 1.0, min(maxstep, lightDistanceWeight), cloudceiling, cloudfloor, extralargenoiseScale, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod);
						
						float henyeygreenstein = pow(HenyeyGreenstein(genericData.data.anisotropy, dot(lightToOriginDelta, raydirection)), mix(1.0, 2.0, 1.0 - genericData.data.anisotropy)); 
						densitySample = BeersLaw(lightDistanceWeight, densitySample * henyeygreenstein);
						densitySample = mix(densitySample, newdensity, 0.5) * powderEffect;
						lightDistanceWeight = lightDistanceWeight / pointLights[lightI].position.w;
						lightDistanceWeight = pointLights[lightI].color.a * pow((1.0 - lightDistanceWeight), 2.2) * densitySample;


						lightColor.rgb += pow(pointLights[lightI].color.rgb * lightDistanceWeight, vec3(2.2));
					}
				}
				
				if (aobase.a > 0.0){
					ambient += sampleScene(largeNoisePos, mediumNoisePos, smallNoisePos, curPos + vec3(0.0, 1.0, 0.0) * minstep, cloudceiling, cloudfloor, maskSample.a, largenoiseScale, mediumnoiseScale, smallnoiseScale, coverage, smallNoiseMultiplier, curlPower, curLod, true) * densityMultiplier * lightingdensityMultiplier ;
				}

				
				newStep = mix(mix(maxstep, minstep, pow(newdensity, 0.1)), maxstep, float(i) / float(stepCount));
				if (newdensity > highestDensity){
					highestDensity = newdensity;
					highestDensityDistance = traveledDistance;
				}
			}
			else{
				newStep = maxstep;
			}

			if (i == 0){
				newdensity = mix(newdensity, 0.0, traveledDistance / maxstep);
			}

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

	ambient = clamp(ambient / lightingSamples, 0.0, 1.0);
	paintedColor = clamp(paintedColor / lightingSamples, 0.0, 1.0);


	vec3 ambientLight = genericData.data.ambientLightColor.rgb * totalLightPower;
	ambientLight = mix(ambientLight, ambientLight * aobase.rgb, ambient * aobase.a) * paintedColor;
	lightColor.rgb += ambientLight;
	// lightColor.rgb = ambientLight + clamp(lightColor.rgb / lightingSamples, vec3(0.0), vec3(1.0));
	lightColor.a = density;

	vec3 physicalFogColor = lightColor.rgb;
	float fogweight = 0.0;
	
	if (linear_depth > maxstep && directionalLightCount > 0.0){
		for (float i = 0.0; i < directionalLightCount; i++){
			DirectionalLight light = directionalLights[int(i)];
			vec3 sundir = light.direction.xyz;
			//sampleColor = sundir;
			float sunUpWeight = smoothstep(0.0, 0.4, dot(sundir, vec3(0.0, 1.0, 0.0)));
			float sundensityaffect = 1.0 - clamp(dot(sundir, raydirection) * density, 0.0, 1.0);
			// sundensityaffect = min(1.0 - (sundensityaffect * density), 1.0 - (sundensityaffect * clamp(maxTheoreticalStep - linear_depth, 0.0, 1.0)));
			float lightPower = light.color.a * sunUpWeight * sundensityaffect;
			vec4 atmosphericData = sampleAllAtmospherics(rayOrigin, raydirection, linear_depth, traveledDistance, 0.0, traveledDistance / 10.0, 10.0, atmosphericDensity, sundir, light.color.rgb * lightPower, ambientfogdistancecolor);
			
			physicalFogColor = mix(physicalFogColor, atmosphericData.rgb, atmosphericData.a); //causes jitter in the sky
			fogweight += atmosphericData.a;
		}
	}



	lightColor.rgb = mix(physicalFogColor, mix(lightColor.rgb, ambientfogdistancecolor, fogweight),  genericData.data.atmosphere_simple_blend);
	//lightColor.rgb = physicalFogColor;
	// initialdistanceSample = max(initialdistanceSample, 0.0);


	//accumulation preperation:
	float finalDensityDistance = min(traveledDistance, highestDensityDistance);
	vec3 worldFinalPos = rayOrigin + raydirection * traveledDistance;
	vec3 delta = rayOrigin - scene_data_block.prev_data.main_cam_inv_view_matrix[3].xyz;
	worldFinalPos += delta;
	
	vec4 reprojectedScreenPos = vec4(0.0);

	#if ((GODOT_VERSION_MAJOR == 4) && (GODOT_VERSION_MINOR == 4)) || ((GODOT_VERSION_MAJOR == 4) && (GODOT_VERSION_MINOR == 5))

		//Prevview is already actually the inv_view (due to the way retrieving the transform works), so inversing it here is making it the equalivant of View_Matrix.
		vec4 reprojectedClipPos = scene_data_block.prev_data.view_matrix * vec4(worldFinalPos, 1.0);
		
		reprojectedClipPos.z -= 0.01;
		if (reprojectedClipPos.z > 0.0){
			override = true;
		}
		
		reprojectedScreenPos = scene_data_block.prev_data.projection_matrix * reprojectedClipPos;
	#else
		mat4 view_matrix = transpose(mat4(
			scene_data_block.prev_data.view_matrix[0], 
			scene_data_block.prev_data.view_matrix[1], 
			scene_data_block.prev_data.view_matrix[2], 
			vec4(0.0, 0.0, 0.0, 1.0)));

		//Prevview is already actually the inv_view (due to the way retrieving the transform works), so inversing it here is making it the equalivant of View_Matrix.
		vec4 reprojectedClipPos = view_matrix * vec4(worldFinalPos, 1.0);
		
		reprojectedClipPos.z -= 0.01;
		if (reprojectedClipPos.z > 0.0){
			override = true;
		}
		
		reprojectedScreenPos = scene_data_block.prev_data.projection_matrix * reprojectedClipPos;
	#endif

	// Convert clip space to normalized device coordinates
	ndc = (reprojectedScreenPos.xy / reprojectedScreenPos.w);

	// Convert normalized device coordinates to screen space
	vec2 screen_position = ndc * 0.5 + 0.5;
	//screen_position = clamp(screen_position, vec2(0.0), vec2(1.0));
	screen_position = screen_position - depthUV;

	ivec2 adjustedUV = ivec2(int(screen_position.x * size.x), int(screen_position.y * size.y));
	//float change = length(vec2(adjustedUV));
	adjustedUV += uv; //Size is the screen resolution.
	
	ivec2 clampedUV = clamp(adjustedUV, ivec2(0), size - ivec2(1)); //having two lets me check if clamping it changed the reprojected uv, if it did that means it was offscreen, so rebuild data.

	//execute accumilation.
	float accumdecay = genericData.data.accumilation_decay;

	//alternate back and forth to avoid stepping on pixels being written too.
	float usingaccumA = genericData.data.isAccumulationA;
	
	//float finalDensityDistance = max(traveledDistance, highestDensityDistance);
	//linear_depth = max(linear_depth, traveledDistance);
	float travelspeed = length(delta) + maxstep;
	//bool debugCollisions = false;
	if (usingaccumA > 0.0){
		currentColorAccumilation = imageLoad(accum_1A_image, adjustedUV).rgba;
		currentDataAccumilation = imageLoad(accum_2A_image, adjustedUV).rgba;

		float currentDepthBreak = float(depthBreak);

		// bool lastDepthBreak = currentDataAccumilation.a < 0.0;
		float if_break = max(float(override), abs(length(clampedUV - adjustedUV)));
		// if_break = max(if_break, lightColor.a - 0.8 - currentColorAccumilation.a); //Lets super high accumilation still look passable, but at the cost of less soft edges.

		if (if_break > 0.0 || (currentDepthBreak != currentDataAccumilation.a && abs(initialdistanceSample - currentDataAccumilation.r) > travelspeed * 0.5)){
			currentColorAccumilation = lightColor;
			//debugCollisions = true;
			currentDataAccumilation.r = initialdistanceSample;
			currentDataAccumilation.g = traveledDistance;
			currentDataAccumilation.b = finalDensityDistance;
		}
		else{
			currentColorAccumilation = (currentColorAccumilation * accumdecay) + lightColor * (1.0 - accumdecay);

			currentDataAccumilation.r = mix(currentDataAccumilation.r, initialdistanceSample, (1.0 - accumdecay));
			currentDataAccumilation.g = mix(currentDataAccumilation.g, traveledDistance,  (1.0 - accumdecay));
			currentDataAccumilation.b = mix(currentDataAccumilation.b, finalDensityDistance,  (1.0 - accumdecay));
		}

		currentDataAccumilation.a = currentDepthBreak;

		imageStore(accum_1B_image, uv, currentColorAccumilation);
		imageStore(accum_2B_image, uv, currentDataAccumilation);
	}
	else{
		currentColorAccumilation = imageLoad(accum_1B_image, adjustedUV).rgba;
		currentDataAccumilation = imageLoad(accum_2B_image, adjustedUV).rgba;

		float currentDepthBreak = float(depthBreak);
		
		// bool lastDepthBreak = currentDataAccumilation.a < 0.0;
		float if_break = max(float(override), abs(length(clampedUV - adjustedUV)));
		// if_break = max(if_break, lightColor.a - 0.8 - currentColorAccumilation.a); //Lets super high accumilation still look passable, but at the cost of less soft edges.

		if (if_break > 0.0 || (currentDepthBreak != currentDataAccumilation.a && abs(initialdistanceSample - currentDataAccumilation.r) > travelspeed * 0.5)){
			currentColorAccumilation = lightColor;
			//debugCollisions = true;
			currentDataAccumilation.r = initialdistanceSample;
			currentDataAccumilation.g = traveledDistance;
			currentDataAccumilation.b = finalDensityDistance;
		}
		else{
			currentColorAccumilation = (currentColorAccumilation * accumdecay) + lightColor * (1.0 - accumdecay);

			currentDataAccumilation.r = mix(currentDataAccumilation.r, initialdistanceSample, (1.0 - accumdecay));
			currentDataAccumilation.g = mix(currentDataAccumilation.g, traveledDistance,  (1.0 - accumdecay));
			currentDataAccumilation.b = mix(currentDataAccumilation.b, finalDensityDistance,  (1.0 - accumdecay));
		}

		currentDataAccumilation.a = currentDepthBreak;

		imageStore(accum_1A_image, uv, currentColorAccumilation);
		imageStore(accum_2A_image, uv, currentDataAccumilation);
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
	
	imageStore(output_color_image, uv, currentColorAccumilation);
	imageStore(output_data_image, uv, currentDataAccumilation);
	//}
}