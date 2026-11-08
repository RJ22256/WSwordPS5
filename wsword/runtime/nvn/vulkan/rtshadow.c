// (WSword) Ray-traced sun shadows (rtshadow.h)
#include "rtshadow.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../settings.h"
#include "../maxwell/shader.h"
#include "record.h"

uint64_t renderer_present_count(void);

#define MAX_CASC 8      // cascades (the game draws 3): one acceleration structure each, the instance mask its bit
#define MAX_SEG 4096    // runs of caster draws (the same cascade, opaque or not, one after another)
#define VERT 16         // bytes a captured vertex (vec4: the clip position, then the world position in place)
#define RAYS 8          // per pixel, over the sun's disc (0.3.13: 8 - 4 left the penumbras grainy, the filter blurred them)
#define AO_RAYS 6       // per pixel, ambient occlusion (0.3.13)
#define UBO_FLOATS 216  // trace_src's / refl_src's U (0.3.19: the world camera's view-projection, the reflections')
#define WATER_ID 22     // (0.3.19) the G-buffer's material id of water (rt0's red channel x 255)

typedef struct { VkBuffer buf; VkDeviceMemory mem; VkDeviceSize size; VkDeviceAddress addr; } RBuf;

static struct {
    bool tried, ok;
    char why[200];
    PFN_vkCreateAccelerationStructureKHR create_as;
    PFN_vkDestroyAccelerationStructureKHR destroy_as;
    PFN_vkGetAccelerationStructureBuildSizesKHR sizes;
    PFN_vkCmdBuildAccelerationStructuresKHR build;
    PFN_vkGetAccelerationStructureDeviceAddressKHR as_addr;
    PFN_vkCmdBindTransformFeedbackBuffersEXT xfb_bind;
    PFN_vkCmdBeginTransformFeedbackEXT xfb_begin;
    PFN_vkCmdEndTransformFeedbackEXT xfb_end;
    PFN_vkCmdPushDescriptorSetKHR push_set;
    VkDeviceSize scratch_align;
    VkPipelineLayout xform_layout, trace_layout;
    VkDescriptorSetLayout xform_set, trace_set;
    VkPipeline xform, trace;
    VkSampler nearest;
    RBuf cap;            // the captured vertices (capacity cap_verts)
    uint32_t cap_verts;
    RBuf blas_buf[MAX_CASC], tlas_buf, scratch, inst, ubo;
    VkAccelerationStructureKHR blas[MAX_CASC], tlas;
    TexBackend vis, copy;  // the rays' result (RGBA8, .r lit, .g through foliage) and a copy of the game's mask
    // (0.3.19) the water's reflections: made the first time there's water to reflect in
    bool rf_tried, rf_ok;
    VkDescriptorSetLayout rf_set;
    VkPipelineLayout rf_layout;
    VkPipeline rf;
    TexBackend refl;       // their result (RGBA16F at the G-buffer's size: .rgb what the ray met, .a how much of it)
} R;

static struct {  // this frame's capture
    uint64_t frame;
    uint32_t cursor, need;
    bool overflow;
    struct { uint32_t start, count; uint8_t casc, foliage; } seg[MAX_SEG];
    int nseg, ndraws, nfol;
    int ncasc;
    float vp[MAX_CASC][16];   // the cascades' view-projections (c3 12-27, row-major: the game's clip from the world)
    double inv[MAX_CASC][16]; // and their inverses
    float sun[3];             // toward the sun (the light's view's z row)
    float view[11];           // the first cascade's view rotation (c3 0-10): the others' must be the same
    TexBackend *map;          // the cascades' depth array (the game's maps: foliage's opacity in the rays)
    uint32_t layer[MAX_CASC]; // each cascade's layer in it
    int missed;               // caster draws not captured (a variant still compiling...): the game's mask kept too
    // the mask (rts_mask_seen)
    bool pending;
    TexBackend *mask, *depth;
    float world[64];
    // the last run's numbers (rts_report, rts_status)
    uint32_t last_tris, last_casc;
    uint64_t runs;
} C;

// ---------------------------------------------------------------- buffers

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(g_vk.phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static bool rbuf_make(RBuf *b, VkDeviceSize size, VkBufferUsageFlags usage) {
    memset(b, 0, sizeof *b);
    VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                             .usage = usage | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    if (vkCreateBuffer(g_vk.dev, &bi, NULL, &b->buf) != VK_SUCCESS) return false;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(g_vk.dev, b->buf, &req);
    VkMemoryAllocateFlagsInfo fi = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, .flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT};
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &fi, .allocationSize = req.size,
                               .memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(g_vk.dev, &ai, NULL, &b->mem) != VK_SUCCESS) {
        vkDestroyBuffer(g_vk.dev, b->buf, NULL);
        memset(b, 0, sizeof *b);
        return false;
    }
    vkBindBufferMemory(g_vk.dev, b->buf, b->mem, 0);
    VkBufferDeviceAddressInfo ba = {.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = b->buf};
    b->addr = vkGetBufferDeviceAddress(g_vk.dev, &ba);
    b->size = size;
    return true;
}

// Replaced buffers and acceleration structures: destroyed once the GPU is past the submissions that may use them
static struct { RBuf b; VkAccelerationStructureKHR as; uint64_t seq; } dead[64];
static int ndead;
static void retire(RBuf *b, VkAccelerationStructureKHR *as) {
    if (!b->buf && !(as && *as)) return;
    if (ndead == 64) {  // (never in practice: wait for the GPU, then let them all go)
        vkDeviceWaitIdle(g_vk.dev);
        for (int i = 0; i < ndead; i++) {
            if (dead[i].as) R.destroy_as(g_vk.dev, dead[i].as, NULL);
            if (dead[i].b.buf) vkDestroyBuffer(g_vk.dev, dead[i].b.buf, NULL), vkFreeMemory(g_vk.dev, dead[i].b.mem, NULL);
        }
        ndead = 0;
    }
    dead[ndead].b = *b, dead[ndead].as = as ? *as : VK_NULL_HANDLE, dead[ndead++].seq = vk_pending_seq();
    memset(b, 0, sizeof *b);
    if (as) *as = VK_NULL_HANDLE;
}
static void reap(void) {
    uint64_t done = vk_completed_seq();
    int k = 0;
    for (int i = 0; i < ndead; i++) {
        if (dead[i].seq > done) { dead[k++] = dead[i]; continue; }
        if (dead[i].as) R.destroy_as(g_vk.dev, dead[i].as, NULL);
        if (dead[i].b.buf) vkDestroyBuffer(g_vk.dev, dead[i].b.buf, NULL), vkFreeMemory(g_vk.dev, dead[i].b.mem, NULL);
    }
    ndead = k;
}

// ---------------------------------------------------------------- shaders

// The captured clip positions back to the world, in place: each run's vertices through its cascade's inverse
static const char xform_src[] =
    "#version 460\n"
    "layout(local_size_x = 256) in;\n"
    "layout(set = 0, binding = 0, std430) buffer B { vec4 v[]; };\n"
    "layout(push_constant) uniform P { mat4 inv; uint start; uint count; } pc;\n"  // (inv: row-major, v * inv)
    "void main() {\n"
    "  uint i = gl_GlobalInvocationID.x;\n"
    "  if (i >= pc.count) return;\n"
    "  vec4 w = v[pc.start + i] * pc.inv;\n"
    "  v[pc.start + i] = abs(w.w) > 1e-20 ? vec4(w.xyz / w.w, 1.0) : vec4(uintBitsToFloat(0x7fc00000u));\n"  // (NaN: inactive)
    "}\n";

// Each pixel of the half-resolution depth: its world position (the world camera's inverse), its normal (from its
// neighbours, the nearer of each pair), the finest cascade it is in, then RAYS rays over the sun's disc against that
// cascade's geometry: .r the share that met nothing (alpha-tested foliage blocks where its cut-out is solid: solid());
// (0, 1): no cascade, or the sky - the game's mask as it is.
static const char trace_src[] =
    "#version 460\n"
    "#extension GL_EXT_ray_query : require\n"
    "layout(local_size_x = 8, local_size_y = 8) in;\n"
    "layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;\n"
    "layout(set = 0, binding = 1) uniform sampler2D dep;\n"
    "layout(set = 0, binding = 2, rgba8) uniform writeonly image2D vis;\n"
    "layout(set = 0, binding = 4) uniform sampler2DArray maps;\n"  // the game's cascades (depth): foliage's cut-outs
    "layout(set = 0, binding = 3, std140) uniform U {\n"
    "  mat4 inv_vp;\n"      // (row-major: v * m) the world camera's clip to the world
    "  mat4 casc[8];\n"     // the world to each cascade's clip
    "  vec4 sun;\n"         // xyz: toward the sun; w: the disc's radius (tan)
    "  vec4 cam;\n"         // xyz: the camera's position
    "  vec4 p;\n"           // x: rows' direction (ysign); y: OpenGL depth (1); z: cascades; w: rays
    "  vec4 bias;\n"        // x: metres; y: per metre of distance; z: the rays' length; w: foliage nearer is passed
    "  vec4 cl[8];\n"      // x: each cascade's layer in the maps
    "  vec4 aop;\n"        // x: ambient occlusion's rays' length (metres); y: its rays (0: none)
    "  mat4 vp;\n"         // (0.3.19) the world camera's: the world to its clip (refl_src)
    "  vec4 rfp;\n"        // x: the reflections' rays' length; z: water's material id; w: their strength
    "} u;\n"
    // A candidate hit on alpha-tested foliage at H blocks the ray where the game's own map of that cascade - drawn
    // with the leaves' cut-outs - has a surface at least as near the light as H there (within 25 cm): the cut-out was
    // solid at that texel. Elsewhere the ray goes on through the leaf's transparent part.
    "bool solid(vec3 H, vec3 L, int c) {\n"
    "  vec4 a = vec4(H, 1.0) * u.casc[c], b = vec4(H + L * 0.25, 1.0) * u.casc[c];\n"
    "  if (a.w <= 0.0 || b.w <= 0.0) return true;\n"
    "  vec3 na = a.xyz / a.w, nb = b.xyz / b.w;\n"
    "  vec2 uv = vec2(na.x * 0.5 + 0.5, na.y * u.p.x * 0.5 + 0.5);\n"
    "  if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return true;\n"
    "  float da = u.p.y > 0.5 ? na.z * 0.5 + 0.5 : na.z, db = u.p.y > 0.5 ? nb.z * 0.5 + 0.5 : nb.z;\n"
    "  ivec3 sz = textureSize(maps, 0);\n"
    "  float dm = texelFetch(maps, ivec3(min(ivec2(uv * vec2(sz.xy)), sz.xy - 1), int(u.cl[c].x)), 0).r;\n"
    "  float toward = da - db;\n"  // (depth change 25 cm toward the light: its sign is the depth's direction)
    "  return (da - dm) * sign(toward) >= -abs(toward);\n"
    "}\n"
    "float depth_at(ivec2 px, ivec2 sz) {\n"  // (the full-resolution depth, at the mask pixel's centre)
    "  ivec2 dz = textureSize(dep, 0);\n"
    "  return texelFetch(dep, min(ivec2((vec2(px) + 0.5) / vec2(sz) * vec2(dz)), dz - 1), 0).r;\n"
    "}\n"
    "vec3 world(ivec2 px, ivec2 sz) {\n"
    "  px = clamp(px, ivec2(0), sz - 1);\n"
    "  float d = depth_at(px, sz);\n"
    "  vec2 uv = (vec2(px) + 0.5) / vec2(sz);\n"
    "  vec4 c = vec4(uv.x * 2.0 - 1.0, (uv.y * 2.0 - 1.0) * u.p.x, u.p.y > 0.5 ? d * 2.0 - 1.0 : d, 1.0);\n"
    "  vec4 w = c * u.inv_vp;\n"
    "  return w.xyz / w.w;\n"
    "}\n"
    "void main() {\n"
    "  ivec2 sz = imageSize(vis), px = ivec2(gl_GlobalInvocationID.xy);\n"
    "  if (px.x >= sz.x || px.y >= sz.y) return;\n"
    "  float d = depth_at(px, sz);\n"
    "  if (d >= 0.999999) { imageStore(vis, px, vec4(0.0, 1.0, 1.0, 0.0)); return; }\n"
    "  vec3 P = world(px, sz);\n"
    "  vec3 pr = world(px + ivec2(1, 0), sz), pl = world(px - ivec2(1, 0), sz);\n"
    "  vec3 pd = world(px + ivec2(0, 1), sz), pu = world(px - ivec2(0, 1), sz);\n"
    "  vec3 dx = length(pr - P) < length(P - pl) ? pr - P : P - pl;\n"
    "  vec3 dy = length(pd - P) < length(P - pu) ? pd - P : P - pu;\n"
    "  vec3 V = u.cam.xyz - P;\n"
    "  vec3 N = cross(dx, dy);\n"
    "  N = dot(N, N) > 1e-20 ? normalize(N) : normalize(V);\n"
    "  if (dot(N, V) < 0.0) N = -N;\n"
    "  int c = -1;\n"
    "  for (int i = 0; i < int(u.p.z) && c < 0; i++) {\n"
    "    vec4 q = vec4(P, 1.0) * u.casc[i];\n"
    "    if (q.w > 0.0 && abs(q.x) < q.w * 0.995 && abs(q.y) < q.w * 0.995) c = i;\n"
    "  }\n"
    "  if (c < 0) { imageStore(vis, px, vec4(0.0, 1.0, 1.0, 0.0)); return; }\n"
    "  vec3 L = normalize(u.sun.xyz);\n"
    "  float b = u.bias.x + length(V) * u.bias.y;\n"
    "  vec3 O = P + N * b + L * b;\n"
    "  vec3 T = normalize(cross(abs(L.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), L));\n"
    "  vec3 B = cross(L, T);\n"
    "  float a0 = 6.2831853 * fract(52.9829189 * fract(dot(vec2(px), vec2(0.06711056, 0.00583715))));\n"
    "  int n = int(u.p.w);\n"
    "  float lit = 0.0, fol = 0.0;\n"
    "  for (int k = 0; k < n; k++) {\n"
    "    float r = sqrt((float(k) + 0.5) / float(n)) * u.sun.w, ang = a0 + float(k) * 2.39996323;\n"
    "    vec3 D = normalize(L + (T * cos(ang) + B * sin(ang)) * r);\n"
    "    rayQueryEXT q;\n"
    "    rayQueryInitializeEXT(q, tlas, gl_RayFlagsTerminateOnFirstHitEXT, 1u << c, O, 0.0, D, u.bias.z);\n"
    "    while (rayQueryProceedEXT(q))\n"
    "      if (rayQueryGetIntersectionTypeEXT(q, false) == gl_RayQueryCandidateIntersectionTriangleEXT) {\n"
    "        float t = rayQueryGetIntersectionTEXT(q, false);\n"
    "        if (t > u.bias.w && solid(O + D * t, L, c)) rayQueryConfirmIntersectionEXT(q);\n"
    "      }\n"
    "    if (rayQueryGetIntersectionTypeEXT(q, true) == gl_RayQueryCommittedIntersectionNoneEXT) lit += 1.0;\n"
    "  }\n"
    // (0.3.13) Ambient occlusion: AO_RAYS short rays (u.aop.x metres long) over the
    // hemisphere around the normal, cosine-weighted, against the same cascade's opaque geometry (foliage left out:
    // its cut-outs are known only toward the sun); a hit near the surface occludes more than one at the rays' end.
    // .b: the share of the sky the surface sees (1: open)
    "  float occ = 0.0;\n"
    "  int na = int(u.aop.y);\n"
    "  vec3 TN = normalize(cross(abs(N.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), N));\n"
    "  vec3 BN = cross(N, TN);\n"
    "  vec3 OA = P + N * b;\n"
    "  for (int k = 0; k < na; k++) {\n"
    "    float e = (float(k) + 0.5) / float(na), ang = a0 + float(k) * 2.39996323;\n"
    "    float s = sqrt(e), z = sqrt(max(0.0, 1.0 - e));\n"
    "    vec3 D = normalize(TN * (cos(ang) * s) + BN * (sin(ang) * s) + N * z);\n"
    "    rayQueryEXT q;\n"
    "    rayQueryInitializeEXT(q, tlas, gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsCullNoOpaqueEXT, 1u << c, OA, 0.0, D, u.aop.x);\n"
    "    while (rayQueryProceedEXT(q)) {}\n"
    "    if (rayQueryGetIntersectionTypeEXT(q, true) != gl_RayQueryCommittedIntersectionNoneEXT)\n"
    "      occ += 1.0 - rayQueryGetIntersectionTEXT(q, true) / u.aop.x;\n"
    "  }\n"
    "  float ao = na > 0 ? 1.0 - occ / float(na) : 1.0;\n"
    "  imageStore(vis, px, vec4(lit / float(n), fol / float(n), ao, 0.0));\n"
    "}\n";

// (0.3.19) Ray-traced reflections on water, at the composited scene (before the HUD). For each pixel the game's
// G-buffer marks water (rt0's red channel: material id WATER_ID), a ray from the surface along the view reflected in
// its normal (rt3: the world-space normal, the waves' included) against the casters' opaque geometry, every cascade,
// as far as u.rfp.x. Where it meets a surface the camera sees - the scene's depth there is that surface - the
// reflection is the scene's colour there, its weight the water's Fresnel term (Schlick, F0 0.02) times the strength,
// faded at the screen's edges; a ray to the sky, or to a surface out of view or hidden, leaves the game's own
// reflection (its sky and light) as it is (weight 0).
static const char refl_src[] =
    "#version 460\n"
    "#extension GL_EXT_ray_query : require\n"
    "layout(local_size_x = 8, local_size_y = 8) in;\n"
    "layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;\n"
    "layout(set = 0, binding = 1) uniform sampler2D dep;\n"
    "layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D outr;\n"
    "layout(set = 0, binding = 3, std140) uniform U {\n"
    "  mat4 inv_vp; mat4 casc[8]; vec4 sun; vec4 cam; vec4 p; vec4 bias; vec4 cl[8]; vec4 aop; mat4 vp; vec4 rfp;\n"
    "} u;\n"
    "layout(set = 0, binding = 4) uniform sampler2D col;\n"   // the composited scene
    "layout(set = 0, binding = 5) uniform sampler2D mat;\n"   // the G-buffer's rt0 (.r: the material id / 255)
    "layout(set = 0, binding = 6) uniform sampler2D nrm;\n"   // the G-buffer's rt3 (.xyz: the world normal * 0.5 + 0.5)
    "ivec2 at(vec2 uv, ivec2 s) { return clamp(ivec2(uv * vec2(s)), ivec2(0), s - 1); }\n"
    "float depth_uv(vec2 uv) { return texelFetch(dep, at(uv, textureSize(dep, 0)), 0).r; }\n"
    "vec3 world_uv(vec2 uv, float d) {\n"
    "  vec4 c = vec4(uv.x * 2.0 - 1.0, (uv.y * 2.0 - 1.0) * u.p.x, u.p.y > 0.5 ? d * 2.0 - 1.0 : d, 1.0);\n"
    "  vec4 w = c * u.inv_vp;\n"
    "  return w.xyz / w.w;\n"
    "}\n"
    "void main() {\n"
    "  ivec2 sz = imageSize(outr), px = ivec2(gl_GlobalInvocationID.xy);\n"
    "  if (px.x >= sz.x || px.y >= sz.y) return;\n"
    "  vec2 uv = (vec2(px) + 0.5) / vec2(sz);\n"
    "  float id = texelFetch(mat, at(uv, textureSize(mat, 0)), 0).r * 255.0;\n"
    "  if (abs(id - u.rfp.z) > 0.5) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  float d = depth_uv(uv);\n"
    "  if (d >= 0.999999) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  vec3 P = world_uv(uv, d);\n"
    "  vec3 N = texelFetch(nrm, at(uv, textureSize(nrm, 0)), 0).xyz * 2.0 - 1.0;\n"
    "  N = dot(N, N) > 1e-6 ? normalize(N) : vec3(0.0, 1.0, 0.0);\n"
    "  vec3 V = normalize(u.cam.xyz - P);\n"
    "  if (dot(N, V) < 0.02) N = normalize(N + V * (0.02 - dot(N, V)));\n"   // (a wave facing away: as if edge-on)
    "  vec3 R = reflect(-V, N);\n"
    "  if (R.y < 0.01) R = normalize(vec3(R.x, 0.01, R.z));\n"              // (into the water: along it)
    "  float c = clamp(dot(N, V), 0.0, 1.0), F = 0.02 + 0.98 * pow(1.0 - c, 5.0);\n"
    "  vec3 O = P + N * (0.03 + length(u.cam.xyz - P) * 0.0005);\n"
    "  rayQueryEXT q;\n"
    "  rayQueryInitializeEXT(q, tlas, gl_RayFlagsCullNoOpaqueEXT, 0xFFu, O, 0.05, R, u.rfp.x);\n"
    "  while (rayQueryProceedEXT(q)) {}\n"
    "  if (rayQueryGetIntersectionTypeEXT(q, true) == gl_RayQueryCommittedIntersectionNoneEXT) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  vec3 H = O + R * rayQueryGetIntersectionTEXT(q, true);\n"
    "  vec4 hc = vec4(H, 1.0) * u.vp;\n"
    "  if (hc.w <= 1e-4) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  vec2 huv = vec2(hc.x / hc.w * 0.5 + 0.5, hc.y / hc.w * u.p.x * 0.5 + 0.5);\n"
    "  vec2 e2 = min(huv, 1.0 - huv);\n"
    "  if (min(e2.x, e2.y) <= 0.0) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  float hd = depth_uv(huv);\n"
    "  vec3 S = world_uv(huv, hd);\n"
    "  float dh = length(H - u.cam.xyz);\n"
    "  if (hd >= 0.999999 || length(S - H) > 0.03 * dh + 0.5) { imageStore(outr, px, vec4(0.0)); return; }\n"
    "  vec3 L = textureLod(col, huv, 0.0).rgb;\n"
    "  float w = clamp(F * u.rfp.w, 0.0, 0.7) * smoothstep(0.0, 0.06, min(e2.x, e2.y));\n"
    "  imageStore(outr, px, vec4(L, w));\n"
    "}\n";

static VkPipeline compute_pipeline(const char *src, const char *name, VkPipelineLayout layout) {
    VkShaderModule m = vk_compile_glsl(src, STAGE_COMPUTE, name);
    if (!m) return VK_NULL_HANDLE;
    VkComputePipelineCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                                      .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                                                .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = m, .pName = "main"},
                                      .layout = layout};
    VkPipeline p = VK_NULL_HANDLE;
    VkResult r = vkCreateComputePipelines(g_vk.dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
    vkDestroyShaderModule(g_vk.dev, m, NULL);
    if (r != VK_SUCCESS) LOG("[rts] the %s pipeline failed (%d)\n", name, r);
    return r == VK_SUCCESS ? p : VK_NULL_HANDLE;
}

static bool setup(void) {
#define FN(field, T, name) (R.field = (T)vkGetDeviceProcAddr(g_vk.dev, name))
    FN(create_as, PFN_vkCreateAccelerationStructureKHR, "vkCreateAccelerationStructureKHR");
    FN(destroy_as, PFN_vkDestroyAccelerationStructureKHR, "vkDestroyAccelerationStructureKHR");
    FN(sizes, PFN_vkGetAccelerationStructureBuildSizesKHR, "vkGetAccelerationStructureBuildSizesKHR");
    FN(build, PFN_vkCmdBuildAccelerationStructuresKHR, "vkCmdBuildAccelerationStructuresKHR");
    FN(as_addr, PFN_vkGetAccelerationStructureDeviceAddressKHR, "vkGetAccelerationStructureDeviceAddressKHR");
    FN(xfb_bind, PFN_vkCmdBindTransformFeedbackBuffersEXT, "vkCmdBindTransformFeedbackBuffersEXT");
    FN(xfb_begin, PFN_vkCmdBeginTransformFeedbackEXT, "vkCmdBeginTransformFeedbackEXT");
    FN(xfb_end, PFN_vkCmdEndTransformFeedbackEXT, "vkCmdEndTransformFeedbackEXT");
    FN(push_set, PFN_vkCmdPushDescriptorSetKHR, "vkCmdPushDescriptorSetKHR");
#undef FN
    if (!R.create_as || !R.destroy_as || !R.sizes || !R.build || !R.as_addr || !R.xfb_bind || !R.xfb_begin || !R.xfb_end ||
        !R.push_set) {
        snprintf(R.why, sizeof R.why, "the driver's ray tracing functions are missing");
        return false;
    }
    VkPhysicalDeviceAccelerationStructurePropertiesKHR ap = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR};
    VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &ap};
    vkGetPhysicalDeviceProperties2(g_vk.phys, &p2);
    R.scratch_align = ap.minAccelerationStructureScratchOffsetAlignment ? ap.minAccelerationStructureScratchOffsetAlignment : 256;
    // the layouts: push descriptors (written into the command buffer: nothing to keep alive between frames)
    VkDescriptorSetLayoutBinding xb = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
    VkDescriptorSetLayoutCreateInfo xl = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                          .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, .bindingCount = 1,
                                          .pBindings = &xb};
    VkDescriptorSetLayoutBinding tb[5] = {
        {0, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL}};
    VkDescriptorSetLayoutCreateInfo tl = xl;
    tl.bindingCount = 5, tl.pBindings = tb;
    if (vkCreateDescriptorSetLayout(g_vk.dev, &xl, NULL, &R.xform_set) != VK_SUCCESS ||
        vkCreateDescriptorSetLayout(g_vk.dev, &tl, NULL, &R.trace_set) != VK_SUCCESS) {
        snprintf(R.why, sizeof R.why, "its descriptor layouts failed");
        return false;
    }
    VkPushConstantRange pr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 72};
    VkPipelineLayoutCreateInfo pl = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
                                     .pSetLayouts = &R.xform_set, .pushConstantRangeCount = 1, .pPushConstantRanges = &pr};
    VkPipelineLayoutCreateInfo tpl = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
                                      .pSetLayouts = &R.trace_set};
    if (vkCreatePipelineLayout(g_vk.dev, &pl, NULL, &R.xform_layout) != VK_SUCCESS ||
        vkCreatePipelineLayout(g_vk.dev, &tpl, NULL, &R.trace_layout) != VK_SUCCESS) {
        snprintf(R.why, sizeof R.why, "its pipeline layouts failed");
        return false;
    }
    R.xform = compute_pipeline(xform_src, "rts_xform.comp", R.xform_layout);
    R.trace = compute_pipeline(trace_src, "rts_trace.comp", R.trace_layout);
    if (!R.xform || !R.trace) {
        snprintf(R.why, sizeof R.why, "its shaders failed to compile (WSword.log says why)");
        return false;
    }
    VkSamplerCreateInfo si = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST,
                              .minFilter = VK_FILTER_NEAREST, .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                              .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                              .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 0};
    if (vkCreateSampler(g_vk.dev, &si, NULL, &R.nearest) != VK_SUCCESS) {
        snprintf(R.why, sizeof R.why, "its sampler failed");
        return false;
    }
    R.cap_verts = 4u << 20;  // (16 MB a million vertices: the report's frame captured ~3 million; grown when short)
    if (!rbuf_make(&R.cap, (VkDeviceSize)R.cap_verts * VERT,
                   VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                       VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR) ||
        !rbuf_make(&R.inst, MAX_CASC * sizeof(VkAccelerationStructureInstanceKHR),
                   VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR | VK_BUFFER_USAGE_TRANSFER_DST_BIT) ||
        !rbuf_make(&R.ubo, 1024, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT)) {
        snprintf(R.why, sizeof R.why, "its buffers couldn't be made (out of video memory?)");
        return false;
    }
    LOG("[rts] ray-traced shadows ready (capture %u vertices, scratch alignment %llu)\n", R.cap_verts,
        (unsigned long long)R.scratch_align);
    return true;
}

bool rts_on(void) {
    if (!g_settings.rt_shadows || !g_vk.rt) return false;
    if (!R.tried) {
        R.tried = true;
        R.ok = setup();
        if (!R.ok) LOG("[rts] ray-traced shadows off: %s\n", R.why);
    }
    return R.ok;
}

// ---------------------------------------------------------------- the capture

typedef struct { VkCommandBuffer cb; VkBuffer buf; VkDeviceSize off, size; } XfbArgs;
static void xfb_begin_run(const void *p) {
    const XfbArgs *a = p;
    R.xfb_bind(a->cb, 0, 1, &a->buf, &a->off, &a->size);
    R.xfb_begin(a->cb, 0, 0, NULL, NULL);
}
static void xfb_end_run(const void *p) { R.xfb_end(*(const VkCommandBuffer *)p, 0, 0, NULL, NULL); }

static bool invert(const double *m, double *o) {  // (4x4, row-major)
    double inv[16];
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    double det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (!(fabs(det) > 1e-30)) return false;
    for (int i = 0; i < 16; i++) o[i] = inv[i] / det;
    return true;
}

static void frame_start(uint64_t fr) {
    if (C.overflow && C.need > R.cap_verts && C.need < (48u << 20)) {  // (short last frame: a larger buffer)
        uint32_t want = C.need + C.need / 4;
        RBuf nb;
        if (rbuf_make(&nb, (VkDeviceSize)want * VERT, VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT |
                                                          VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                                          VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR)) {
            retire(&R.cap, NULL);
            R.cap = nb;
            R.cap_verts = want;
            LOG("[rts] capture buffer: %u vertices\n", want);
        }
    }
    C.frame = fr, C.cursor = 0, C.need = 0, C.overflow = false, C.nseg = 0, C.ndraws = 0, C.nfol = 0, C.ncasc = 0;
    C.map = NULL, C.missed = 0;
    C.pending = false;
}

// One of the sun's cascades: not a standard perspective camera (row 3 of the projection, c3 40-43: 0 0 -1 0 - a spot
// light's shadow, were the game to draw one), and the first cascade's light direction (the view's rotation, c3 0-10)
static bool sun_cascade(const float *c3, uint64_t c3_size) {
    if (!c3 || c3_size < 44 * 4) return false;
    if (c3[40] == 0 && c3[41] == 0 && c3[42] == -1 && c3[43] == 0) return false;
    return !C.ncasc || !memcmp(C.view, c3, sizeof C.view);
}

void rts_capture_missed(const float *c3, uint64_t c3_size) {
    if (!rts_on()) return;
    uint64_t fr = renderer_present_count();
    if (fr != C.frame) frame_start(fr);
    if (sun_cascade(c3, c3_size)) C.missed++;
}

bool rts_capture_begin(VkCommandBuffer cb, const float *c3, uint64_t c3_size, bool foliage, uint32_t nverts, TexBackend *map,
                       uint32_t layer) {
    if (!rts_on() || !c3 || c3_size < 44 * 4 || !nverts || nverts % 3 || !map) return false;
    uint64_t fr = renderer_present_count();
    if (fr != C.frame) frame_start(fr);
    if (!sun_cascade(c3, c3_size)) return false;  // (not the sun's: not missed either)
    if (C.map && C.map != map) { C.missed++; return false; }  // (one depth array: the sun's)
    const float *vp = c3 + 12;
    int c = 0;
    while (c < C.ncasc && memcmp(C.vp[c], vp, sizeof C.vp[c])) c++;
    if (c == C.ncasc) {  // a cascade not seen this frame
        if (C.ncasc == MAX_CASC) { C.missed++; return false; }
        double m[16];
        for (int i = 0; i < 16; i++) m[i] = vp[i];
        if (!invert(m, C.inv[c])) { C.missed++; return false; }
        memcpy(C.vp[c], vp, sizeof C.vp[c]);
        C.layer[c] = layer;
        C.map = map;
        if (!c) {  // the sun: the light's view's z row (c3 8-10), toward the light
            memcpy(C.view, c3, sizeof C.view);
            double l = sqrt((double)c3[8] * c3[8] + (double)c3[9] * c3[9] + (double)c3[10] * c3[10]);
            if (l > 1e-6) C.sun[0] = (float)(c3[8] / l), C.sun[1] = (float)(c3[9] / l), C.sun[2] = (float)(c3[10] / l);
        }
        C.ncasc++;
    }
    if (C.cursor + (uint64_t)nverts > R.cap_verts) {
        C.overflow = true;
        C.need = C.cursor + nverts > C.need ? C.cursor + nverts : C.need;
        return false;
    }
    int last = C.nseg - 1;
    if (last >= 0 && C.seg[last].casc == c && C.seg[last].foliage == foliage && C.seg[last].start + C.seg[last].count == C.cursor) {
        C.seg[last].count += nverts;
    } else {
        if (C.nseg == MAX_SEG) { C.missed++; return false; }
        C.seg[C.nseg].start = C.cursor, C.seg[C.nseg].count = nverts, C.seg[C.nseg].casc = (uint8_t)c;
        C.seg[C.nseg++].foliage = foliage;
    }
    XfbArgs a = {cb, R.cap.buf, (VkDeviceSize)C.cursor * VERT, (VkDeviceSize)nverts * VERT};
    rec_call(xfb_begin_run, &a, sizeof a);
    C.cursor += nverts;
    C.ndraws++;
    C.nfol += foliage;
    return true;
}

void rts_capture_end(VkCommandBuffer cb) { rec_call(xfb_end_run, &cb, sizeof cb); }

// ---------------------------------------------------------------- the mask

void rts_mask_seen(TexBackend *mask, TexBackend *depth, const float *world_c3, uint64_t c3_size) {
    if (!rts_on() || C.frame != renderer_present_count() || !C.nseg || !mask || !world_c3 || c3_size < 58 * 4) return;
    // the world camera: a perspective projection (row 3: 0 0 -1 0) with a far plane (c3 57) past 1 km
    const float *f = world_c3;
    if (f[40] != 0 || f[41] != 0 || f[42] != -1 || f[43] != 0 || !(f[57] > 1000)) return;
    C.pending = true, C.mask = mask, C.depth = depth;
    memcpy(C.world, world_c3, sizeof C.world);
}

bool rts_mask_pending(void) { return C.pending; }

static bool own_image(TexBackend *t, uint32_t w, uint32_t h, VkFormat fmt, VkImageUsageFlags usage) {
    if (t->image && t->width == w && t->height == h && t->format == fmt) return true;
    if (t->image) {
        vk_views_forget(t);
        vk_defer_image(t->image, t->mem);
        t->image = VK_NULL_HANDLE, t->mem = VK_NULL_HANDLE;
    }
    VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt,
                            .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                            .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage};
    VmaAllocationCreateInfo ai = {.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE};
    if (vmaCreateImage(g_vk.vma, &ci, &ai, &t->image, &t->mem, NULL) != VK_SUCCESS) return false;
    t->format = fmt, t->width = w, t->height = h, t->depth = 1, t->layers = 1, t->levels = 1, t->samples = 1;
    t->aspect = VK_IMAGE_ASPECT_COLOR_BIT, t->base_type = VK_IMAGE_VIEW_TYPE_2D;
    vk_image_init_layout(vk_cmd(), t->image, VK_IMAGE_ASPECT_COLOR_BIT);
    return true;
}

static bool ensure_as(RBuf *b, VkAccelerationStructureKHR *as, VkDeviceSize size, VkAccelerationStructureTypeKHR type) {
    if (*as && b->size >= size) return true;
    retire(b, as);
    VkDeviceSize want = size + size / 4 + 65536;
    if (!rbuf_make(b, want, VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR)) return false;
    VkAccelerationStructureCreateInfoKHR ci = {.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
                                               .buffer = b->buf, .size = want, .type = type};
    if (R.create_as(g_vk.dev, &ci, NULL, as) != VK_SUCCESS) { retire(b, NULL); return false; }
    return true;
}

// What the recorder thread records (rts_run): one block, freed after
typedef struct {
    VkCommandBuffer cb;
    int nruns;
    struct { uint32_t start, count; float inv[16]; int casc; } runs[MAX_SEG];
    int nblas;
    VkAccelerationStructureBuildGeometryInfoKHR info[MAX_CASC + 1];
    VkAccelerationStructureBuildRangeInfoKHR *range[MAX_CASC + 1];
    VkAccelerationStructureGeometryKHR *geom;  // all of the BLASes' geometries, then their ranges
    VkAccelerationStructureBuildRangeInfoKHR *ranges;
    VkAccelerationStructureGeometryKHR tgeom;
    VkAccelerationStructureBuildRangeInfoKHR trange;
    VkAccelerationStructureInstanceKHR inst[MAX_CASC];
    int ninst;
    float ubo[UBO_FLOATS];
    VkImageView depth_view, vis_view, map_view;
    VkImage mask, copy;
    uint32_t w, h;
    // (the handles as of this frame: the main thread may replace R's before the recorder runs this)
    VkBuffer cap_buf, ubo_buf, inst_buf;
    VkAccelerationStructureKHR tlas;
} RunBlock;

static void barrier(VkCommandBuffer cb, VkPipelineStageFlags2 ss, VkAccessFlags2 sa, VkPipelineStageFlags2 ds, VkAccessFlags2 da) {
    VkMemoryBarrier2 mb = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2, .srcStageMask = ss, .srcAccessMask = sa,
                           .dstStageMask = ds, .dstAccessMask = da};
    VkDependencyInfo di = {.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &mb};
    vkCmdPipelineBarrier2(cb, &di);
}
#define ALL VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
#define RW (VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT)

static void run_rt(const void *p) {
    RunBlock *b = *(RunBlock *const *)p;
    VkCommandBuffer cb = b->cb;
    // the captured vertices, and the last frame's rays and builds done with what is rebuilt now
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT | VK_ACCESS_2_TRANSFORM_FEEDBACK_WRITE_BIT_EXT, ALL, RW);
    vkCmdUpdateBuffer(cb, b->ubo_buf, 0, sizeof b->ubo, b->ubo);
    if (b->ninst) vkCmdUpdateBuffer(cb, b->inst_buf, 0, b->ninst * sizeof b->inst[0], b->inst);
    // 1. the world positions, in place
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.xform);
    VkDescriptorBufferInfo cbi = {b->cap_buf, 0, VK_WHOLE_SIZE};
    VkWriteDescriptorSet w0 = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0, .descriptorCount = 1,
                               .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &cbi};
    R.push_set(cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.xform_layout, 0, 1, &w0);
    for (int i = 0; i < b->nruns; i++) {
        struct { float inv[16]; uint32_t start, count; } pc;
        memcpy(pc.inv, b->runs[i].inv, sizeof pc.inv);
        pc.start = b->runs[i].start, pc.count = b->runs[i].count;
        vkCmdPushConstants(cb, R.xform_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
        vkCmdDispatch(cb, (pc.count + 255) / 256, 1, 1);
    }
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    // 2. one bottom-level structure per cascade, then the top-level one over them
    const VkAccelerationStructureBuildRangeInfoKHR *const *rp = (const VkAccelerationStructureBuildRangeInfoKHR *const *)b->range;
    if (b->nblas) R.build(cb, (uint32_t)b->nblas, b->info, rp);
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    const VkAccelerationStructureBuildRangeInfoKHR *tr = &b->trange;
    R.build(cb, 1, &b->info[b->nblas], &tr);
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    // 3. the rays
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.trace);
    VkWriteDescriptorSetAccelerationStructureKHR wa = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR,
                                                       .accelerationStructureCount = 1, .pAccelerationStructures = &b->tlas};
    VkDescriptorImageInfo di = {R.nearest, b->depth_view, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo vi = {VK_NULL_HANDLE, b->vis_view, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo ui = {b->ubo_buf, 0, sizeof b->ubo};
    VkDescriptorImageInfo mi = {R.nearest, b->map_view, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w[5] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = &wa, .dstBinding = 0, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 1, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &di},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 2, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &vi},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 3, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &ui},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 4, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &mi}};
    R.push_set(cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.trace_layout, 0, 5, w);
    vkCmdDispatch(cb, (b->w + 7) / 8, (b->h + 7) / 8, 1);
    // 4. the game's mask, copied for the compose pass to read while it writes the mask
    VkImageCopy ic = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                      .extent = {b->w, b->h, 1}};
    vkCmdCopyImage(cb, b->mask, VK_IMAGE_LAYOUT_GENERAL, b->copy, VK_IMAGE_LAYOUT_GENERAL, 1, &ic);
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    // 5. the capture buffer back to NaN (inactive triangles) for the next frame: what a draw writes less than its
    // stretch (a strip cut by restarts) never forms a triangle of last frame's leftovers
    vkCmdFillBuffer(cb, b->cap_buf, 0, VK_WHOLE_SIZE, 0x7fc00000u);
    barrier(cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    free(b->geom);
    free(b);
}

// (0.3.13) Ambient occlusion with the shadows' rays (trace_src's .b), put on the composited scene (exec.c rt_ao_apply)
static struct { uint64_t frame; VkImageView vis, depth; float pc[4]; VkAccelerationStructureKHR tlas; VkBuffer ubo; } AO;
static float refl_strength(void);  // (0.3.19: the water reflections', below)
static bool ao_wanted(void) {
    static int ao = -1;  // (SAVAGEWIND_RT_AO=0: none)
    if (ao < 0) ao = !(getenv("SAVAGEWIND_RT_AO") && !strcmp(getenv("SAVAGEWIND_RT_AO"), "0"));
    return ao;
}

bool rts_ao(VkImageView *vis, VkImageView *depth, float pc[4]) {
    if (!ao_wanted() || !rts_on() || AO.frame != renderer_present_count() || !AO.vis || !AO.depth) return false;
    *vis = AO.vis, *depth = AO.depth;
    memcpy(pc, AO.pc, sizeof AO.pc);
    return true;
}

bool rts_run(VkCommandBuffer cb, TexBackend *(*scene_depth)(const float *world_c3), RtsCompose *out) {
    C.pending = false;
    reap();
    if (!rts_on() || C.frame != renderer_present_count() || !C.nseg || C.overflow) return false;
    TexBackend *mask = C.mask, *depth = scene_depth(C.world);
    static int no_depth;
    if (!depth || !depth->image) {
        if (no_depth++ < 3) LOG("[rts] no scene depth of the world camera this frame: the game's shadows\n");
        return false;
    }
    if (!mask->image) return false;
    uint32_t w = mask->width, h = mask->height;
    if (!own_image(&R.vis, w, h, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT) ||
        !own_image(&R.copy, w, h, mask->format, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT))
        return false;
    RunBlock *b = calloc(1, sizeof *b);
    if (!b) return false;
    b->cb = cb, b->w = w, b->h = h, b->mask = mask->image, b->copy = R.copy.image;
    static const VkComponentMapping id = {0};
    b->depth_view = vk_image_view(depth, VK_IMAGE_VIEW_TYPE_2D, depth->format, 0, 1, 0, 1, id, VK_IMAGE_ASPECT_DEPTH_BIT);
    b->vis_view = vk_image_view(&R.vis, VK_IMAGE_VIEW_TYPE_2D, R.vis.format, 0, 1, 0, 1, id, VK_IMAGE_ASPECT_COLOR_BIT);
    if (!C.map || !C.map->image) { free(b); return false; }
    b->map_view = vk_image_view(C.map, VK_IMAGE_VIEW_TYPE_2D_ARRAY, C.map->format, 0, 1, 0, C.map->layers ? C.map->layers : 1, id,
                                VK_IMAGE_ASPECT_DEPTH_BIT);
    // the transform runs: each stretch of one cascade
    for (int i = 0; i < C.nseg; i++) {
        int last = b->nruns - 1;
        if (last >= 0 && b->runs[last].start + b->runs[last].count == C.seg[i].start && b->runs[last].casc == C.seg[i].casc) {
            b->runs[last].count += C.seg[i].count;
            continue;
        }
        b->runs[b->nruns].start = C.seg[i].start, b->runs[b->nruns].count = C.seg[i].count, b->runs[b->nruns].casc = C.seg[i].casc;
        for (int k = 0; k < 16; k++) b->runs[b->nruns].inv[k] = (float)C.inv[C.seg[i].casc][k];
        b->nruns++;
    }
    // the geometries: each run of draws one, per cascade
    b->geom = calloc((size_t)C.nseg, sizeof *b->geom + sizeof *b->ranges);
    if (!b->geom) { free(b); return false; }
    b->ranges = (VkAccelerationStructureBuildRangeInfoKHR *)(b->geom + C.nseg);
    VkDeviceSize scratch = 0, scr_off[MAX_CASC + 1];
    uint32_t tris = 0;
    int g = 0;
    for (int c = 0; c < C.ncasc; c++) {
        int g0 = g;
        uint32_t maxp[MAX_SEG];
        for (int i = 0; i < C.nseg; i++) {
            if (C.seg[i].casc != c) continue;
            VkAccelerationStructureGeometryKHR *ge = &b->geom[g];
            ge->sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
            ge->geometryType = VK_GEOMETRY_TYPE_TRIANGLES_KHR;
            ge->flags = C.seg[i].foliage ? 0 : VK_GEOMETRY_OPAQUE_BIT_KHR;
            ge->geometry.triangles = (VkAccelerationStructureGeometryTrianglesDataKHR){
                .sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
                .vertexFormat = VK_FORMAT_R32G32B32_SFLOAT,
                .vertexData.deviceAddress = R.cap.addr + (VkDeviceAddress)C.seg[i].start * VERT,
                .vertexStride = VERT, .maxVertex = C.seg[i].count - 1, .indexType = VK_INDEX_TYPE_NONE_KHR};
            b->ranges[g] = (VkAccelerationStructureBuildRangeInfoKHR){.primitiveCount = C.seg[i].count / 3};
            maxp[g - g0] = C.seg[i].count / 3;
            tris += C.seg[i].count / 3;
            g++;
        }
        if (g == g0) continue;
        VkAccelerationStructureBuildGeometryInfoKHR *bi = &b->info[b->nblas];
        *bi = (VkAccelerationStructureBuildGeometryInfoKHR){
            .sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
            .type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR,
            .flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT_KHR,
            .mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR, .geometryCount = (uint32_t)(g - g0), .pGeometries = &b->geom[g0]};
        VkAccelerationStructureBuildSizesInfoKHR sz = {.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
        R.sizes(g_vk.dev, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, bi, maxp, &sz);
        if (!ensure_as(&R.blas_buf[c], &R.blas[c], sz.accelerationStructureSize, VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR)) {
            free(b->geom), free(b);
            return false;
        }
        bi->dstAccelerationStructure = R.blas[c];
        scr_off[b->nblas] = scratch;
        scratch += (sz.buildScratchSize + R.scratch_align - 1) / R.scratch_align * R.scratch_align;
        b->range[b->nblas] = &b->ranges[g0];
        VkAccelerationStructureDeviceAddressInfoKHR ai = {.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR,
                                                          .accelerationStructure = R.blas[c]};
        VkAccelerationStructureInstanceKHR *in = &b->inst[b->ninst++];
        in->transform.matrix[0][0] = in->transform.matrix[1][1] = in->transform.matrix[2][2] = 1.0f;
        in->mask = (uint8_t)(1u << c);
        in->flags = VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR;
        in->accelerationStructureReference = R.as_addr(g_vk.dev, &ai);
        b->nblas++;
    }
    if (!b->nblas) { free(b->geom), free(b); return false; }
    // the top level
    b->tgeom = (VkAccelerationStructureGeometryKHR){
        .sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR, .geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR,
        .geometry.instances = {.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR,
                               .data.deviceAddress = R.inst.addr}};
    VkAccelerationStructureBuildGeometryInfoKHR *ti = &b->info[b->nblas];
    *ti = (VkAccelerationStructureBuildGeometryInfoKHR){
        .sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR, .type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR,
        .flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR, .mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR,
        .geometryCount = 1, .pGeometries = &b->tgeom};
    uint32_t ninst = (uint32_t)b->ninst;
    VkAccelerationStructureBuildSizesInfoKHR tsz = {.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
    R.sizes(g_vk.dev, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, ti, &ninst, &tsz);
    if (!ensure_as(&R.tlas_buf, &R.tlas, tsz.accelerationStructureSize, VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR)) {
        free(b->geom), free(b);
        return false;
    }
    ti->dstAccelerationStructure = R.tlas;
    b->tlas = R.tlas, b->cap_buf = R.cap.buf, b->ubo_buf = R.ubo.buf, b->inst_buf = R.inst.buf;
    scr_off[b->nblas] = scratch;
    scratch += (tsz.buildScratchSize + R.scratch_align - 1) / R.scratch_align * R.scratch_align;
    b->trange.primitiveCount = ninst;
    if (R.scratch.size < scratch) {
        retire(&R.scratch, NULL);
        if (!rbuf_make(&R.scratch, scratch + scratch / 4 + R.scratch_align, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)) {
            free(b->geom), free(b);
            return false;
        }
    }
    VkDeviceAddress sbase = (R.scratch.addr + R.scratch_align - 1) / R.scratch_align * R.scratch_align;
    for (int i = 0; i <= b->nblas; i++) b->info[i].scratchData.deviceAddress = sbase + scr_off[i];
    // the rays' constants
    float *u = b->ubo;
    {
        double m[16], inv[16];
        for (int i = 0; i < 16; i++) m[i] = C.world[12 + i];
        if (!invert(m, inv)) { free(b->geom), free(b); return false; }
        for (int i = 0; i < 16; i++) u[i] = (float)inv[i];
    }
    for (int c = 0; c < MAX_CASC; c++)
        for (int i = 0; i < 16; i++) u[16 + c * 16 + i] = c < C.ncasc ? C.vp[c][i] : 0;
    static float cone = -1, bias_m = -1, bias_d = -1;
    if (cone < 0) {  // (testing: SAVAGEWIND_RTS_CONE=<tan>, SAVAGEWIND_RTS_BIAS=<metres>,<per metre>)
        const char *e = getenv("SAVAGEWIND_RTS_CONE");
        // (0.3.13: 0.005, about the sun's own disc - 0.012 softened the shadows well past the game's own; 0.3.20:
        // 0.0025, sharper than the sun's disc, as the game's own shadows are near Link)
        cone = e ? (float)atof(e) : 0.0025f;
        e = getenv("SAVAGEWIND_RTS_BIAS");
        if (!e || sscanf(e, "%f,%f", &bias_m, &bias_d) != 2) bias_m = 0.03f, bias_d = 0.0025f;
    }
    u[144] = C.sun[0], u[145] = C.sun[1], u[146] = C.sun[2], u[147] = cone;
    u[148] = C.world[47], u[149] = C.world[51], u[150] = C.world[55], u[151] = 0;  // (the camera matrix's position column)
    extern bool renderer_origin_lower_left(void);
    extern uint32_t nvn_depth_mode(void);
    u[152] = renderer_origin_lower_left() ? 1.0f : -1.0f, u[153] = nvn_depth_mode() == 0 ? 1.0f : 0.0f;
    u[154] = (float)C.ncasc, u[155] = RAYS;
    // (alpha-tested casters within 30 cm of the surface - the grass the pixel stands in - let the rays through)
    u[156] = bias_m, u[157] = bias_d, u[158] = 3000.0f, u[159] = 0.3f;
    for (int c = 0; c < MAX_CASC; c++) u[160 + c * 4] = c < C.ncasc ? (float)C.layer[c] : 0;
    u[192] = 1.5f, u[193] = ao_wanted() ? AO_RAYS : 0, u[194] = u[195] = 0;
    for (int i = 0; i < 16; i++) u[196 + i] = C.world[12 + i];  // (0.3.19: the world camera's own, for the reflections)
    u[212] = 400.0f, u[213] = 0, u[214] = (float)WATER_ID, u[215] = refl_strength();
    // (b is the recorder thread's from here - run_rt frees it: what's needed of it after, read now)
    VkImageView depth_view = b->depth_view, vis_view = b->vis_view;
    float gl_depth = u[153];
    rec_call(run_rt, &b, sizeof b);
    C.last_tris = tris, C.last_casc = (uint32_t)C.ncasc, C.runs++;
    if (C.runs == 1 || C.runs % 3600 == 0)
        LOG("[rts] frame %llu: %d caster draws (%d alpha-tested, %d not captured), %u triangles, %d cascades (layers %u %u %u), "
            "mask %ux%u, maps %ux%ux%u\n", (unsigned long long)C.frame, C.ndraws, C.nfol, C.missed, tris, C.ncasc, C.layer[0],
            C.layer[1], C.layer[2], w, h, C.map->width, C.map->height, C.map->layers);
    // the compose pass (exec.c): the rays' result, the game's mask, the depth
    out->mask = mask, out->vis = &R.vis, out->copy = &R.copy, out->depth_view = depth_view;
    memset(out->pc, 0, sizeof out->pc);
    static int view = -1;  // (testing: SAVAGEWIND_RTS_VIEW=1: the rays alone, the foliage lit)
    if (view < 0) view = getenv("SAVAGEWIND_RTS_VIEW") ? atoi(getenv("SAVAGEWIND_RTS_VIEW")) : 0;
    out->pc[0] = (float)view;
    out->pc[1] = C.world[38], out->pc[2] = C.world[39], out->pc[3] = gl_depth;  // (the distance: B / (z + A))
    // (casters not traced this frame: the game's shadows kept as well - 0.3.20: for the next 2 seconds too, so a
    // caster whose variant is still being built doesn't flip the shadows between the two every other frame)
    static unsigned hold;
    if (C.missed) hold = 120;
    else if (hold) hold--;
    out->pc[4] = hold ? 1.0f : 0.0f;
    AO.frame = C.frame, AO.vis = vis_view, AO.depth = depth_view;
    AO.tlas = R.tlas, AO.ubo = R.ubo.buf;
    AO.pc[0] = 0.85f, AO.pc[1] = C.world[38], AO.pc[2] = C.world[39], AO.pc[3] = gl_depth;  // (strength; the distance)
    return true;
}

// ---------------------------------------------------------------- (0.3.19) ray-traced reflections on water

static struct { uint64_t frame; TexBackend *mat, *nrm; } GB;
void rts_gbuf_seen(TexBackend *mat, TexBackend *nrm) {
    GB.frame = renderer_present_count(), GB.mat = mat, GB.nrm = nrm;
}

static float refl_strength(void) {
    static float k = -1;  // (testing: SAVAGEWIND_RT_REFL=<strength>, 0: none)
    if (k < 0) k = getenv("SAVAGEWIND_RT_REFL") ? (float)atof(getenv("SAVAGEWIND_RT_REFL")) : 2.0f;
    return k;
}

static bool refl_setup(void) {
    if (R.rf_tried) return R.rf_ok;
    R.rf_tried = true;
    VkDescriptorSetLayoutBinding tb[7] = {
        {0, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {5, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {6, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL}};
    VkDescriptorSetLayoutCreateInfo tl = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                          .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, .bindingCount = 7,
                                          .pBindings = tb};
    if (vkCreateDescriptorSetLayout(g_vk.dev, &tl, NULL, &R.rf_set) != VK_SUCCESS) return false;
    VkPipelineLayoutCreateInfo pl = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
                                     .pSetLayouts = &R.rf_set};
    if (vkCreatePipelineLayout(g_vk.dev, &pl, NULL, &R.rf_layout) != VK_SUCCESS) return false;
    R.rf = compute_pipeline(refl_src, "rts_refl.comp", R.rf_layout);
    if (!R.rf) {
        LOG("[rts] the water reflections' shader failed to compile: Ray-Tracing without them\n");
        return false;
    }
    LOG("[rts] ray-traced water reflections ready (material %d)\n", WATER_ID);
    return R.rf_ok = true;
}

typedef struct {
    VkCommandBuffer cb;
    VkAccelerationStructureKHR tlas;
    VkBuffer ubo;
    VkImageView depth, out, color, mat, nrm;
    uint32_t w, h;
} RfBlock;

static void run_refl(const void *p) {
    const RfBlock *b = (const RfBlock *)p;
    barrier(b->cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
    vkCmdBindPipeline(b->cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.rf);
    VkWriteDescriptorSetAccelerationStructureKHR wa = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR,
                                                       .accelerationStructureCount = 1, .pAccelerationStructures = &b->tlas};
    VkDescriptorImageInfo di = {R.nearest, b->depth, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo oi = {VK_NULL_HANDLE, b->out, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo ui = {b->ubo, 0, UBO_FLOATS * 4};
    VkDescriptorImageInfo ci = {R.nearest, b->color, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo mi = {R.nearest, b->mat, VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo ni = {R.nearest, b->nrm, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w[7] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = &wa, .dstBinding = 0, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 1, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &di},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 2, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &oi},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 3, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &ui},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 4, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &ci},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 5, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &mi},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 6, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &ni}};
    R.push_set(b->cb, VK_PIPELINE_BIND_POINT_COMPUTE, R.rf_layout, 0, 7, w);
    vkCmdDispatch(b->cb, (b->w + 7) / 8, (b->h + 7) / 8, 1);
    barrier(b->cb, ALL, VK_ACCESS_2_MEMORY_WRITE_BIT, ALL, RW);
}

static VkImageView color_view(TexBackend *t) {
    static const VkComponentMapping id = {0};
    return vk_image_view(t, VK_IMAGE_VIEW_TYPE_2D, t->format, 0, 1, 0, 1, id, VK_IMAGE_ASPECT_COLOR_BIT);
}

bool rts_refl_on(void) {
    return rts_on() && refl_strength() > 0 && !(R.rf_tried && !R.rf_ok) && GB.frame == renderer_present_count() &&
           GB.mat && GB.nrm && AO.frame == renderer_present_count() && AO.tlas && AO.depth;
}

bool rts_refl(VkCommandBuffer cb, VkImageView color, VkImageView *out) {
    if (!rts_refl_on()) return false;
    TexBackend *m = GB.mat, *n = GB.nrm;
    if (!m->image || !n->image || m->layers != 1 || n->layers != 1 || m->samples != 1 || n->samples != 1 ||
        m->aspect != VK_IMAGE_ASPECT_COLOR_BIT || n->aspect != VK_IMAGE_ASPECT_COLOR_BIT)
        return false;
    if (!refl_setup()) return false;
    if (!own_image(&R.refl, m->width, m->height, VK_FORMAT_R16G16B16A16_SFLOAT,
                   VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT))
        return false;
    RfBlock b = {.cb = cb, .tlas = AO.tlas, .ubo = AO.ubo, .depth = AO.depth, .color = color, .mat = color_view(m),
                 .nrm = color_view(n), .out = color_view(&R.refl), .w = R.refl.width, .h = R.refl.height};
    rec_call(run_refl, &b, sizeof b);
    *out = b.out;
    return true;
}

bool rts_available(void) { return g_vk.rt; }

void rts_status(char *out, size_t n) {
    if (!g_vk.rt) snprintf(out, n, "Not available: this graphics card or driver has no hardware ray tracing for Vulkan.");
    else if (!g_settings.rt_shadows) snprintf(out, n, "Off.");
    else if (R.tried && !R.ok) snprintf(out, n, "Not running: %s.", R.why);
    else if (!C.runs) snprintf(out, n, "On - waiting for the game's sun shadows (outdoors, in daylight).");
    else snprintf(out, n, "On: shadows%s%s, %u triangles from %u cascades in the last frame traced.",
                  ao_wanted() ? ", ambient occlusion" : "",
                  refl_strength() <= 0 ? "" : R.rf_tried && !R.rf_ok ? " (water reflections failed to start)" : " and water reflections",
                  C.last_tris, C.last_casc);
}

void rts_report(void) {
    LOG("[rtr] ray-traced shadows: setting %s, ray tracing %s, %s; this frame so far: %d caster draws captured (%d "
        "alpha-tested), %u vertices of %u, %d runs, %d cascades%s, sun (%.3f %.3f %.3f)\n",
        g_settings.rt_shadows ? "on" : "off", g_vk.rt ? "available" : "not available", R.tried ? (R.ok ? "ready" : R.why) : "not set up",
        C.ndraws, C.nfol, C.cursor, R.cap_verts, C.nseg, C.ncasc, C.overflow ? " (overflow)" : "", C.sun[0], C.sun[1], C.sun[2]);
    LOG("[rtr] ray-traced shadows: %d caster draws not captured this frame\n", C.missed);
}
