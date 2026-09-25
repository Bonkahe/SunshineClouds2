#[compute]
#version 450

#define MSAA_ENABLED 1

#include "./CloudsInc.comp"
#include "./SunshineCloudsPostCompute.comp"
// Body revision 5: depth-aware upsample; radial blur removed.
