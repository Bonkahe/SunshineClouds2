#[compute]
#version 450

#define MSAA_ENABLED 1

#include "./CloudsInc.comp"
#include "./SunshineCloudsPostCompute.comp"
// Body revision 2: premultiplied composite; geometry shadow keeps its aerial inscatter.
