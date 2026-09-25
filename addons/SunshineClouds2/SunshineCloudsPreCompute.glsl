#[compute]
#version 450

#include "./CloudsInc.comp"
// Shared header revision 3: GenericData carries the full target size.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D depth_image;
layout(r32f, binding = 1) uniform image2D output_depth_image;

layout(binding = 2) uniform uniformBuffer {
	GenericData data;
} genericData;

void main() {
    ivec2 base_uv = ivec2(gl_GlobalInvocationID.xy);
	//ivec2 size = ivec2(params.raster_size);
    ivec2 lowres_size = ivec2(genericData.data.raster_size);

    // int resolutionScale = int(params.resolutionscale);
    int resolutionScale = int(genericData.data.resolutionscale);
    // The depth buffer's own size, not lowres_size * resolutionScale, which can be
    // a pixel larger at odd sizes.
    ivec2 size = textureSize(depth_image, 0);

    int adjustedScale = resolutionScale * 2;
    int windowOffset = (adjustedScale - resolutionScale) / 2;
    ivec2 starting_uv = ivec2(floor(vec2(base_uv) * float(resolutionScale))) - ivec2(windowOffset);
    ivec2 current_uv = starting_uv;

    float furthestDepth = 10000000000000000.0;
    for (int x = 0; x < adjustedScale; x++) {
        for(int y = 0; y < adjustedScale; y++) {
            current_uv = starting_uv + ivec2(x, y);
            if (current_uv.x < 0 || current_uv.y < 0 || current_uv.x >= size.x || current_uv.y >= size.y) {
                continue;
            }

            // Fetched by pixel, not sampled by a normalized UV: a UV built against
            // the wrong size drifts across the screen and snaps to the next row
            // halfway down, which split the low-res depth along the middle.
            furthestDepth = min(texelFetch(depth_image, current_uv, 0).r, furthestDepth);
        }
    }

    imageStore(output_depth_image, base_uv, vec4(furthestDepth, 0.0, 0.0, 0.0));
}