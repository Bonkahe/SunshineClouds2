#[compute]
#version 450

#define MSAA_ENABLED 1

#include "./CloudsInc.comp"
#include "./SunshineCloudsPostCompute.comp"
// Body revision 7: slope-aware upsample match on grazing ground.
