#version 120
// Sunstone lighting for lit textured models: hemispheric sky/ground ambient, wrapped diffuse, energy-conserving
// Blinn-Phong on the material's own specular, and a sun-side rim light. sunstoneLight 0 keeps the game's terms.
//
// Material detail (sunstoneMatDetail) adds a material's surface to the art (grain, wear, cavities, sheen) from the
// procedural snippets of tools/materials, spliced into the BEGIN/END MATERIALS block by tools/build_materials.py.
//
// Human skin and real hair on the worms (the Worm skin and Worm hair settings) are drawn here too, where each fragment's
// unlit colour is the texture's own texel, before any light or grade: no colour has to be guessed from the finished frame.
// - Skin: the worm's own material (body, tail, hands, eyes and lids, nothing else) with a texel of the skin's colour
//   family (SkinFamily). The tone replaces the peach, keeping the texel's darker drawn detail, and is shaded as skin:
//   blood at the cheeks, nose and lips and an oily T-zone, placed from the worm's centre and facing. Its detail is sized
//   to show from the game's own distance: blotches of blood and pigment, a grain never finer than a few pixels (seen
//   mostly in the sheen), folds and wrinkles round the neck and down the back, moles, blemishes and (most fair worms)
//   freckles, round on the skin wherever the texture is stretched; pores for close views, fixed to the surface and faded
//   out below a few pixels. Light carried under the skin (softer bumps per channel, wrap and a red band at the
//   terminator, warm shade lifted on a darker tone, a glow at thin edges); a matte broad sheen and a tight oily one on the
//   T-zone, and the sky's reflection; a soft roll-off that keeps the colour and the highlights in bright light; and a
//   dither before the 8-bit target. The eye whites go white and wet, shaded at their edge.
// - The parts a worm wears share one material with many props, so they are told apart by their texture (Fingerprint:
//   three texels at fixed places, compared with a table made from the game's files by tools/make_fingerprints.py): a glove
//   with the worm's bare skin in it (its skin texels take the tone), a moustache, or a hair hat.
// - Hair: the strands of the texture lit as hair fibres (two Kajiya-Kay highlights along the strands), in a natural
//   colour (the moustache's own colour family, or the worm's own for Mixed), or a dyed hat's own colour.
// - Each fragment of skin (and Mixed hair) takes its worm from the nearest of the 16 worm centres Sunstone's Lua sends
//   (sunstoneWormN: centre, tone, seed, facing and hair colour), the fragment's world position worked out from the view
//   matrix; with none sent it takes the setting's tone and no face.
// - The skin marks itself in the alpha it writes (SkinMark) for Bloodsand and Kindjal, which find it there instead of by
//   colour; PostProcess.RecombineWorms.glsl carries the mark through the game's own composition of the frame. The game's
//   own peach is marked too (Worm skin Game), so they find it under any light or a poisoned worm's tint as well.
uniform sampler2D texture0;
uniform vec3 lightDiffuseCol;
uniform vec3 lightAmbientCol;
uniform vec3 lightSpecularCol;
uniform mat4 materialMatrix;   // columns: specular colour, emissive colour, rim colour, (rim power, gloss)
// The vertex program's view matrix; column 1 is the world's up axis in eye space.
uniform mat4 view;

uniform float sunstoneLight;        // 0 game lighting, 1 Sunstone; + 10 shows the lighting on grey
uniform vec3 sunstoneSky;           // ambient tint for surfaces facing up
uniform vec3 sunstoneGround;        // ambient tint for surfaces facing down
uniform float sunstoneWrap;         // light wrap past the terminator (soft, rounded shading)
uniform float sunstoneSpecular;     // scale of the material's specular
uniform float sunstoneRim;          // rim light strength
uniform float sunstoneSunGain;      // sun (diffuse) gain
uniform float sunstoneAmbientGain;  // ambient gain
uniform vec3 sunstoneSunTint;       // tint of the direct light
uniform vec3 sunstoneShadowTint;    // tint of the ambient light
uniform float sunstoneTint;         // how far the two tints apply (0 none)
uniform float sunstoneGroundDip;    // ambient dip on surfaces facing down (0 none)
uniform float sunstoneFoliage;      // leaf hue shift toward yellow-green (degrees)
uniform float sunstoneSplit;        // pixels left of this x keep the game's lighting (comparisons)
uniform float sunstoneSkin;         // 1 human skin on the worms (0 the game's peach)
uniform vec3 sunstoneSkinTone;      // the setting's skin albedo (for a worm with no sunstoneWormN)
uniform float sunstoneSkinMixed;    // 1 the worms' own data is sent in sunstoneWormN (any tone, and Mixed hair)
uniform float sunstoneHair;         // 0 the game's moustaches, 1 natural hair, 2 a natural colour per worm
uniform float sunstoneWigs;         // 1 hair hats are drawn as hair too
uniform float sunstoneSkinSss;      // light carried under the skin: wrap past the terminator, glow at thin edges (0 none)
uniform float sunstoneSkinSheen;    // the skin's sheen (both lobes and the sky's reflection)
uniform float sunstoneSkinPores;    // blotches, grain, folds and wrinkles, moles and freckles, pores
uniform float sunstoneSkinFlush;    // blood showing through: cheeks, nose, lips (0 none)
uniform float sunstoneSkinShade;    // how far a darker tone's shade is lifted, as a camera exposes for it (0 none)
uniform float sunstoneSkinChroma;   // how much of the scene light's own colour the skin takes (1 all; per theme)
uniform vec3 sunstoneSkinAmbient;   // tint of the ambient light on the skin (1 1 1 none; per theme)
uniform float sunstoneSkinVivid;    // the skin's colour against its grey, ahead of a theme's grade that greys it (1 none)
uniform float sunstoneHairSheen;    // the hair's highlights
uniform float sunstoneSkinFlag;     // 1 marks skin in the scene alpha (see SkinMark)
uniform float sunstoneSkinDebug;    // 1 what is skin and hair; 2 which worm a fragment takes its colours from; 3 the face; 4 sheen
// The worms: centre (world units, the body's middle) and in w 0 for a free slot, or 1 + the worm's data as an integer
// (exact in a float): hair colour (1..10, HairAlbedo; 0 its moustache's own) * 2^15 + tone (1..7, TONES; 0 the setting's)
// * 2^12 + seed (0..63) * 2^6 + facing (yaw in 64 steps: the face looks along (sin yaw, 0, cos yaw)).
uniform vec4 sunstoneWorm0, sunstoneWorm1, sunstoneWorm2, sunstoneWorm3, sunstoneWorm4, sunstoneWorm5, sunstoneWorm6, sunstoneWorm7,
             sunstoneWorm8, sunstoneWorm9, sunstoneWorm10, sunstoneWorm11, sunstoneWorm12, sunstoneWorm13, sunstoneWorm14, sunstoneWorm15;

// BEGIN FINGERPRINTS (generated by tools/make_fingerprints.py; do not edit by hand)
// 59 textures: Gloves.AlienBreed, Gloves.Cowboy, Gloves.Cowboy.Black, Gloves.Cowboy.Red, Gloves.Cowboy.White, Gloves.Dino, Gloves.FighterPilot, Gloves.FuManChu, Gloves.Knight, Gloves.Knight.Gold, Gloves.Knight.Green, Gloves.Knight.White, Gloves.Pirate, Gloves.Pirate.Black, Gloves.Pirate.Green, Gloves.Pirate.White, Gloves.Punk, Gloves.Punk.Green, Gloves.Punk.Grey, Gloves.Punk.Red, Gloves.Ringed, Gloves.Spacesuit, Gloves.Spacesuit.Blue, Gloves.Spacesuit.Grey, Gloves.Spacesuit.Pink, Gloves.Sport, Gloves.SuperHero, Hat.Afro, Hat.Frankenstein, Hat.Pigtails, Hat.Pigtails.Bl, Hat.Pigtails.Bnd, Hat.Prehistoric, Hat.Punk, Hat.Punk.Bl, Hat.Punk.Gr, Hat.Punk.Y, Hat.QueenOfSheba, Mustache.Afro, Mustache.Afro.Blond, Mustache.Afro.Grey, Mustache.Afro.Red, Mustache.Chinese, Mustache.Cowboy, Mustache.Cowboy.Black, Mustache.Cowboy.Blond, Mustache.Cowboy.Grey, Mustache.Curly, Mustache.Curly.Blond, Mustache.Curly.Grey, Mustache.Curly.Red, Mustache.Professor, Mustache.Scott, Mustache.Small.Red, Mustache.Viking, Mustache.Viking.Black, Mustache.Viking.Grey, Mustache.Viking.Red
const vec2 PROBE_A = vec2(0.0546875, 0.9765625);
const vec2 PROBE_B = vec2(0.9609375, 0.4609375);
const vec2 PROBE_C = vec2(0.6484375, 0.1953125);
const float FP_TOL = 0.03;
const int FP_N = 59;
// probe A colour, class * 16 + hair colour (sorted by red, see Fingerprint)
const vec4 FP_A[FP_N] = vec4[FP_N](
    vec4(0.043, 0.314, 0.475, 48.0),
    vec4(0.043, 0.412, 0.188, 48.0),
    vec4(0.125, 0.137, 0.129, 49.0),
    vec4(0.133, 0.122, 0.188, 33.0),
    vec4(0.153, 0.114, 0.125, 33.0),
    vec4(0.161, 0.165, 0.122, 34.0),
    vec4(0.173, 0.376, 0.478, 48.0),
    vec4(0.192, 0.169, 0.145, 34.0),
    vec4(0.2, 0.177, 0.116, 16.0),
    vec4(0.203, 0.168, 0.222, 16.0),
    vec4(0.247, 0.425, 0.302, 16.0),
    vec4(0.259, 0.545, 0.188, 16.0),
    vec4(0.26, 0.228, 0.261, 16.0),
    vec4(0.261, 0.175, 0.23, 16.0),
    vec4(0.325, 0.412, 0.58, 16.0),
    vec4(0.337, 0.424, 0.475, 16.0),
    vec4(0.354, 0.438, 0.15, 16.0),
    vec4(0.396, 0.137, 0.035, 48.0),
    vec4(0.408, 0.494, 0.616, 16.0),
    vec4(0.411, 0.498, 0.619, 16.0),
    vec4(0.411, 0.498, 0.619, 16.0),
    vec4(0.411, 0.498, 0.619, 16.0),
    vec4(0.424, 0.71, 0.882, 16.0),
    vec4(0.444, 0.331, 0.198, 16.0),
    vec4(0.445, 0.334, 0.201, 16.0),
    vec4(0.494, 0.152, 0.244, 16.0),
    vec4(0.506, 0.397, 0.237, 65.0),
    vec4(0.522, 0.361, 0.035, 48.0),
    vec4(0.553, 0.241, 0.156, 16.0),
    vec4(0.595, 0.276, 0.085, 37.0),
    vec4(0.595, 0.276, 0.085, 33.0),
    vec4(0.595, 0.276, 0.085, 41.0),
    vec4(0.595, 0.276, 0.085, 40.0),
    vec4(0.651, 0.175, 0.177, 16.0),
    vec4(0.663, 0.408, 0.188, 16.0),
    vec4(0.671, 0.384, 0.118, 40.0),
    vec4(0.698, 0.722, 0.784, 41.0),
    vec4(0.749, 0.749, 0.651, 16.0),
    vec4(0.753, 0.69, 0.533, 65.0),
    vec4(0.757, 0.757, 0.718, 41.0),
    vec4(0.768, 0.721, 0.702, 16.0),
    vec4(0.78, 0.659, 0.384, 38.0),
    vec4(0.788, 0.733, 0.753, 41.0),
    vec4(0.831, 0.455, 0.2, 40.0),
    vec4(0.831, 0.376, 0.478, 48.0),
    vec4(0.831, 0.635, 0.306, 54.0),
    vec4(0.847, 0.922, 0.886, 41.0),
    vec4(0.859, 0.902, 0.933, 16.0),
    vec4(0.866, 0.89, 0.831, 42.0),
    vec4(0.868, 0.778, 0.704, 16.0),
    vec4(0.882, 0.6, 0.431, 16.0),
    vec4(0.89, 0.694, 0.376, 38.0),
    vec4(0.89, 0.349, 0.188, 40.0),
    vec4(0.937, 0.565, 0.0, 40.0),
    vec4(0.969, 0.608, 0.471, 16.0),
    vec4(1.0, 0.627, 0.435, 16.0),
    vec4(1.0, 0.71, 0.776, 16.0),
    vec4(1.0, 0.886, 0.561, 38.0),
    vec4(1.0, 0.851, 0.407, 65.0)
);
// probe B colour, mean luminance of the hair
const vec4 FP_B[FP_N] = vec4[FP_N](
    vec4(0.165, 0.451, 0.608, 0.339),
    vec4(0.165, 0.561, 0.29, 0.365),
    vec4(0.132, 0.142, 0.134, 0.2),
    vec4(0.239, 0.212, 0.345, 0.217),
    vec4(0.114, 0.082, 0.094, 0.156),
    vec4(0.31, 0.259, 0.231, 0.252),
    vec4(0.208, 0.514, 0.651, 0.4),
    vec4(0.106, 0.094, 0.078, 0.131),
    vec4(0.925, 0.515, 0.465, 1.0),
    vec4(0.194, 0.163, 0.22, 1.0),
    vec4(0.966, 0.627, 0.446, 1.0),
    vec4(0.244, 0.526, 0.179, 1.0),
    vec4(0.258, 0.229, 0.258, 1.0),
    vec4(0.966, 0.627, 0.446, 1.0),
    vec4(0.216, 0.302, 0.494, 1.0),
    vec4(0.255, 0.333, 0.373, 1.0),
    vec4(0.352, 0.435, 0.148, 1.0),
    vec4(0.569, 0.255, 0.118, 0.295),
    vec4(0.31, 0.377, 0.519, 1.0),
    vec4(0.315, 0.383, 0.314, 1.0),
    vec4(0.275, 0.281, 0.296, 1.0),
    vec4(0.351, 0.281, 0.296, 1.0),
    vec4(0.333, 0.549, 0.667, 1.0),
    vec4(0.438, 0.329, 0.196, 1.0),
    vec4(0.188, 0.165, 0.157, 1.0),
    vec4(0.491, 0.148, 0.242, 1.0),
    vec4(0.522, 0.425, 0.364, 0.197),
    vec4(0.702, 0.506, 0.118, 0.458),
    vec4(0.55, 0.24, 0.155, 1.0),
    vec4(0.968, 0.794, 0.431, 0.733),
    vec4(0.206, 0.248, 0.236, 0.23),
    vec4(0.985, 0.891, 0.784, 0.819),
    vec4(0.967, 0.6, 0.225, 0.613),
    vec4(0.966, 0.627, 0.446, 1.0),
    vec4(0.965, 0.616, 0.488, 1.0),
    vec4(0.571, 0.329, 0.075, 0.475),
    vec4(0.612, 0.635, 0.714, 0.678),
    vec4(0.744, 0.744, 0.647, 1.0),
    vec4(0.16, 0.121, 0.155, 0.192),
    vec4(0.89, 0.878, 0.835, 0.852),
    vec4(0.966, 0.627, 0.446, 1.0),
    vec4(0.996, 0.827, 0.51, 0.795),
    vec4(0.729, 0.682, 0.696, 0.779),
    vec4(0.992, 0.608, 0.263, 0.634),
    vec4(0.992, 0.514, 0.651, 0.621),
    vec4(0.992, 0.835, 0.416, 0.773),
    vec4(0.765, 0.835, 0.804, 0.848),
    vec4(0.706, 0.694, 0.706, 1.0),
    vec4(0.948, 0.985, 0.906, 0.91),
    vec4(0.867, 0.78, 0.706, 1.0),
    vec4(0.872, 0.59, 0.431, 1.0),
    vec4(0.825, 0.645, 0.263, 0.738),
    vec4(0.984, 0.518, 0.278, 0.555),
    vec4(0.745, 0.459, 0.0, 0.541),
    vec4(0.98, 0.669, 0.493, 1.0),
    vec4(0.986, 0.564, 0.438, 1.0),
    vec4(0.929, 0.549, 0.592, 1.0),
    vec4(0.937, 0.804, 0.518, 0.842),
    vec4(0.0, 0.0, 0.0, 0.197)
);
// probe C colour, hair cutoff (class 4) or the glove skin's minimum red
const vec4 FP_C[FP_N] = vec4[FP_N](
    vec4(0.204, 0.263, 0.298, 0.0),
    vec4(0.204, 0.29, 0.212, 0.0),
    vec4(0.293, 0.248, 0.236, 0.0),
    vec4(0.157, 0.141, 0.231, 0.0),
    vec4(0.196, 0.149, 0.165, 0.0),
    vec4(0.192, 0.18, 0.157, 0.0),
    vec4(0.18, 0.404, 0.522, 0.0),
    vec4(0.263, 0.231, 0.2, 0.0),
    vec4(0.933, 0.541, 0.469, 0.5),
    vec4(0.158, 0.13, 0.187, 0.5),
    vec4(0.591, 0.531, 0.425, 0.5),
    vec4(0.184, 0.454, 0.151, 0.5),
    vec4(0.96, 0.549, 0.47, 0.5),
    vec4(0.591, 0.531, 0.425, 0.5),
    vec4(0.225, 0.311, 0.501, 0.5),
    vec4(0.337, 0.427, 0.478, 0.5),
    vec4(0.96, 0.549, 0.47, 0.5),
    vec4(0.306, 0.208, 0.169, 0.0),
    vec4(0.254, 0.312, 0.456, 0.8),
    vec4(0.253, 0.31, 0.272, 0.8),
    vec4(0.228, 0.234, 0.248, 0.8),
    vec4(0.289, 0.234, 0.248, 0.8),
    vec4(0.427, 0.714, 0.886, 0.5),
    vec4(0.383, 0.264, 0.144, 0.5),
    vec4(0.172, 0.146, 0.133, 0.5),
    vec4(0.434, 0.095, 0.205, 0.5),
    vec4(0.223, 0.308, 0.351, 0.36),
    vec4(0.341, 0.275, 0.169, 0.0),
    vec4(0.96, 0.549, 0.47, 0.5),
    vec4(0.94, 0.729, 0.374, 0.0),
    vec4(0.2, 0.231, 0.217, 0.0),
    vec4(0.935, 0.828, 0.72, 0.0),
    vec4(0.94, 0.55, 0.196, 0.0),
    vec4(0.591, 0.531, 0.425, 0.5),
    vec4(0.786, 0.492, 0.213, 0.8),
    vec4(0.752, 0.432, 0.145, 0.0),
    vec4(0.718, 0.737, 0.8, 0.0),
    vec4(0.96, 0.549, 0.47, 0.5),
    vec4(0.19, 0.158, 0.208, 0.36),
    vec4(0.792, 0.788, 0.745, 0.0),
    vec4(0.591, 0.531, 0.425, 0.5),
    vec4(0.835, 0.702, 0.42, 0.0),
    vec4(0.836, 0.78, 0.802, 0.0),
    vec4(0.89, 0.494, 0.22, 0.0),
    vec4(0.89, 0.404, 0.522, 0.0),
    vec4(0.89, 0.682, 0.337, 0.0),
    vec4(0.89, 0.973, 0.937, 0.0),
    vec4(0.859, 0.902, 0.937, 0.5),
    vec4(0.862, 0.865, 0.823, 0.0),
    vec4(0.715, 0.638, 0.575, 0.5),
    vec4(0.839, 0.559, 0.429, 0.5),
    vec4(0.946, 0.739, 0.427, 0.0),
    vec4(0.914, 0.365, 0.184, 0.0),
    vec4(1.0, 0.651, 0.0, 0.0),
    vec4(0.975, 0.643, 0.482, 0.8),
    vec4(1.0, 0.637, 0.431, 0.5),
    vec4(1.0, 0.714, 0.776, 0.5),
    vec4(1.0, 0.937, 0.584, 0.0),
    vec4(0.354, 0.323, 0.494, 0.42)
);
// END FINGERPRINTS

// The game's skin texel (the body texture is this peach, nearly flat, with a faint mouth line and tint), and its luminance.
const vec3 SKIN_TEXEL = vec3(0.953, 0.620, 0.475);
const vec3 LUMW = vec3(0.299, 0.587, 0.114);
const float PEACH_LUM = 0.703;
// Skin albedos by the tone the script sends per worm (1..7: fair, light, medium, olive, tan, brown, deep; keep the same as
// SKIN.TONES in client/init.lua). Each has its own undertone as well as lightness: fair a pink ivory, light a golden beige,
// medium a warm tan, olive a muted green-brown, tan a golden brown, brown and deep red-browns.
const vec3 TONES[8] = vec3[8](vec3(0.64, 0.46, 0.36), vec3(0.92, 0.8, 0.73), vec3(0.85, 0.73, 0.5), vec3(0.64, 0.46, 0.36), vec3(0.53, 0.47, 0.355), vec3(0.52, 0.38, 0.18), vec3(0.4, 0.26, 0.185), vec3(0.28, 0.18, 0.135));
// A place where the worm's see-through lid textures are clear: a worm-material texture with alpha there is a layer drawn
// over another, which keeps its own alpha (no mark).
const vec2 PROBE_LAYER = vec2(0.5, 0.2);
// How far apart the skin's pores are, and the finest its grain gets, in world units (a worm's head is about 12 across).
const float PORE_W = 0.085;
const float GRAIN_W = 0.2;
// The skin's blood, oiliness and lips or folds, for the face debug view (sunstoneSkinDebug 3).
vec3 dbgFace = vec3(0.0);

bool GameTerms() {
    return gl_FragCoord.x < sunstoneSplit || sunstoneLight < 0.5 || (sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// The worm's own material: specular (0.2, 0.18, 0.1), rim (0.3, 0.275, 0.175), rim power 1.5, gloss 5.
bool WormMaterial() {
    float d = dot(abs(materialMatrix[0].xyz - vec3(0.2, 0.18, 0.1)), vec3(1.0)) + dot(abs(materialMatrix[2].xyz - vec3(0.3, 0.275, 0.175)), vec3(1.0))
            + abs(materialMatrix[3].x - 1.5) + abs(materialMatrix[3].y - 5.0) * 0.1;
    return d < 0.02;
}

// The matte materials of what a worm wears (and of many props): specular 0.24 to 0.31, gloss 4.5 to 8.5, not the worm's.
bool MatteMaterial() {
    return materialMatrix[0].x > 0.235 && materialMatrix[0].x < 0.315 && materialMatrix[3].y > 4.5 && materialMatrix[3].y < 8.5;
}

// Material detail (Sunstone 2.3): a snippet per material class from tools/materials, picked by Melange's texture tag
// (mg_texTag) or, untagged, from the material. Never on the worm's own material, its skin, eyes or hair (see main).
// BEGIN MATERIALS (generated by tools/build_materials.py from tools/materials; do not edit by hand)
// ---- _common.glsl: the material library's shared part (inputs, outputs, helpers). See tools/materials/README.md.
// Spliced into the lit textured model shaders by tools/build_materials.py, after the host's own uniforms (texture0,
// materialMatrix, view, sunstoneLight, sunstoneSplit) and GameTerms(). Every name here starts with Mat or MAT_.

// Melange's texture tag for the texture bound on unit 0: [0] = (class id, scale, strength, roughness bias),
// [1] = (wear, tint variation, class parameter a, class parameter b). All zero for an untagged texture or a Melange
// without texture tags (it then logs that the uniform "stays 0" once at link).
uniform vec4 mg_texTag[2];
uniform float sunstoneMatDetail;   // material detail amount: 0 off, 1 full (Subtle sends 0.5; set by Sunstone)
uniform float sunstoneMatSplit;    // pixels left of this x are drawn without material detail (A/B comparisons)
uniform float sunstoneMatDebug;    // 1 class colours; 2 fade; 3 normal detail; 4 cavity

// FUTURE (disabled): shared material maps. Needs Melange shader textures (a plugin-bound sampler2DArray of original
// tileable layers) and #version 130 in the host shader (texture2D -> texture); then define SUNSTONE_MAT_MAPS.
// Layers: R,G normal xy, B height/cavity, A roughness/albedo variation. Until then everything is procedural.
#ifdef SUNSTONE_MAT_MAPS
uniform sampler2DArray sunstoneMat;
vec4 MatMap(float layer, vec2 uv) {
    return texture(sunstoneMat, vec3(uv, layer));
}
#endif

const vec3 MAT_LUMW = vec3(0.299, 0.587, 0.114);
// Beyond this distance from the camera (world units) detail is gone (and starts going at a third of it).
const float MAT_FADE_FAR = 3000.0;

// What a snippet gets. Eye space = the game's view space (camera at 0; the same units as the world).
struct MatIn {
    vec3 albedo;      // the texel's colour, 0..1 (the base albedo, before Sunstone's leaf hue shift)
    float alpha;      // the texel's alpha
    vec2 uv;          // texture coordinate (GL_REPEAT space: whole numbers are the texture's own wrap)
    vec2 uvDx;        // its screen derivatives, per pixel
    vec2 uvDy;
    float uvPx;       // texture units one pixel covers (the larger axis)
    float uvPerWorld; // texture units per world unit on this triangle (a worm's head is about 12 world units)
    float pxWorld;    // world units one pixel covers here
    float aniso;      // how far the texture is stretched on the surface (1 none; 2 twice as long one way)
    vec3 pos;         // eye-space position
    vec3 wpos;        // world position (props move: prefer uv, which sticks to the surface)
    vec3 n;           // unit normal, eye space (no detail)
    vec3 gu;          // eye-space surface gradient of u (texture units per world unit, steepest direction)
    vec3 gv;          // eye-space surface gradient of v
    vec3 tu;          // unit direction of increasing u along the surface (the cotangent frame; the mesh has none)
    vec3 tv;          // unit direction of increasing v
    vec3 v;           // unit vector toward the eye
    vec3 l;           // unit vector toward the sun
    vec3 up;          // the world's up, eye space
    float ndl;        // dot(n, l), unclamped
    float ndv;        // dot(n, v), at least 0
    float sky;        // 0 facing the ground .. 1 facing the sky
    vec2 lumD;        // screen derivatives (x, y) of the texel's luminance: the art's own edges
    float scale;      // tag: feature size multiplier (1 the snippet's own sizes; 2 twice as big)
    float strength;   // tag: strength (the dispatcher applies it to the result; read it only to shape detail)
    vec4 p;           // tag: (wear, tint variation, class parameter a, class parameter b), see the snippet's @default
    float fade;       // 0..1 distance and grazing-angle fade (the dispatcher applies it; use it to skip work)
    float seed;       // 0..1, differs between textures with different tag parameters
    float tagged;     // 1 the tag came from Melange; 0 the class was guessed from the material
};

// What a snippet returns. MatNone(m.albedo) is "no change"; start from it.
struct MatOut {
    vec3 albedo;      // new albedo (keep the art's hue and value: detail is mostly light, not paint)
    float spec;       // specular scale (1 the material's own)
    float gloss;      // gloss scale, the Blinn-Phong exponent (1 the material's own; < 1 rougher)
    vec3 dn;          // normal perturbation, eye space, added to n before normalising (from MatBumpUv / MatBumpScreen)
    float ao;         // cavity and occlusion, 0..1 (1 none): darkens ambient fully and direct light a third
};

MatOut MatNone(vec3 albedo) {
    return MatOut(albedo, 1.0, 1.0, vec3(0.0), 1.0);
}

float MatLum(vec3 c) {
    return dot(c, MAT_LUMW);
}

// ---- hashes (no sine: stable for big coordinates)
float MatHash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 MatHash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
vec3 MatHash32(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// ---- gradient noise on the texture's plane, with its slope: (value about -0.5..0.5, d/dp.x, d/dp.y).
// period > 0 wraps the lattice every period cells: with p = uv * F and period = F (F a whole number) the noise
// repeats with the texture, so a GL_REPEAT seam stays seamless. period 0: no wrap.
vec2 MatGrad(vec2 i, float period) {
    if (period > 0.0) i = mod(i, period);
    return MatHash22(i) * 2.0 - 1.0;
}
vec3 MatGNoise(vec2 p, float period) {
    vec2 i = floor(p), f = fract(p), e = vec2(1.0, 0.0);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec2 ga = MatGrad(i, period), gb = MatGrad(i + e, period), gc = MatGrad(i + e.yx, period), gd = MatGrad(i + 1.0, period);
    float va = dot(ga, f), vb = dot(gb, f - e), vc = dot(gc, f - e.yx), vd = dot(gd, f - 1.0), k = va - vb - vc + vd;
    return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va));
}

// ---- footprint: how much of a pattern survives at this pixel. cellsPx = pattern cells per pixel: 1 below 0.25
// (four pixels a cell), 0 from 0.5 (the Nyquist limit), so nothing ever shimmers or crawls.
float MatFadeCells(float cellsPx) {
    return 1.0 - smoothstep(0.25, 0.5, cellsPx);
}
// For a pattern of freq cells per texture unit.
float MatFadeUv(MatIn m, float freq) {
    return MatFadeCells(freq * m.uvPx);
}
// For features sizeWorld world units apart.
float MatFadeWorld(MatIn m, float sizeWorld) {
    return MatFadeCells(m.pxWorld / max(sizeWorld, 1e-4));
}

// Features sizeWorld world units apart, on the texture's plane: F0 (cells per texture unit, a power of two, so the
// pattern repeats with the texture; pass it as MatGNoise's period) and the blend toward the next octave 2 * F0.
// Blend the two octaves with it so the size never jumps between triangles of different texel density.
void MatOctave(MatIn m, float sizeWorld, out float F0, out float blend) {
    float lf = clamp(-log2(max(sizeWorld * m.uvPerWorld, 1e-6)), 0.0, 13.0);
    F0 = exp2(floor(lf));
    blend = lf - floor(lf);
}

// fbm of up to 4 octaves from freq cells per texture unit (a whole number, or 0 period for no wrap), each octave faded
// by its own footprint: (value, d/duv). Lacunarity 2, gain 0.5.
vec3 MatFbm(MatIn m, vec2 uv, float freq, float octaves) {
    vec3 s = vec3(0.0);
    float a = 1.0, f = freq;
    for (int i = 0; i < 4; i++) {
        if (float(i) >= octaves) break;
        float k = MatFadeUv(m, f);
        if (k <= 0.0) break;
        vec3 g = MatGNoise(uv * f + float(i) * 17.31, f);
        s += a * k * vec3(g.x, g.yz * f);
        a *= 0.5;
        f *= 2.0;
    }
    return s;
}

// ---- normal detail. A height field h(uv) in world units with slope dh = (dh/du, dh/dv): the perturbation that tilts
// the normal by it (dh from MatGNoise is per noise cell: multiply its .yz by the frequency and by the height).
vec3 MatBumpUv(MatIn m, vec2 dh) {
    return -(dh.x * m.gu + dh.y * m.gv);
}
// A height with screen derivatives dxy (world units per pixel in x and y), e.g. m.lumD * depth.
vec3 MatBumpScreen(MatIn m, vec2 dxy) {
    vec3 dpx = dFdx(m.pos), dpy = dFdy(m.pos);
    vec3 r1 = cross(dpy, m.n), r2 = cross(m.n, dpx);
    float det = dot(dpx, r1);
    return -(dxy.x * r1 + dxy.y * r2) / (abs(det) > 1e-20 ? det : 1e-20);
}

// ---- colour: a variation of up to amount in brightness with a touch of warmth, keeping the art's hue (r: -1..1).
vec3 MatVary(vec3 c, float amount, float r) {
    return c * (1.0 + amount * r * vec3(1.02, 1.0, 0.97));
}

// The inputs for this fragment. Call only in uniform control flow (MatEnabled() is uniform): it takes derivatives.
MatIn MatSetup(vec4 tex, vec2 uv) {
    MatIn m;
    m.albedo = tex.rgb;
    m.alpha = tex.a;
    m.uv = uv;
    m.uvDx = dFdx(uv);
    m.uvDy = dFdy(uv);
    m.uvPx = max(length(m.uvDx), length(m.uvDy));
    m.pos = -gl_TexCoord[1].xyz;
    m.wpos = (m.pos - view[3].xyz) * mat3(view);
    m.n = normalize(gl_TexCoord[2].xyz);
    m.v = normalize(gl_TexCoord[1].xyz);
    m.l = normalize(-gl_TexCoord[3].xyz);
    vec3 up = view[1].xyz;
    m.up = dot(up, up) > 0.25 ? normalize(up) : m.l;
    m.ndl = dot(m.n, m.l);
    m.ndv = max(dot(m.n, m.v), 0.0);
    m.sky = dot(m.n, m.up) * 0.5 + 0.5;
    float lum = MatLum(tex.rgb);
    m.lumD = vec2(dFdx(lum), dFdy(lum));
    // The cotangent frame (no tangents in the mesh): surface gradients of u and v from the screen derivatives.
    vec3 dpx = dFdx(m.pos), dpy = dFdy(m.pos);
    vec3 r1 = cross(dpy, m.n), r2 = cross(m.n, dpx);
    float det = dot(dpx, r1);
    det = abs(det) > 1e-20 ? det : 1e-20;
    m.gu = (r1 * m.uvDx.x + r2 * m.uvDy.x) / det;
    m.gv = (r1 * m.uvDx.y + r2 * m.uvDy.y) / det;
    float gu2 = dot(m.gu, m.gu), gv2 = dot(m.gv, m.gv);
    m.tu = gu2 > 1e-24 ? m.gu * inversesqrt(gu2) : normalize(cross(m.n, vec3(0.31, 0.95, 0.0)));
    m.tv = gv2 > 1e-24 ? m.gv * inversesqrt(gv2) : normalize(cross(m.tu, m.n));
    float areaW = length(cross(dpx, dpy));
    float areaUv = abs(m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x);
    m.uvPerWorld = max(sqrt(areaUv / max(areaW, 1e-24)), 1e-6);
    m.pxWorld = sqrt(areaW);
    float tt = gu2, bb = gv2, tb = dot(m.gu, m.gv), tr = tt + bb, dg = max(tt * bb - tb * tb, 1e-36);
    float sa = sqrt(max(tr * tr - 4.0 * dg, 0.0));
    m.aniso = sqrt(max((tr + sa) / max(tr - sa, 1e-30), 1.0));
    float d = length(m.pos);
    m.fade = (1.0 - smoothstep(MAT_FADE_FAR / 3.0, MAT_FADE_FAR, d)) * smoothstep(0.03, 0.2, m.ndv);
    m.scale = 1.0;
    m.strength = 1.0;
    m.p = vec4(0.0);
    m.seed = 0.0;
    m.tagged = 0.0;
    return m;
}
// ---- end _common.glsl

// ---- snippets (tools/materials/<class>.glsl)
// -- generic.glsl
// @class generic
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0
// @param tint: albedo variation (1 = 2% either way)
// @param a: unused
// @param b: unused
// The default for any class without its own snippet, and for an untagged matte texture: a barely-there surface, a
// fine grain in the light (the normal and the sheen) and a faint mottle in the paint. It must stay small: it lands on
// everything, cartoon art included.
MatOut mat_generic(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Grain about 1.2 world units across (a worm's head is about 12), two octaves blended so it never jumps in size.
    float F0, fb;
    MatOctave(m, 1.2 * m.scale, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + 7.0, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    float k = MatFadeUv(m, F0 * (1.0 + fb));
    // Height 0.05 world units: slopes of a few degrees at most.
    o.dn = MatBumpUv(m, g.yz * (0.05 * m.scale * k));
    // A mottle ten times bigger, 2% either way (tint), and the sheen broken a little by the grain.
    float F1, fb1;
    MatOctave(m, 12.0 * m.scale, F1, fb1);
    float mot = mix(MatGNoise(m.uv * F1 + 3.0, F1).x, MatGNoise(m.uv * (2.0 * F1) + 11.0, 2.0 * F1).x, fb1);
    o.albedo = MatVary(m.albedo, 0.04 * m.p.y * MatFadeUv(m, F1), mot);
    o.spec = 1.0 + 0.25 * g.x * k;
    return o;
}

// ---- generated: class ids (tools/materials/classes.json) and the dispatch
const int MAT_CLASSES = 26;
const int MAT_FALLBACK_METAL = 8;   // bare_metal
const int MAT_FALLBACK_MATTE = 0;   // generic
MatOut MatDispatch(int c, MatIn m) {
    // generic: 0 and painted_metal, fabric_cloth, fur_hair, leaf_foliage, plastic, stone_rock, wood_planks, bare_metal, skin, other, leather, gold_brass, emissive_light, glass_gem, bone_teeth, rusted_metal, cartoon_flat, wood_bark, paper_card, sand_dirt, rope_straw, concrete_plaster, snow_ice, grass_turf, brick, rubber
    return mat_generic(m);
}
// The tag an untagged texture of a fallback class gets: (class, scale, strength, rough), (wear, tint, a, b).
void MatDefaults(int c, out vec4 t0, out vec4 t1) {
    if (c == 8) { t0 = vec4(8.0, 1.0, 1.0, 0.0); t1 = vec4(0.0, 1.0, 0.0, 0.0); return; }
    t0 = vec4(0.0, 1.0, 1.0, 0.0);
    t1 = vec4(0.0, 1.0, 0.0, 0.0);
}

// ---- _evaluate.glsl: the tag, the switches and the blend of a snippet's result (after the generated MatDispatch).

// For the debug views: the class drawn (0 generic), whether it was tagged, and the snippet's own fade, normal detail
// and cavity before the mask.
int matClass = -1;
float matTagged = 0.0;
float matDbgFade = 0.0;
vec3 matDbgDn = vec3(0.0);
float matDbgAo = 1.0;

// Uniform: whether any fragment of this draw gets material detail (Sunstone's lighting on, not its grey view).
bool MatEnabled() {
    return sunstoneMatDetail > 0.0 && sunstoneLight > 0.5 && !(sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// Per fragment: 0 left of the A/B split or where the game's lighting is kept.
float MatMask() {
    return gl_FragCoord.x < sunstoneMatSplit || GameTerms() ? 0.0 : 1.0;
}

// The class and parameters for this draw (Melange's tag, else a guess from the material), the snippet's result, and
// that result scaled by the detail amount, the tag's strength and the fade, with the tag's roughness bias.
MatOut MatEvaluate(MatIn m) {
    vec4 t0 = mg_texTag[0], t1 = mg_texTag[1];
    int c = int(floor(t0.x + 0.5));
    if (c < 1 || c > MAT_CLASSES) {
        // Untagged (or an older Melange): the material's specular and gloss tell metal from the standard matte.
        bool metal = materialMatrix[3].y >= 30.0 && dot(materialMatrix[0].xyz, vec3(0.333)) >= 0.5;
        c = metal ? MAT_FALLBACK_METAL : MAT_FALLBACK_MATTE;
        MatDefaults(c, t0, t1);
        m.tagged = 0.0;
    } else {
        m.tagged = 1.0;
    }
    m.scale = t0.y > 0.0 ? t0.y : 1.0;
    m.strength = max(t0.z, 0.0);
    m.p = t1;
    m.seed = MatHash12(vec2(t0.y * 13.1 + t1.x * 7.7 + t1.z * 3.3 + float(c), t0.z * 5.3 + t1.y * 11.9 + t1.w * 2.9));
    MatOut o = MatDispatch(c, m);
    float k = clamp(sunstoneMatDetail * m.strength * m.fade, 0.0, 2.0);
    o.gloss *= exp2(-2.0 * t0.w);
    o.spec *= exp2(-t0.w);
    MatOut r;
    r.albedo = clamp(mix(m.albedo, o.albedo, k), 0.0, 1.0);
    r.spec = max(mix(1.0, o.spec, k), 0.0);
    r.gloss = max(mix(1.0, o.gloss, k), 0.05);
    r.dn = o.dn * k;
    r.ao = clamp(mix(1.0, o.ao, k), 0.0, 1.0);
    matClass = c;
    matTagged = m.tagged;
    matDbgFade = k;
    matDbgDn = r.dn;
    matDbgAo = r.ao;
    return r;
}

// The lighting's material terms for Light(): specular scale, gloss scale, cavity; vec3(1.0) none.
vec3 MatLightTerms(MatOut o, float w) {
    return vec3(mix(1.0, o.spec, w), mix(1.0, o.gloss, w), mix(1.0, o.ao, w));
}

// The debug views (sunstoneMatDebug), by the lit colour's brightness. 1: a colour per class (generic grey; untagged
// striped; no detail, e.g. the worm's own material, skin and hair, near black). 2: the detail amount after fade.
// 3: the normal detail. 4: the cavity.
vec3 MatDebug(vec3 col, float w) {
    if (sunstoneMatDebug < 0.5 || matClass < 0) return col;
    float sh = 0.35 + 0.65 * clamp(MatLum(col) * 1.6, 0.0, 1.0);
    if (sunstoneMatDebug > 3.5) return vec3(matDbgAo) * w;
    if (sunstoneMatDebug > 2.5) return (matDbgDn * 4.0 + 0.5) * w;
    if (sunstoneMatDebug > 1.5) return vec3(matDbgFade * w, 0.3 * (1.0 - w), 0.0) + 0.15 * sh;
    if (w <= 0.0) return vec3(0.08) * sh;
    // (Hues 7/26 of a turn apart by id, every other id darker: neighbouring ids never look alike.)
    float id = float(matClass);
    vec3 c = matClass == 0 ? vec3(0.6) : (0.5 + 0.5 * cos(6.2831 * (fract(id * 7.0 / 26.0) + vec3(0.0, 0.33, 0.67))))
                                         * (mod(id, 2.0) < 0.5 ? 0.6 : 1.0);
    if (matTagged < 0.5 && fract((gl_FragCoord.x + gl_FragCoord.y) / 12.0) < 0.5) c *= 0.45;
    return c * sh;
}
// ---- end _evaluate.glsl
// END MATERIALS

// How much a texel of the worm's own texture is skin, 0..1: red highest, green 0.34 to 0.86 of it and blue 0.31 to 0.68,
// not dark. The peach, its shading, the lids' pink crease and the lips pass; the eye whites (green near red), the
// pupils, teeth (blue), the mouth's inside and the tongue's red (green and blue far below) do not.
float SkinFamily(vec3 t) {
    float r = max(t.r, 1e-3), u = t.g / r, v = t.b / r;
    return smoothstep(0.50, 0.60, t.r) * smoothstep(0.34, 0.40, u) * (1.0 - smoothstep(0.80, 0.86, u))
         * smoothstep(0.31, 0.36, v) * (1.0 - smoothstep(0.62, 0.68, v));
}

// A glove's bare-skin texel: the peach's own chroma, at least rmin red (a glove whose dark leather has that chroma sets it high).
float SkinChroma(vec3 t, float rmin) {
    float r = max(t.r, 1e-3), u = t.g / r, v = t.b / r;
    return smoothstep(rmin - 0.03, rmin + 0.05, t.r) * smoothstep(0.55, 0.58, u) * (1.0 - smoothstep(0.72, 0.75, u))
         * smoothstep(0.38, 0.41, v) * (1.0 - smoothstep(0.56, 0.59, v));
}

// The texture's entry in the fingerprint table: class * 16 + hair colour (0 none), with the entry's mean hair luminance
// and its cutoff or minimum red. The three reads are at fixed places, so every fragment of a draw reads the same texels.
// The table is sorted by probe A's red: a binary search finds the first entry less than FP_TOL below it, and only the few
// entries up to FP_TOL above it are compared in full (a scan of the whole table in every fragment of every matte prop cost
// up to 0.6 ms a frame where fence posts or wire filled the screen). Seven halvings cover up to 127 entries.
float Fingerprint(out float mean, out float extra) {
    mean = 1.0;
    extra = 0.0;
    vec3 a = texture2D(texture0, PROBE_A).rgb;
    float lo = a.r - FP_TOL, hi = a.r + FP_TOL;
    if (lo > FP_A[FP_N - 1].r) return 0.0;
    int i0 = 0, i1 = FP_N - 1;
    for (int k = 0; k < 7; k++) {
        int m = (i0 + i1) / 2;
        if (FP_A[m].r < lo) i0 = m + 1; else i1 = m;
    }
    if (FP_A[i0].r > hi) return 0.0;
    vec3 b = texture2D(texture0, PROBE_B).rgb;
    vec3 c = texture2D(texture0, PROBE_C).rgb;
    for (int i = i0; i < FP_N; i++) {
        if (FP_A[i].r > hi) break;
        vec3 d = max(abs(a - FP_A[i].rgb), max(abs(b - FP_B[i].rgb), abs(c - FP_C[i].rgb)));
        if (max(d.r, max(d.g, d.b)) < FP_TOL) {
            mean = FP_B[i].a;
            extra = FP_C[i].a;
            return FP_A[i].a;
        }
    }
    return 0.0;
}

// The skin's mark in the scene alpha: its colour is written on the 8-bit grid and its alpha is a hash of that colour, 192
// to 240 (of 255), exact in floats, so PostProcess.RecombineWorms.glsl can tell skin from a cut-out's edge, a terrain layer
// or a blend that happens to leave such an alpha (and, under the game's ghost of a hidden worm, from the rest of the worm:
// see PostProcess.Silhouette_PC.glsl). Keep the two copies of SkinMark the same.
float SkinMark(vec3 q) {
    return 192.0 + mod(q.r * 37.0 + q.g * 101.0 + q.b * 13.0, 49.0);
}

// Natural hair albedos (display colours): 1 black, 2 dark brown, 3 brown, 4 light brown, 5 dark blonde, 6 blonde,
// 7 auburn, 8 ginger, 9 grey, 10 white.
vec3 HairAlbedo(float i) {
    if (i < 1.5) return vec3(0.055, 0.045, 0.040);
    if (i < 2.5) return vec3(0.14, 0.09, 0.06);
    if (i < 3.5) return vec3(0.30, 0.20, 0.115);
    if (i < 4.5) return vec3(0.45, 0.31, 0.19);
    if (i < 5.5) return vec3(0.58, 0.45, 0.28);
    if (i < 6.5) return vec3(0.76, 0.63, 0.42);
    if (i < 7.5) return vec3(0.40, 0.16, 0.08);
    if (i < 8.5) return vec3(0.72, 0.36, 0.14);
    if (i < 9.5) return vec3(0.55, 0.53, 0.51);
    return vec3(0.80, 0.79, 0.76);
}

// The fragment's world position: the eye-space position (the vertex program passes its negative in texcoord 1) taken
// back through the view matrix.
vec3 WorldPos() {
    return (-gl_TexCoord[1].xyz - view[3].xyz) * mat3(view);
}

// The worm whose centre is nearest (its height counts half: a worm is tall), unpacked: its centre, tone (0 none), seed,
// facing (yaw, radians) and hair colour. pickPos is the fragment's world position.
vec3 pickPos = vec3(0.0);
vec3 pickCentre = vec3(0.0);
float pickTone = 0.0, pickSeed = 0.0, pickYaw = 0.0, pickHair = 0.0;
float pickCode = 0.0;
float pickBest = 1e9;
float pickSlot = -1.0;
void Pick(vec3 p, vec4 c, float slot) {
    if (c.w < 0.5) return;
    vec3 d = p - c.xyz;
    d.y *= 0.5;
    float e = dot(d, d);
    if (e < pickBest) {
        pickBest = e;
        pickCode = c.w - 1.0;
        pickCentre = c.xyz;
        pickSlot = slot;
    }
}
void PickWorm() {
    vec3 p = WorldPos();
    pickPos = p;
    Pick(p, sunstoneWorm0, 0.0);
    Pick(p, sunstoneWorm1, 1.0);
    Pick(p, sunstoneWorm2, 2.0);
    Pick(p, sunstoneWorm3, 3.0);
    Pick(p, sunstoneWorm4, 4.0);
    Pick(p, sunstoneWorm5, 5.0);
    Pick(p, sunstoneWorm6, 6.0);
    Pick(p, sunstoneWorm7, 7.0);
    Pick(p, sunstoneWorm8, 8.0);
    Pick(p, sunstoneWorm9, 9.0);
    Pick(p, sunstoneWorm10, 10.0);
    Pick(p, sunstoneWorm11, 11.0);
    Pick(p, sunstoneWorm12, 12.0);
    Pick(p, sunstoneWorm13, 13.0);
    Pick(p, sunstoneWorm14, 14.0);
    Pick(p, sunstoneWorm15, 15.0);
    if (pickSlot < 0.0) return;
    float k = floor(pickCode + 0.5);
    pickHair = floor(k / 32768.0);
    k -= pickHair * 32768.0;
    pickTone = floor(k / 4096.0);
    k -= pickTone * 4096.0;
    pickSeed = floor(k / 64.0);
    pickYaw = (k - pickSeed * 64.0) * 0.09817477;
}

// 1 between heights a and b of the worm's frame, fading over a couple of units at either end.
float Band(float y, float a, float b) {
    return smoothstep(a - 1.5, a + 0.5, y) * (1.0 - smoothstep(b - 0.5, b + 1.5, y));
}

float Hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Three hashes of a cell (a hash without sine: the sine of the big coordinates of a fine grid repeats in nearby cells).
vec3 Hash32(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.103, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float Noise2(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(Hash2(i), Hash2(i + vec2(1.0, 0.0)), f.x), mix(Hash2(i + vec2(0.0, 1.0)), Hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}

// A pore in a share dens of the cells of a grid, at a random place in its cell, of random size (big scales it) and depth,
// round on the surface (m: the texture's metric there, see main, and in w how far it stretches a circle at most): its
// depth (0..1) and its slope, outward, scaled to its size.
vec3 Pore(vec2 pg, float big, float dens, vec4 m) {
    vec3 rnd = Hash32(floor(pg));
    float R = min(mix(0.12, 0.28, rnd.y) * big, 0.45 / m.w);
    vec2 pc = fract(pg) - 0.5 - (rnd.xz - 0.5) * (1.0 - 2.0 * R * m.w), mp = vec2(dot(m.xy, pc), dot(m.yz, pc));
    float rr = dot(pc, mp) / (R * R);
    float d = step(1.0 - dens, fract(rnd.x * 7.31 + rnd.z)) * mix(0.35, 1.0, rnd.z);
    return rr < 1.0 ? d * vec3((1.0 - rr) * (1.0 - rr), 4.0 * (1.0 - rr) * mp / R) : vec3(0.0);
}

// Gradient noise (about -0.4..0.4; its extremes fall between the lattice's points, so it has none of value noise's
// blobs on a grid), in space for the skin's blotches and on the texture's plane, with its slope, for its grain.
vec3 Grad3(vec3 p) {
    p = fract(p * vec3(0.1031, 0.103, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx) * 2.0 - 1.0;
}
float GNoise3(vec3 p) {
    vec3 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
    vec2 e = vec2(1.0, 0.0);
    return mix(mix(mix(dot(Grad3(i), f), dot(Grad3(i + e.xyy), f - e.xyy), u.x),
                   mix(dot(Grad3(i + e.yxy), f - e.yxy), dot(Grad3(i + e.xxy), f - e.xxy), u.x), u.y),
               mix(mix(dot(Grad3(i + e.yyx), f - e.yyx), dot(Grad3(i + e.xyx), f - e.xyx), u.x),
                   mix(dot(Grad3(i + e.yxx), f - e.yxx), dot(Grad3(i + e.xxx), f - e.xxx), u.x), u.y), u.z);
}
vec3 GNoise2(vec2 p) {
    vec2 i = floor(p), f = fract(p), e = vec2(1.0, 0.0);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec2 ga = Hash32(i).xy * 2.0 - 1.0, gb = Hash32(i + e).xy * 2.0 - 1.0, gc = Hash32(i + e.yx).xy * 2.0 - 1.0, gd = Hash32(i + 1.0).xy * 2.0 - 1.0;
    float va = dot(ga, f), vb = dot(gb, f - e), vc = dot(gc, f - e.yx), vd = dot(gd, f - 1.0), k = va - vb - vc + vd;
    return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va));
}

// Brightness above the knee rolls off toward white, as film does, so bright sand and stone stay pale rather than
// clipping per channel or turning orange.
vec3 Shoulder(vec3 c) {
    if (GameTerms()) return c;
    float m = max(c.r, max(c.g, c.b));
    if (m <= 0.9) return c;
    float r = 0.9 + 0.1 * (1.0 - exp((0.9 - m) / 0.1));
    vec3 rolled = mix(c * (r / m), vec3(r), clamp((m - 0.9) / m * 1.5, 0.0, 1.0));
    return mix(rolled, min(c, vec3(1.0)), 0.5);
}

float Hue(vec3 c, out float s) {
    float mx = max(c.r, max(c.g, c.b)), C = mx - min(c.r, min(c.g, c.b));
    s = C / max(mx, 1e-4);
    if (C < 1e-4) return 0.0;
    float h = mx == c.r ? (c.g - c.b) / C : (mx == c.g ? 2.0 + (c.b - c.r) / C : 4.0 + (c.r - c.g) / C);
    return fract(h / 6.0) * 360.0;
}

vec3 Hsv(float h, float s, float v) {
    vec3 k = clamp(abs(fract(h / 360.0 + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(vec3(1.0), k, s);
}

// How much the surface faces the sun (0..1) and the sky (0..1), set by Light().
float leafSun = 1.0;
float leafSky = 0.5;

// A gentler pull of leaf greens toward yellow-green, with no chroma cap; very saturated greens (painted drums) keep
// their colour. Leaves turned from the sun stay a cooler green, and canopy tops seen from above shift less.
vec3 Foliage(vec3 c) {
    if (sunstoneFoliage <= 0.0 || GameTerms()) return c;
    float S, H = Hue(c, S);
    float w = smoothstep(0.2, 0.4, S) * smoothstep(95.0, 120.0, H) * (1.0 - smoothstep(155.0, 175.0, H));
    w *= 1.0 - smoothstep(0.55, 0.65, S) * (1.0 - smoothstep(120.0, 130.0, H));
    // Glossy materials are painted props, not leaves.
    w *= 1.0 - smoothstep(0.15, 0.4, dot(materialMatrix[0].xyz, vec3(0.333)));
    float shift = mix(0.4, 1.0, leafSun) * (1.0 - 0.5 * smoothstep(0.85, 0.97, leafSky));
    return Hsv(H - sunstoneFoliage * w * shift, S, max(c.r, max(c.g, c.b))) * mix(vec3(1.0), vec3(0.93, 1.0, 1.1), w * (1.0 - leafSun));
}

// The rim light, kept apart so it can take on the surface's colour.
vec3 rimLight = vec3(0.0);
// The sun term n.l before clamping, the colour of the direct light and the ambient light, set by Light() for the skin
// and the hair.
float litNdl = 0.0;
vec3 sunLight = vec3(0.0);
vec3 ambLight = vec3(0.0);

// n: the unit normal (with any material detail); mt: the material detail's specular scale, gloss scale and cavity
// (vec3(1.0) none, which gives exactly the lighting without it).
void Light(vec3 n, vec3 mt, out vec3 base, out vec3 add) {
    vec3 v = normalize(gl_TexCoord[1].xyz);
    vec3 l = normalize(-gl_TexCoord[3].xyz);
    vec3 h = normalize(l + v);
    vec3 specCol = materialMatrix[0].xyz * mt.x;
    vec3 emissive = materialMatrix[1].xyz;
    vec3 rimCol = materialMatrix[2].xyz;
    float rimPower = materialMatrix[3].x;
    float power = materialMatrix[3].y * mt.y;
    float ndl = dot(n, l), ndh = max(dot(n, h), 0.0), ndv = max(dot(n, v), 0.0);
    float gameRim = clamp(pow(1.0 - dot(v, n), rimPower), 0.0, 1.0);
    litNdl = ndl;

    if (GameTerms()) {
        float spec = power > 0.0 ? pow(ndh, power) : 1.0;
        base = lightDiffuseCol * clamp(ndl, 0.0, 1.0) + lightAmbientCol + emissive;
        add = lightSpecularCol * specCol * spec + rimCol * gameRim;
        sunLight = lightDiffuseCol;
        ambLight = lightAmbientCol;
        return;
    }

    vec3 up = view[1].xyz;
    up = dot(up, up) > 0.25 ? normalize(up) : l;
    float w = sunstoneWrap;
    float diffuse = clamp((ndl + w) / (1.0 + w), 0.0, 1.0);
    float sky = dot(n, up) * 0.5 + 0.5;
    leafSun = smoothstep(-0.1, 0.5, ndl);
    leafSky = sky;
    vec3 ambient = lightAmbientCol * sunstoneAmbientGain * mix(sunstoneGround, sunstoneSky, sky)
        * mix(vec3(1.0), sunstoneShadowTint, sunstoneTint) * mix(1.0 - sunstoneGroundDip, 1.0, sky);

    float p = max(power, 1.0);
    float shine = power > 0.0 ? (p + 8.0) / 8.0 * pow(ndh, p) * max(ndl, 0.0) : 0.0;
    float f = 1.0 + 3.0 * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0);
    vec3 spec = lightSpecularCol * specCol * sunstoneSpecular * f * shine;

    float edge = pow(1.0 - ndv, 2.5);
    float back = clamp(0.35 - 0.65 * dot(v, l), 0.0, 1.0);
    vec3 rim = sunstoneRim * edge * (lightAmbientCol * sunstoneSky * 0.6 + lightDiffuseCol * (0.2 + back)) * (0.4 + 0.6 * sky);

    float keep = 1.0 - clamp(dot(specCol, vec3(0.333)) * sunstoneSpecular * 0.5, 0.0, 0.5);
    sunLight = lightDiffuseCol * mix(vec3(1.0), sunstoneSunTint, sunstoneTint) * sunstoneSunGain;
    // (Cavity: all of the ambient, a third of the sun.)
    base = sunLight * diffuse * keep * (1.0 - 0.35 * (1.0 - mt.z)) + ambient * mt.z + emissive;
    ambLight = ambient;
    add = spec + rimCol * gameRim * 0.5;
    // Weaker on surfaces facing up, which only meet the rim at grazing angles (lids, tops).
    rimLight = rim * mix(1.0, 0.35, smoothstep(0.7, 1.0, sky));
}

void main() {
    vec2 uv = gl_TexCoord[0].xy;
    vec4 tex = texture2D(texture0, uv);
    // (Derivatives first, outside any branch that differs between neighbouring fragments.)
    vec3 P = -gl_TexCoord[1].xyz;
    vec3 dp1 = dFdx(P), dp2 = dFdy(P);
    vec2 du1 = dFdx(uv), du2 = dFdy(uv);

    // What the fragment is: skin (0..1, skinFam; re-toned as skin only with a tone set), hair (0..1, with its colour), and
    // whether it may carry the skin's mark. The game's own peach is marked as well (marking), so Bloodsand and Kindjal find
    // the skin the same way whatever the tone, the light or a poisoned worm's tint; a glove's skin only while a skin or
    // hair setting is on (the table look-up is not worth running for every prop otherwise).
    float skin = 0.0, skinFam = 0.0, hair = 0.0, markable = 0.0, cls = 0.0, hairIdx = 0.0, hairMean = 1.0, extra = 0.0, sclera = 0.0;
    bool people = (sunstoneSkin > 0.5 || sunstoneHair > 0.5) && sunstoneLight < 9.5;
    bool marking = sunstoneSkinFlag > 0.5 && sunstoneLight < 9.5;
    if (people || marking) {
        if (WormMaterial()) {
            skinFam = SkinFamily(tex.rgb);
            markable = texture2D(texture0, PROBE_LAYER).a > 0.5 && tex.a > 0.999 ? 1.0 : 0.0;
            if (sunstoneSkin > 0.5) {
                skin = skinFam;
                // The eye whites (bright, green near red: see SkinFamily).
                sclera = (1.0 - skinFam) * smoothstep(0.6, 0.75, tex.r) * smoothstep(0.84, 0.9, tex.g / max(tex.r, 1e-3));
            }
        } else if (people && MatteMaterial()) {
            float code = Fingerprint(hairMean, extra);
            cls = floor(code / 16.0 + 0.01);
            hairIdx = code - cls * 16.0;
            if (cls == 1.0) {
                skinFam = SkinChroma(tex.rgb, extra);
                markable = tex.a > 0.999 ? 1.0 : 0.0;
                if (sunstoneSkin > 0.5) skin = skinFam;
            } else if (sunstoneHair > 0.5 && (cls == 2.0 || (sunstoneWigs > 0.5 && cls >= 3.0))) {
                hair = cls == 4.0 ? 1.0 - smoothstep(extra - 0.06, extra + 0.03, dot(tex.rgb, vec3(0.299, 0.587, 0.114))) : 1.0;
            }
        }
    }
    bool mixed = ((skin > 0.0 || sclera > 0.0) && sunstoneSkinMixed > 0.5) || (hair > 0.0 && cls == 2.0 && sunstoneHair > 1.5);
    if (mixed || (sunstoneSkinDebug > 1.5 && people)) PickWorm();

    // Material detail: everything but the worm's own material, its skin, eye whites and hair, which keep the paths
    // above (matW 0 there). With it off the lighting is exactly as without it.
    vec3 n0 = normalize(gl_TexCoord[2].xyz);
    MatOut mat = MatNone(tex.rgb);
    float matW = 0.0;
    if (MatEnabled()) {
        mat = MatEvaluate(MatSetup(tex, uv));
        matW = WormMaterial() ? 0.0 : MatMask() * (1.0 - skin) * (1.0 - hair) * (1.0 - sclera);
    }
    vec3 base, add;
    if (matW > 0.0) Light(normalize(n0 + mat.dn * matW), MatLightTerms(mat, matW), base, add);
    else Light(n0, vec3(1.0), base, add);
    vec3 albedo = sunstoneLight > 9.5 ? vec3(0.5) : Foliage(matW > 0.0 ? mix(tex.rgb, mat.albedo, matW) : tex.rgb);

    vec3 n = n0;
    vec3 v = normalize(gl_TexCoord[1].xyz);
    vec3 l = normalize(-gl_TexCoord[3].xyz);
    vec3 h = normalize(l + v);

    if (skin > 0.0) {
        // The worm: its tone (a few percent its own), ruddiness, seed and the fragment in its frame (q: x across the face, y
        // up from the body's middle, z out of the face; nq the normal in it; fy its facing). No worm sent: no face.
        vec3 tone = sunstoneSkinTone;
        float seed = 0.0, framed = 0.0, ruddy = 1.0;
        vec3 q = vec3(0.0), nq = vec3(0.0), hs = vec3(0.5);
        vec2 fy = vec2(0.0, 1.0);
        if (pickSlot >= 0.0) {
            if (pickTone > 0.5) tone = TONES[int(pickTone + 0.5)];
            hs = fract(pickSeed * vec3(0.6180339, 0.7548777, 0.5698403) + vec3(0.31, 0.67, 0.13));
            tone *= (1.0 + 0.08 * (hs.x - 0.5)) * vec3(1.0 + 0.05 * (hs.y - 0.5), 1.0, 1.0 - 0.06 * (hs.y - 0.5));
            ruddy = 0.7 + 0.6 * hs.z;
            seed = pickSeed;
            fy = vec2(sin(pickYaw), cos(pickYaw));
            vec3 d = pickPos - pickCentre;
            vec3 nw = n * mat3(view);
            q = vec3(d.x * fy.y - d.z * fy.x, d.y, d.x * fy.x + d.z * fy.y);
            nq = vec3(nw.x * fy.y - nw.z * fy.x, nw.y, nw.x * fy.x + nw.z * fy.y);
            framed = 1.0;
        }
        float lumT = dot(tone, LUMW) / PEACH_LUM;
        float dark = 1.0 - clamp(lumT, 0.0, 1.0);
        // The face: the T-zone (the snout between the mouth and the eyes, and the brow), oily; the cheeks; the lips (a narrow
        // band along the mouth, and the snout's underside above it, by its normal, so they follow the mouth in any pose).
        float front = smoothstep(0.05, 0.6, nq.z) * framed;
        float face = smoothstep(-0.3, 0.3, nq.z) * framed * Band(q.y, -5.0, 10.0);
        float tzone = clamp(front * exp(-q.x * q.x * 0.11) * Band(q.y, -1.5, 3.0)
                    + smoothstep(-0.2, 0.5, nq.z) * framed * exp(-q.x * q.x * 0.06) * Band(q.y, 4.0, 9.0), 0.0, 1.0);
        float cx = abs(q.x) - 3.3;
        float cheek = smoothstep(-0.35, 0.35, nq.z) * framed * exp(-cx * cx * 0.22) * Band(q.y, -3.5, 1.5);
        float lips = clamp(front * exp(-(q.y + 2.4) * (q.y + 2.4) * 1.8 - q.x * q.x * 0.07)
                         + smoothstep(-0.2, 0.3, nq.z) * smoothstep(0.2, 0.55, -nq.y) * framed * Band(q.y, -4.0, 0.5) * exp(-q.x * q.x * 0.06), 0.0, 1.0);
        // Blotches of blood (mot) and pigment (mel): two octaves each of gradient noise in the worm's frame (broad ones in
        // the texture's coordinates broke at its seams), the lattice turned off the face's axes (qr); the finer blood octave
        // (n2) also sets where the T-zone is oiliest.
        vec3 qs = q + seed * vec3(3.7, 1.3, 2.9), qr = mat3(0.0, -0.8, -0.6, 0.8, 0.36, -0.48, 0.6, -0.48, 0.64) * qs;
        float n2 = GNoise3(qr * 1.05 + 5.0);
        float mot = GNoise3(qr * 0.31) * 0.95 + n2 * 0.6;
        float mel = GNoise3(qr.zxy * 0.13 + 11.0) * 1.05 + GNoise3(qr.yzx * 0.47 + 3.0) * 0.55;
        // The body's texture is mirrored (both halves of the worm share it): the half, from its winding on screen, gives
        // each its own spots and pores. body: the worm's body texture (its mouth's dark red at PROBE_B).
        float half_ = step(0.0, du1.x * du2.y - du1.y * du2.x);
        vec2 uo = uv + vec2(seed * 0.173, seed * 0.291) + half_ * vec2(0.37, 0.61);
        bool body = texture2D(texture0, PROBE_B).g < 0.12;
        // (T, B: the surface gradients of u and v, times det; mt the texture's metric on the skin at its mean scale, M = (x y,
        // y z), and in w the most it stretches a circle; an, the ratio of its stretches squared.)
        vec3 dp2perp = cross(dp2, n), dp1perp = cross(n, dp1);
        vec3 T = dp2perp * du1.x + dp1perp * du2.x, B = dp2perp * du1.y + dp1perp * du2.y;
        float tt = dot(T, T), bb = dot(B, B), tb = dot(T, B), dg = max(tt * bb - tb * tb, 1e-36), tr = tt + bb;
        float sa = sqrt(max(tr * tr - 4.0 * dg, 0.0)), an = (tr + sa) / max(tr - sa, 1e-30);
        vec4 mt = vec4(vec3(bb, -tb, tt) * inversesqrt(dg), sqrt(sqrt(an)));
        // Pores in the texture's coordinates, PORE_W world units apart (the grid's density per texture unit from this
        // triangle's texture-to-world ratio, as a power of two blended with the next), bigger and more on the T-zone, in
        // patches; fine fades them out as a cell nears a few pixels.
        float fp = length(abs(du1) + abs(du2));
        float ar = max(sqrt(abs(du1.x * du2.y - du1.y * du2.x) / max(length(cross(dp1, dp2)), 1e-24)), 1e-6);
        float lf = clamp(-log2(PORE_W * ar), 6.0, 13.0);
        float oc = floor(lf), fo = lf - oc, F0 = exp2(oc);
        float big = 1.0 + 0.4 * tzone + 0.3 * mel, dens = clamp(0.45 + 0.4 * tzone + 0.25 * cheek + 0.6 * mot, 0.15, 0.95);
        float fine = 1.0 - smoothstep(0.2, 0.5, fp * F0 * exp2(fo));
        vec3 pore = fine > 0.0 ? mix(Pore(uo * F0, big, dens, mt), Pore(uo * (2.0 * F0) + 0.5, big, dens, mt), fo) : vec3(0.0);
        float pit = pore.x;
        vec2 gPit = pore.yz;
        // The grain: gradient noise on the texture's plane (on the moving skin, mirrored with it: no seam), GRAIN_W units or
        // 4.5 pixels across, whichever is more (two octaves blended), so it shows from the game's distance; gone on a far
        // worm (lumps) and where the texture is stretched on the skin (the chin's front: streaks). gr: value and slope.
        float wpp = sqrt(length(cross(dp1, dp2)));
        float lg = clamp(-log2(max(GRAIN_W, 4.5 * wpp) * ar), 2.0, 12.0), og = floor(lg), Fg = exp2(og);
        vec2 gs = vec2(seed * 0.37, seed * 0.61);
        vec3 gr = mix(GNoise2(uv * Fg + gs), GNoise2(uv * (2.0 * Fg) + gs), lg - og) * (1.0 - smoothstep(0.16, 0.3, wpp)) * (1.0 - smoothstep(1.8, 3.2, an));
        // Creases: rings round the throat, the nape and the back down to the bend (zone, in the worm's frame), each a wavering
        // valley with a roll of skin above it, never thinner than a pixel, faded where closer than ~6 pixels (the fine ones
        // ~11: from afar a line bends at each of the mesh's triangles, as hN is linear in each). Drawn on hN, a
        // fit to the body texture (rising up the body, levelled where the mirrored halves meet, dF and dB; scalp left out), so
        // they stay on the swaying skin; only hN and az place a line (anything per triangle drew it in blocks). pH: a pixel in
        // hN. crease: the valley (0..1); creaseS: the height's slope up the body.
        float crease = 0.0, creaseS = 0.0, az = dot(uv, vec2(-4.8, 5.05)) + 1.47;
        float dF = clamp(dot(uv - vec2(0.5702, 0.2202), vec2(-0.6795, 0.7336)), 0.0, 0.07);
        float dB = clamp(dot(uv - vec2(0.2892, 0.6107), vec2(0.743, -0.6693)), 0.0, 0.07);
        float hN = dot(uv, vec2(32.31, 20.66)) - 14.0 * (dF * dF / 0.14 + 0.035 - dF) + 10.177 * (dB * dB / 0.14 + 0.035 - dB);
        vec3 hD = 32.31 * T + 20.66 * B;
        float pH = length(vec2(dot(vec2(32.31, 20.66), du1), dot(vec2(32.31, 20.66), du2)));
        float zone = framed * Band(q.y, -9.0, -0.5) * mix(Band(q.y, -6.5, -3.0), 1.0, 1.0 - smoothstep(-0.5, 0.3, nq.z)) * (1.0 - smoothstep(0.45, 0.75, abs(nq.y)));
        if (body && zone > 0.0 && (uv.x < 0.57 || uv.y > 0.21)) {
            // (hk: a fold, one in three, whole and wider, or a fine wrinkle broken into lengths; and how deep.)
            float t = hN / 0.5 + 0.3 * sin(2.0 * az + seed) + 0.06 * sin(3.0 * az + 1.7 * seed), k = floor(t);
            float d = (fract(t) - 0.5) * 0.5, hk = fract(sin(k * 12.99 + seed * 7.23) * 437.58), fold = smoothstep(0.62, 0.7, hk);
            float run = 0.5 + 0.5 * sin(az * (2.0 + 3.0 * hk) + hk * 40.0 + seed);
            float dep = sunstoneSkinPores * zone * (0.6 + 0.6 * hs.x) * smoothstep(0.15, 0.5, hk) * mix(run * run, 1.0, fold)
                      * mix(smoothstep(8.0, 14.0, 0.5 / max(pH, 1e-4)), smoothstep(4.5, 8.0, 0.5 / max(pH, 1e-4)), fold);
            float w = max(mix(0.05, 0.1, fold), 0.75 * pH), w2 = w * w, val = exp(-0.5 * d * d / w2), r = d - 2.2 * w, roll = exp(-0.2 * r * r / w2);
            crease = dep * val * mix(0.55, 1.0, fold);
            creaseS = dep * 0.0125 * (d / w2 * val - 0.18 * r / w2 * roll) * (1.0 + fold);
        }
        // Spots, at most one per cell of a grid on the body texture (cells ~0.65 units): a few moles, small red blemishes
        // (more on the face), freckles (most fair and light worms, a few on medium, in patches, more on the upper body and
        // face) big enough to see from the game's distance; faded out below about a pixel.
        float mole = 0.0, freck = 0.0, blem = 0.0;
        if (body) {
            vec2 sg = uo * 52.0, sc = floor(sg);
            vec3 sr = Hash32(sc + 0.5);
            // (The distance in the cell measured on the skin, so a spot is round where the texture is stretched.)
            vec2 so = fract(sg) - 0.5 - (sr.yz - 0.5) * 0.45;
            float sd = sqrt(max(dot(so, vec2(dot(mt.xy, so), dot(mt.yz, so))), 0.0));
            float fw = max(fp * 52.0, 1e-4);
            float frk = smoothstep(0.15, 0.6, fract(seed * 0.1373 + 0.21)) * (1.0 - smoothstep(0.15, 0.4, dark)) * (0.3 + 0.7 * Band(q.y, -4.0, 12.0))
                      * smoothstep(-0.15, 0.15, mel);
            float r = sr.x > 0.996 - 0.004 * hs.z ? mix(0.22, 0.38, sr.y) : (sr.x > 0.994 - 0.004 * face ? mix(0.14, 0.24, sr.z) : (sr.x > 1.0 - 0.55 * frk ? mix(0.12, 0.22, sr.z) : 0.0));
            float m = r > 0.0 ? (1.0 - smoothstep(r - max(0.5 * r, 0.6 * fw), r + 0.6 * fw, sd)) * smoothstep(0.35, 0.9, r / fw) : 0.0;
            if (sr.x > 0.996 - 0.004 * hs.z) mole = m;
            else if (sr.x > 0.994 - 0.004 * face) blem = m * mix(0.5, 1.0, sr.y);
            else freck = m * mix(0.5, 1.0, sr.y);
        }
        float pk = sunstoneSkinPores;
        // The texture's detail as brightness against the peach, not colour (its baked blotches made islands of another hue,
        // its lighter edges a peach rim on a dark tone): darker lines (creases, mouth, lids) kept, a little deeper on a
        // darker tone, at most 40%; the first few percent either way (blotches, 8-bit steps) taken off every value (not a
        // threshold, whose edge drew contours around them); lighter mostly dropped.
        float e = 1.0 - clamp(dot(tex.rgb, LUMW) / PEACH_LUM, 0.35, 1.3);
        e = sign(e) * max(abs(e) - 0.035, 0.0) * (e > 0.0 ? 1.1 + 0.3 * dark : 0.3);
        vec3 alb = tone * (1.0 - min(e, 0.4));
        // Creases redder as well as darker; the face a little redder and darker than the body below it, the back more tanned
        // than the belly, and the skin around the eyes darker and (on light skin) a little violet.
        float crs = clamp(e * 3.0, 0.0, 1.0), ex = abs(q.x) - 2.3, ey = q.y - 3.4;
        float orb = framed * smoothstep(-0.2, 0.4, nq.z) * exp(-(ex * ex + ey * ey) * 0.3);
        alb *= mix(vec3(1.0), vec3(1.0, 0.86, 0.83), 0.6 * crs) * mix(vec3(1.02, 1.02, 1.01), vec3(0.98, 0.93, 0.92), face)
             * mix(vec3(1.0), vec3(0.93, 0.91, 0.88), framed * (1.0 - smoothstep(-0.6, 0.2, nq.z)))
             * mix(vec3(1.0), mix(vec3(0.9, 0.86, 0.9), vec3(0.86, 0.84, 0.84), dark), orb);
        // Blood under the skin: blotchy, most at the cheeks and nose, rose on light skin, red-brown under more pigment,
        // browner and less on an olive one; the lips redder still.
        float olv = abs(pickTone - 4.0) < 0.5 ? 1.0 : 0.0;
        float flush = sunstoneSkinFlush * ruddy * (1.0 - 0.45 * olv) * clamp((0.04 + 0.95 * cheek + 0.7 * tzone * front + 0.08 * face + (body ? 0.0 : 0.4)) * (0.45 + 1.4 * mot), 0.0, 1.0);
        alb *= mix(vec3(1.0), mix(mix(vec3(1.0, 0.8, 0.8), vec3(0.97, 0.83, 0.81), dark), vec3(0.97, 0.88, 0.84), olv), flush);
        alb *= mix(vec3(1.0), mix(vec3(0.9, 0.62, 0.64), vec3(0.8, 0.62, 0.64), dark), clamp(lips * sunstoneSkinFlush, 0.0, 1.0) * 0.6);
        // (Blood blotches redden, and where there is less blood the skin goes a little paler, never grey; the grain's ridges
        // a little lighter.)
        alb *= (1.0 - pk * (0.14 + 0.5 * dark) * mel * vec3(0.8, 1.0, 1.15)) * (1.0 + pk * (0.36 * max(mot, 0.0) * vec3(0.3, -0.45, -0.45)
             + 0.1 * min(mot, 0.0) * vec3(0.6, 0.9, 1.2))) * (1.0 + pk * 0.09 * gr.x * vec3(0.92, 1.0, 1.06));
        // Pores and creases a little darker and redder, and the spots.
        alb *= 1.0 - pk * mix(0.006, 0.1 * pit, fine) * vec3(0.8, 1.0, 1.1);
        alb *= 1.0 - min(crease, 1.0) * 0.16 * vec3(0.86, 1.0, 1.08);
        alb *= mix(vec3(1.0), vec3(0.74, 0.58, 0.46), 0.7 * pk * freck) * mix(vec3(1.0), vec3(1.0, 0.8, 0.78), 0.6 * pk * blem)
             * mix(vec3(1.0), mix(vec3(0.56, 0.42, 0.34), vec3(0.66, 0.54, 0.5), dark), pk * mole);
        albedo = mix(albedo, alb, skin);
        // Oil: the T-zone and the lips, in patches; the cheeks and the body nearly matte.
        float oil = (clamp(0.06 + 0.94 * tzone + 0.6 * lips, 0.0, 1.0) * framed + 0.25 * (1.0 - framed)) * (0.4 + 0.6 * smoothstep(-0.25, 0.25, n2));
        dbgFace = vec3(flush, oil, max(lips, min(crease, 1.0))) * framed;
        if (!GameTerms()) {
            // The normal: the grain, pores and creases by the texture's frame on screen. The diffuse sees a third of the
            // grain (light under the skin smooths it; the sheen shows it): nd.
            float tbn = inversesqrt(max(max(tt, bb), 1e-30));
            vec3 ng = (0.09 * pk * tbn) * (gr.y * T + gr.z * B), nb = n;
            if (fine > 0.0 && pit > 0.0) nb -= 0.4 * pk * fine * tbn * (gPit.x * T + gPit.y * B);
            vec3 up = normalize(view[1].xyz), hu = hD * sign(dot(dp1, dp2perp)) * inversesqrt(max(dot(hD, hD), 1e-30));
            nb -= creaseS * (hu - n * dot(hu, n));
            vec3 nd = normalize(nb - 0.35 * ng);
            nb = normalize(nb - ng);
            // The light with less of its own colour (sunstoneSkinChroma), so each tone keeps its undertone.
            vec3 sunC = mix(vec3(dot(sunLight, LUMW)), sunLight, sunstoneSkinChroma);
            vec3 ambC = mix(vec3(dot(ambLight, LUMW)), ambLight, sunstoneSkinChroma) * sunstoneSkinAmbient;
            // The albedo's colour at unit brightness: light that travelled in the skin comes out deeper in colour (shade and
            // the light's edge stay warm, never grey).
            vec3 hue = alb / max(dot(alb, LUMW), 0.02);
            // Diffuse carried under the skin: each channel sees a softer copy of the bumps the further it travels (red the
            // smoothest) and wraps past the terminator as far, with a band of red scattered light along it.
            float sss = sunstoneSkinSss;
            float nlB = dot(nd, l);
            vec3 nl3 = mix(vec3(litNdl), vec3(nlB), vec3(0.2, 0.5, 0.7));
            vec3 wr = sunstoneWrap + vec3(0.3, 0.1, 0.04) * sss;
            vec3 D = clamp((nl3 + wr) / (1.0 + wr), 0.0, 1.0);
            // (Less of the band where the terminator runs along the outline, a light from behind the camera: a red outline.)
            float tb = (1.0 - smoothstep(0.0, 0.45, abs(litNdl + 0.08))) * (0.15 + 0.85 * smoothstep(0.05, 0.45, dot(n, v)));
            D = (D + sss * 0.12 * tb * tb * vec3(1.0, 0.3, 0.12)) * mix(vec3(1.0), hue, 0.05 * dark)
              * (1.0 - clamp(dot(materialMatrix[0].xyz, vec3(0.333)) * sunstoneSpecular * 0.5, 0.0, 0.5));
            // Shade: the sky's light comes out warmer and deeper, lifted the more the darker the tone, the dimmer the light
            // and the less of it from the sun (as an eye exposes for a dark face: warm mid-tones in shade, not black); fair
            // skin goes rosy, not grey. A crease's valley sees less of the sky.
            float sunY = dot(sunC * D, LUMW), allY = sunY + dot(ambC, LUMW);
            float dim = 1.0 - smoothstep(0.15, 0.6, allY);
            vec3 A = ambC * mix(vec3(1.04, 0.99, 0.94), vec3(1.06, 0.98, 0.9), dark) * mix(vec3(1.0), hue, 0.1 + 0.06 * dark)
                   * (1.0 + sunstoneSkinShade * 1.5 * dark * dark * (0.2 + 1.4 * dim) * (1.0 - 0.85 * sunY / max(allY, 1e-3)))
                   * (1.0 - 0.25 * min(crease, 1.0));
            base = mix(base, sunC * D + A + materialMatrix[1].xyz, skin);
            // The sheen (GGX, white, Fresnel from 0.028): a broad, rough lobe (faint on the matte cheeks and body) and a
            // tight one where the skin is oily, broken by the pores and the grain, shut out of a crease's valley, rougher
            // where the pores were faded out (va).
            float va = 0.06 * (1.0 - fine);
            float poreK = (1.0 - 0.9 * pk * pit * fine) * (1.0 - 0.75 * min(crease, 1.0)) * (1.0 + 0.4 * pk * gr.x);
            float ndh = max(dot(nb, h), 0.0), ldh = max(dot(l, h), 0.0), c2 = ndh * ndh;
            float a1 = 0.36 + va, a2 = mix(0.24, 0.13, oil) + va;
            a1 *= a1;
            a2 *= a2;
            float k1 = c2 * (a1 - 1.0) + 1.0, k2 = c2 * (a2 - 1.0) + 1.0;
            float Fs = 0.028 + 0.972 * pow(1.0 - ldh, 5.0);
            float lobes = (0.55 + 0.85 * oil) * a1 / (k1 * k1) + 0.9 * oil * a2 / (k2 * k2);
            vec3 spec = sunC * (sunstoneSkinSheen * 3.6 * Fs * lobes * poreK * max(dot(nb, l), 0.0) / (4.0 * max(ldh * ldh, 0.15)));
            // The sky's dull reflection, rising toward grazing angles (a dark face's form in shade).
            float ndv = max(dot(nd, v), 0.0);
            float skyR = smoothstep(-0.3, 0.7, dot(reflect(-v, nd), up));
            float Fe = min(0.028 + 0.972 * pow(1.0 - ndv, 5.0), 0.2);
            spec += ambC * (sunstoneSkinSheen * (0.55 + 1.0 * oil) * poreK * 4.0 * Fe * (0.15 + skyR));
            // Light through the skin: a warm glow at thin edges, strongest against the light.
            float thin = pow(1.0 - max(dot(n, v), 0.0), 3.0);
            float back = clamp(-0.1 - 0.9 * dot(v, l), 0.0, 1.0);
            vec3 glow = (sss * thin) * (sunC * back * 1.3 + ambC * 0.08) * alb * hue * vec3(1.15, 0.78, 0.58);
            add = mix(add, spec + glow, skin);
            // Less of the sky's grey rim light (the glow above stands for it).
            rimLight *= mix(1.0, 0.25 + 0.35 * clamp(lumT, 0.0, 1.0), skin);
        }
    } else if (sclera > 0.0) {
        // The eye whites: a natural white, a little darker beside a darker skin but never brown, and wet (a tight highlight
        // and the sky's reflection); shaded toward the eyeball's edge, where the lids and the socket meet it, so the eye
        // sits in the face instead of reading as a flat disc of white.
        float dk = 1.0 - clamp(dot(pickTone > 0.5 ? TONES[int(pickTone + 0.5)] : sunstoneSkinTone, LUMW) / PEACH_LUM, 0.0, 1.0);
        albedo *= mix(vec3(1.0), mix(vec3(0.97, 0.97, 1.0), vec3(0.94, 0.94, 0.96), dk) * mix(vec3(0.6, 0.57, 0.56), vec3(1.0), smoothstep(0.3, 0.85, dot(n, v))), sclera);
        if (!GameTerms()) {
            float ndh = max(dot(n, h), 0.0), a = 0.0049, k = ndh * ndh * (a - 1.0) + 1.0;
            float Fw = 0.02 + 0.98 * pow(1.0 - max(dot(l, h), 0.0), 5.0);
            float skyR = smoothstep(-0.2, 0.8, dot(reflect(-v, n), normalize(view[1].xyz)));
            add += sclera * (sunLight * (0.5 * Fw * a / (k * k) * max(dot(n, l), 0.0)) + ambLight * (0.12 * skyR));
        }
    } else if (hair > 0.0) {
        // Hair: the natural colour times the texture's strand detail, or a dyed hat's own colour; diffuse as before, and in
        // place of the material's highlight the two highlights of a hair fibre along the strands (the texture's v axis),
        // the white one toward the tip, the coloured one toward the root, broken into glints by the strands.
        float idx = hairIdx;
        if (cls == 2.0 && sunstoneHair > 1.5 && pickHair > 0.5) idx = pickHair;
        float lt = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
        float strand = clamp(lt / max(hairMean, 0.02), 0.4, 1.6);
        // Strands along v about four pixels apart at any distance (two octaves blended, so the scale never jumps), in
        // locks a few times wider that are fixed to the texture.
        float lf = log2(0.25 / max(length(vec2(du1.x, du2.x)), 1e-5));
        float oc = floor(lf), f0 = exp2(oc);
        float sn = mix(Noise2(vec2(uv.x * f0, uv.y * 6.0)), Noise2(vec2(uv.x * f0 * 2.0 + 13.0, uv.y * 6.0)), lf - oc);
        float fib = (0.72 + 0.56 * sn) * (0.85 + 0.3 * Noise2(vec2(uv.x * 18.0, uv.y * 2.0) + 5.0));
        vec3 hairAlb = (idx > 0.5 ? HairAlbedo(idx) * strand : tex.rgb) * fib;
        albedo = mix(albedo, hairAlb, hair);
        if (!GameTerms()) {
            vec3 T = cross(dp2, n) * du1.y + cross(n, dp1) * du2.y;
            T -= n * dot(T, n);
            T = dot(T, T) > 1e-14 ? normalize(T) : normalize(cross(n, vec3(0.31, 0.95, 0.0)));
            vec3 t1 = normalize(T + n * 0.12), t2 = normalize(T - n * 0.18);
            float d1 = dot(t1, h), d2 = dot(t2, h);
            float s1 = pow(max(1.0 - d1 * d1, 0.0), 40.0);
            float s2 = pow(max(1.0 - d2 * d2, 0.0), 10.0);
            float glint = clamp(0.2 + 0.9 * strand * fib * fib, 0.0, 1.6);
            float lit = smoothstep(-0.15, 0.35, litNdl);
            vec3 hl = sunLight * lit * glint * sunstoneHairSheen * (0.24 * s1 + 0.55 * s2 * hairAlb);
            add = mix(add, hl, hair);
            rimLight *= mix(1.0, 0.5, hair);
        }
    }

    vec3 col = base * albedo + add + rimLight * mix(vec3(1.0), albedo / max(max(albedo.r, max(albedo.g, albedo.b)), 1e-3), 0.6);
    // Skin in bright light keeps its colour and its highlights stay soft: above a knee it rolls off by the same factor in
    // every channel, toward 0.95 (under the mark's ceiling in PostProcess.RecombineWorms.glsl), the hottest of the sheen a
    // little toward white (per channel, a fair skin in the sun went white, and an oily nose a white blob with a hard edge).
    if (skin > 0.0) {
        float m = max(col.r, max(col.g, col.b)), r = 0.8 + 0.15 * (1.0 - exp((0.8 - m) / 0.15));
        if (m > 0.8) col = mix(col, mix(col * (r / m), vec3(r), 0.3 * smoothstep(1.0, 1.6, m)), skin);
    }
    col = clamp(Shoulder(col), 0.0, 1.0);
    // A theme whose grade greys the frame (Horror's sepia) gets skin a little richer in colour first, so the tones stay apart.
    if (skin > 0.0) col = clamp(mix(col, mix(vec3(dot(col, LUMW)), col, sunstoneSkinVivid), skin), 0.0, 1.0);
    // Skin is dithered by up to a step of the 8-bit target either way before it is stored (and snapped for the mark): the
    // frame's highlight expansion and grade stretch those steps into contour bands across a smooth face otherwise.
    if (skin > 0.0) {
        vec2 fc = gl_FragCoord.xy;
        float dz = fract(52.9829189 * fract(dot(fc, vec2(0.06711056, 0.00583715))))
                 + fract(52.9829189 * fract(dot(fc + vec2(23.0, 41.0), vec2(0.06711056, 0.00583715)))) - 1.0;
        col = clamp(col + dz * skin / 255.0, 0.0, 1.0);
    }
    if (sunstoneMatDebug > 0.5) col = MatDebug(col, matW);
    gl_FragColor = vec4(col, tex.a);
    // Skin marks itself for Bloodsand and Kindjal (see SkinMark; PostProcess.RecombineWorms.glsl passes it on). Only an
    // opaque texel of an opaque layer: a see-through lid keeps the alpha the game blends it with.
    if (skinFam > 0.5 && markable > 0.5 && marking) {
        vec3 q = floor(col * 255.0 + 0.5);
        gl_FragColor = vec4(q / 255.0, SkinMark(q) / 255.0);
    }
    if (sunstoneSkinDebug > 0.5 && (people || marking)) {
        // 1: skin magenta (a glove's skin orange), other worm parts green, moustaches cyan, hair hats yellow (their other
        // parts olive), gloves brown, other matte parts and props blue, all by their own shading. 2: the worm whose colours
        // a fragment takes, a colour per slot.
        float sh = 0.35 + 0.65 * clamp(dot(base, vec3(0.333)), 0.0, 1.0);
        vec3 c = col * 0.35;
        if (sunstoneSkinDebug > 3.5) {
            // 4: the skin's sheen and glow alone, doubled.
            if (skin > 0.0) c = add * 2.0;
        } else if (sunstoneSkinDebug > 2.5) {
            // 3: the face: red the blood showing through, green the oiliness, blue the lips and folds; other skin dim grey.
            if (skin > 0.0) c = dbgFace * 0.85 + vec3(0.15) * sh;
        } else if (sunstoneSkinDebug < 1.5) {
            if (skinFam > 0.5) c = cls == 1.0 ? vec3(1.0, 0.5, 0.0) : vec3(1.0, 0.0, 1.0);
            else if (WormMaterial()) c = vec3(0.0, 0.8, 0.2);
            else if (cls == 2.0) c = vec3(0.0, 0.9, 1.0);
            else if (cls >= 3.0) c = hair > 0.5 ? vec3(1.0, 0.9, 0.0) : vec3(0.5, 0.45, 0.0);
            else if (cls == 1.0) c = vec3(0.45, 0.25, 0.0);
            else if (MatteMaterial()) c = vec3(0.15, 0.3, 0.9);
            c *= sh;
        } else if (pickSlot >= 0.0) {
            c = (0.5 + 0.5 * cos(6.2831 * (pickSlot / 16.0 * 3.0 + vec3(0.0, 0.33, 0.67)))) * sh;
        }
        gl_FragColor = vec4(c, tex.a);
    }
}
