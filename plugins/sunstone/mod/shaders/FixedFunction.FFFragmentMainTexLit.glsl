#version 130
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
// The tables are uniforms with initializers, not consts: AMD's GL driver keeps a large const array that is indexed
// at run time in per-fragment scratch memory and fills it in every fragment, which cost about 21 ms a frame at
// Ultra on a full-width matte band of the front end; a uniform array is read from the constant buffer. Melange only
// writes uniforms a Cg program or params.ini names, so keep them out of params.ini: the initializers stand (Melange
// logs that each table 'stays 0'; it does not).
// probe A colour, class * 16 + hair colour (sorted by red, see Fingerprint)
uniform vec4 FP_A[FP_N] = vec4[FP_N](
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
uniform vec4 FP_B[FP_N] = vec4[FP_N](
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
uniform vec4 FP_C[FP_N] = vec4[FP_N](
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

// Shared material maps (mod/assets/detail/materials.png, made by tools/make_detail_maps.py): eight original tileable
// 256x256 layers in one texture array, bound by init.lua with wum.shaders.setTexture (Melange 0.10; the host shader is
// #version 130 for sampler2DArray). Every channel 0.5 = neutral, which is also what Melange's sampler reads before a
// texture is bound: R,G tangent normal xy (x along +u, y along +v), B height (0.5 the surface, below cavities), A a
// variation about 0.5 (roughness + rougher, or albedo + lighter; the wear order on MAT_MAP_WEAR). Mips are plain
// averages: the normal flattens with distance. The helpers (MatMap...) follow MatFbm; layers and scales:
// tools/materials/README.md.
uniform sampler2DArray sunstoneMat;
const float MAT_MAP_GRAIN = 0.0;    // fine grain and pores (plastic, paint, skin-like matte); A roughness
const float MAT_MAP_WOOD = 1.0;     // wood grain along u with pores; A albedo
const float MAT_MAP_BRUSHED = 2.0;  // brushed metal along u, scratches at all angles; A roughness
const float MAT_MAP_STONE = 3.0;    // stone / concrete: pits, veins, mottle; A albedo
const float MAT_MAP_WEAVE = 4.0;    // plain weave, 16 threads a tile, fibres; A albedo
const float MAT_MAP_BUMPS = 5.0;    // leather / rubber / organic pebbling with creases; A roughness
const float MAT_MAP_WEAR = 6.0;     // chips, scratches, scuffs; A the wear order (worn where A > 1 - wear)
const float MAT_MAP_BARK = 7.0;     // bark fissures along v and a crack network; A albedo
const float MAT_MAP_TEXELS = 256.0; // a layer's size

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

// ---- shared material maps (sunstoneMat, above). The sample is a vec4; 0.5 in every channel is neutral.
// The raw sample of layer at uvScaled (the map's own coordinates: one tile per unit, e.g. m.uv * 8.0), the mip and
// anisotropy from the sampler. Implicit derivatives: only in uniform control flow, i.e. not after a per-fragment
// branch in a snippet (such as 'if (m.fade <= 0.0) return o;'); MatMapAt is safe anywhere.
vec4 MatMap(float layer, vec2 uvScaled) {
    return texture(sunstoneMat, vec3(uvScaled, layer));
}
// The map tiled freq times per texture unit (a whole number keeps the texture's own wrap seamless) at
// m.uv * freq + offset, with explicit derivatives (the same mip and anisotropy as MatMap, safe in any branch).
vec4 MatMapAt(MatIn m, float layer, float freq, vec2 offset) {
    return textureGrad(sunstoneMat, vec3(m.uv * freq + offset, layer), m.uvDx * freq, m.uvDy * freq);
}
// Footprint fade for a map tiled freq times per texture unit whose features are about texels map texels across:
// 1 while a feature covers four pixels or more, 0 at two (where its lighting would sparkle). The mips flatten the
// normal by themselves; this takes what a snippet derives from the sample (gloss, cavity) to neutral before it aliases.
float MatMapFade(MatIn m, float freq, float texels) {
    return MatFadeUv(m, freq * MAT_MAP_TEXELS / max(texels, 1e-3));
}
// A sample pulled toward neutral (vec4(0.5)): k 1 the sample, 0 neutral (e.g. k = MatMapFade(...)).
vec4 MatMapNeutral(vec4 s, float k) {
    return mix(vec4(0.5), s, k);
}
// A layer sized in world units: a tile about tileWorld world units across (multiply by m.scale yourself), the two
// power-of-two octaves around it blended (MatOctave) so the size never jumps between triangles, faded to neutral by
// the footprint of features texels across. Two samples.
vec4 MatMapWorld(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.37, 0.61)), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}
// The eye-space normal perturbation (for MatOut.dn) of a sample's R,G; amount 1 = the map's own slopes.
vec3 MatMapBump(MatIn m, vec4 s, float amount) {
    vec2 t = (s.xy * 2.0 - 1.0) * amount;
    return t.x * m.tu + t.y * m.tv;
}
// A sample's height about the surface (-0.5..0.5, < 0 cavities) and its variation (-0.5..0.5).
float MatMapHeight(vec4 s) {
    return s.z - 0.5;
}
float MatMapVar(vec4 s) {
    return s.w - 0.5;
}

// ---- colour: a variation of up to amount in brightness with a touch of warmth, keeping the art's hue (r: -1..1).
vec3 MatVary(vec3 c, float amount, float r) {
    return c * (1.0 + amount * r * vec3(1.02, 1.0, 0.97));
}

// ---- degenerate mapping guard. Where a texture's footprint on the surface collapses (UVs that converge to a point, as
// in a gun's bore or a cone's tip; a texture stretched along one direction; a texture spread over hundreds of world
// units or squeezed into a fraction of one) the world-space detail that follows the UVs pinches into stars and streaks,
// and the divisions by uvPerWorld and the surface gradients blow up. This is 1 for every ordinary mapping and falls to 0
// as the mapping degenerates; MatSetup folds it into m.fade, which the dispatcher applies to everything.
//   - stretch (aniso): 1 up to 3 (a plane at a steep angle is about 3), 0 from 8
//   - the texel density changing fast across the screen (uvPerWorld halving every few pixels: a converging mapping):
//     1 below 0.06 octaves a pixel, 0 from 0.2 (1/r of the pinch: it clears about 20 pixels from the point)
//   - an extreme density: a tile over 1000 world units, or under one-twentieth of a unit
float MatDegenerate(MatIn m) {
    float lg = log2(m.uvPerWorld);
    float rate = abs(dFdx(lg)) + abs(dFdy(lg));
    float g = 1.0 - smoothstep(3.0, 8.0, m.aniso);
    g *= 1.0 - smoothstep(0.06, 0.2, rate);
    g *= smoothstep(1e-3, 4e-3, m.uvPerWorld) * (1.0 - smoothstep(20.0, 60.0, m.uvPerWorld));
    return g;
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
    m.fade = (1.0 - smoothstep(MAT_FADE_FAR / 3.0, MAT_FADE_FAR, d)) * smoothstep(0.03, 0.2, m.ndv) * MatDegenerate(m);
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
// -- bare_metal.glsl
// @class bare_metal
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=0.6 b=0
// @param wear: scratches and scuffs breaking the polish (0 none .. 1 a well used tool)
// @param tint: the reflection of sky and ground in the metal (1 = up to about 10% either way)
// @param a: anisotropy: how far the highlight is drawn out across the brushing (0 round .. 1 long streaks)
// @param b: brushing direction: 0 along the texture's u, 1 along v
// Steel, iron, chrome, tin. The art paints the metal's shading; this adds what it cannot: a tight highlight drawn out
// across the brushing, the sky and ground reflected in the metal (moves with the view), soft dents and smudges that
// break the polish, and brushed streaks and scratches close up. Atlas texels that are not metal (paint, gems, lamps,
// black holes) keep a plain painted response.
// Shared by every untagged glossy material (the fallback for metal), so it stays calm.

// How metallic a texel looks: greys and golds 1, saturated paint 0, near-black 0.
float mat_bare_metal_key(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    float gold = smoothstep(0.62, 0.75, gr) * (1.0 - smoothstep(1.0, 1.1, gr)) * step(c.b, c.g);
    return max(1.0 - smoothstep(0.16, 0.36, sat), gold) * smoothstep(0.05, 0.16, mx);
}

// One octave of the dents at F cells per texture unit, (value, d/duv). The lattice offset depends only on F, so the
// octave at 2 * F0 (blended in as the density falls) is the same field as the next F0 octave: no seam where F0 doubles.
vec3 mat_bare_metal_dent(MatIn m, float F) {
    vec2 off = vec2(m.seed * 31.0) + fract(F * vec2(0.6180340, 0.4142136)) * 23.0;
    return MatGNoise(m.uv * F + off, F) * vec3(1.0, F, F);
}
// The brushed map tiled F times per texture unit along the brushing (uvb and its derivatives swapped for b = 1), at an
// offset that depends only on F (as above).
vec4 mat_bare_metal_brush(vec2 uvb, vec2 dxb, vec2 dyb, float F) {
    vec2 off = fract(F * vec2(0.7548777, 0.5698403));
    return textureGrad(sunstoneMat, vec3(uvb * F + off, MAT_MAP_BRUSHED), dxb * F, dyb * F);
}

MatOut mat_bare_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float metal = mat_bare_metal_key(m.albedo);
    bool alongV = m.p.w > 0.5;
    vec3 T = alongV ? m.tv : m.tu;   // the brushing
    vec3 B = alongV ? m.tu : m.tv;   // across it
    vec2 uvb = alongV ? m.uv.yx : m.uv, dxb = alongV ? m.uvDx.yx : m.uvDx, dyb = alongV ? m.uvDy.yx : m.uvDy;

    // Dents and smudges: smooth gradient noise, cells about 5 world units (soft, wide undulations, as a pressed or
    // forged surface has), two octaves blended so the size never jumps between triangles.
    float D0, db;
    MatOctave(m, 5.0 * m.scale, D0, db);
    vec3 g = mix(mat_bare_metal_dent(m, D0), mat_bare_metal_dent(m, 2.0 * D0), db);
    float gk = MatFadeUv(m, D0 * (1.0 + db));
    // Brushed streaks and scratches along the brushing, a tile about 14 world units, two octaves blended (so the tile
    // never doubles between triangles).
    float F0, fb;
    MatOctave(m, 14.0 * m.scale, F0, fb);
    vec4 s = mix(mat_bare_metal_brush(uvb, dxb, dyb, F0), mat_bare_metal_brush(uvb, dxb, dyb, 2.0 * F0), fb);
    s = MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), 3.0));
    vec2 sn = s.xy * 2.0 - 1.0;
    vec3 dnB = sn.x * T + sn.y * B;   // (the swapped sample's x runs along the brushing either way)

    // Height 0.14 world units over a 5-unit cell: tilts of a few degrees, a subtle ripple that bends a tight highlight
    // without splitting it into several hot spots (0.35 did, on a helmet).
    o.dn = metal * (MatBumpUv(m, g.yz * (0.14 * m.scale * gk)) + 0.35 * dnB);
    // Polish: smudges (the noise) and, with wear, scratches (brushed A) rougher; dents a little darker in the hollows.
    float rough = clamp(0.8 * g.x * gk + (0.6 + 0.8 * m.p.x) * max(MatMapVar(s), 0.0), -0.5, 0.6);
    o.gloss = mix(1.4, 2.8 * (1.0 - 0.9 * rough), metal);
    o.spec = mix(1.0, 1.05 - 0.3 * rough, metal);
    o.ao = 1.0 + 0.6 * metal * min(MatMapHeight(s), 0.0);

    // Anisotropy (as Ashikhmin-Shirley's exponent): the gloss falls for a half vector leaning across the brushing, so
    // the highlight is drawn out in a streak across the grain. Only the exponent changes: the diffuse light is untouched.
    vec3 n2 = normalize(m.n + o.dn);
    vec3 h = normalize(m.l + m.v);
    float hu = dot(h, T), hv = dot(h, B);
    float r = 1.0 - 0.88 * metal * clamp(m.p.z, 0.0, 1.0);
    o.gloss *= (hu * hu + r * hv * hv + 1e-4) / (hu * hu + hv * hv + 1e-4);

    // The sky and ground in the metal: brighter where it reflects the sky, a dark horizon line, darker below; stronger
    // at grazing angles.
    float ry = dot(reflect(-m.v, n2), m.up);
    float env = 0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.1;
    o.albedo = m.albedo * (1.0 + 0.2 * m.p.y * metal * (0.7 + 0.6 * (1.0 - m.ndv)) * env);
    return o;
}
// -- bone_teeth.glsl
// @class bone_teeth
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1 b=0
// @param a: pores and hairline cracks (0 none, 1 aged bone, 1.5 fossil)
// @param b: polish (0 dry matte bone, 1 glossy enamel / shell / acrylic)
// @param wear: unused
// Bone, teeth, shell, eggshell: fine pores that catch shade, hairline cracks (cavity and a thin groove in the normal),
// a faint patina in the light. b > 0 turns it into enamel: smoother, a tight sheen broken up by a faint, broad
// waviness (so the highlight is not a plastic dot), almost no pores, and a translucent edge (enamel lets light through
// at grazing angles: a warm lift toward the silhouette).
// Cost: 4 textureGrad (two world-tiled pairs: pores, cracks / waviness), no noise.
MatOut mat_bone_teeth(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, pol = clamp(m.p.w, 0.0, 1.0);
    // pores: ~3 world unit tile of 3-texel features
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 3.0 * m.scale, 3.0);
    float h = MatMapHeight(g);
    o.dn = MatMapBump(m, g, 0.9 * amt * (1.0 - 0.7 * pol));
    float pit = max(-h - 0.04, 0.0) * 4.0;
    o.ao = 1.0 - clamp(pit * 0.55 * amt, 0.0, 0.45) * (1.0 - 0.8 * pol);
    // hairline cracks: the crack network of the bark layer, thresholded thin (large tile: few, long cracks); enamel
    // (b > 0.5, where cracks are muted anyway) takes the stone layer's soft fbm relief instead, for its waviness
    bool enamel = pol > 0.5;
    vec4 c = MatMapWorld(m, enamel ? MAT_MAP_STONE : MAT_MAP_BARK, (enamel ? 24.0 : 14.0) * m.scale, 5.0);
    float crack = (1.0 - smoothstep(-0.42, -0.30, MatMapHeight(c))) * (1.0 - pol * 0.7);
    // enamel waviness: the same broad sample as a soft normal (polished surfaces only), so the tight highlight wobbles
    o.dn += MatMapBump(m, c, 0.25 * amt + 0.2 * pol);
    o.ao *= 1.0 - 0.3 * crack * amt;
    // faint patina, darker in cracks and pores
    o.albedo = MatVary(m.albedo, 0.05 * m.p.y * (1.0 - 0.6 * pol), 1.5 * MatMapVar(c) + MatMapVar(g));
    o.albedo *= 1.0 - 0.03 * crack * amt;
    // translucent edge: enamel and shell lift toward the silhouette, a touch warm (dry bone: none)
    float rim = 1.0 - m.ndv;
    rim *= rim;
    o.albedo *= 1.0 + 0.22 * pol * rim * vec3(1.04, 1.0, 0.9);
    // sheen: dry bone a dull satin (rougher in pores), enamel a tight bright highlight
    o.gloss = mix(0.8, 2.4, pol) * (1.0 - 0.6 * pit * (1.0 - pol));
    o.spec = mix(0.9, 1.25, pol) * (1.0 + 2.0 * MatMapVar(g) * (1.0 - pol));
    return o;
}
// -- brick.glsl
// @class brick
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1.5 b=-1
// @param wear: grime in the mortar joints (0 none, 1 heavy)
// @param tint: albedo variation of the clay (1 = about 3% either way)
// @param a: relief from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance
// @param b: which way the art's relief goes: -1 the joints are paler than the bricks (they sink), +1 darker (tiles, carved)
// Brick, block and roof tile: the joints set back from the art's own lines (paler or darker by b), sandy and dull, the
// faces fired clay with pits and a faint sheen on their worn tops, edges caught by the light.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
// rel: the art's luminance here less the taps' mean (above or below its surroundings), only where a texel covers 1.5
// to 3 pixels or more (a line detector at the pixel's own scale would alias when minified).
vec3 mat_brick_art(MatIn m, float depth, out float rel) {
    rel = 0.0;
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    if (abs(det) < 1e-14) return vec3(0.0);
    vec2 ts = vec2(textureSize(texture0, 0));
    float tp = max(m.uvPx * max(ts.x, ts.y), 1e-6);
    float lod = max(log2(tp), 0.0);
    vec2 e = exp2(lod) / ts;
    float pp = MatLum(textureLod(texture0, m.uv + e, lod).rgb), mm = MatLum(textureLod(texture0, m.uv - e, lod).rgb);
    float pm = MatLum(textureLod(texture0, m.uv + vec2(e.x, -e.y), lod).rgb), mp = MatLum(textureLod(texture0, m.uv + vec2(-e.x, e.y), lod).rgb);
    vec2 sl = 0.25 * vec2(pp + pm - mp - mm, pp + mp - pm - mm) / e;
    rel = (MatLum(textureLod(texture0, m.uv, lod).rgb) - 0.25 * (pp + pm + mp + mm)) * smoothstep(1.5, 3.0, 1.0 / tp);
    vec3 d = MatBumpUv(m, sl * (depth * (1.0 - 0.4 * smoothstep(3.0, 8.0, 1.0 / tp))));
    // (The footprint's elongation on screen: 1 face on, about 1 / cos of the view angle when grazing.)
    float el = m.uvPx * m.uvPx / abs(det);
    return d * (min(1.0, 0.3 * inversesqrt(max(dot(d, d), 1e-8))) * (1.0 - smoothstep(2.0, 3.6, el)));
}

MatOut mat_brick(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float lum = MatLum(c), mx = max(c.r, max(c.g, c.b));
    float sat = (mx - min(c.r, min(c.g, c.b))) / max(mx, 1e-3);
    // The joint: the art's grey or pale mortar (its saturation low), not snow or white paint (very bright).
    float joint = (1.0 - smoothstep(0.16, 0.32, sat)) * (1.0 - smoothstep(0.7, 0.85, lum));
    // Snow or white paint (bright and grey): not clay, and it sits on top. It keeps the art's relief only on the + side
    // (snow higher than what it lies on) and gets no clay pits or grain.
    float snow = smoothstep(0.7, 0.85, lum) * (1.0 - smoothstep(0.1, 0.25, sat));
    // The art's relief, signed by b: the joints sink. Where the magnified art is lower than its surroundings (darker
    // with b +1, paler with b -1) it is a joint or a gap: a cavity, also where the joint is not grey.
    float sb = mix(m.p.w, abs(m.p.w), snow), rel;
    o.dn = mat_brick_art(m, (0.4 * m.p.z * sb), rel);
    float gap = clamp(-rel * sb * (5.0 * m.p.z), 0.0, 1.0);
    // Fired clay: pits and a sandy grain from the stone map, a tile about 16 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 16.0 * m.scale, 6.0);
    float h = MatMapHeight(s), va = MatMapVar(s);
    o.dn += MatMapBump(m, s, 0.3 * (1.0 - snow));
    float pit = smoothstep(-0.2, -0.4, h) * (1.0 - snow);
    // Cavity in the joints and pits; grime in the joints by wear.
    o.ao = (1.0 - 0.12 * joint) * (1.0 - 0.3 * pit) * (1.0 - 0.25 * gap);
    o.albedo = MatVary(c, 0.03 * m.p.y * (1.0 - joint) * (1.0 - snow), 1.2 * va + 0.5 * h);
    o.albedo *= 1.0 - 0.1 * m.p.x * joint * pit;
    // Joints sandy and dull; brick faces a little sheen on their raised tops.
    o.spec = mix(0.95 + 0.5 * max(h, 0.0), 0.6, joint) * (1.0 - 0.5 * pit);
    o.gloss = mix(1.0 + 0.5 * max(h, 0.0), 0.7, joint);
    // Pay back the joints' cavity on the albedo (the mean brightness stays the art's).
    o.albedo *= 1.0 + 0.025 * joint;
    return o;
}
// -- cartoon_flat.glsl
// @class cartoon_flat
// @default scale=1 strength=0.8 rough=0 wear=0 tint=0.4 a=0.45 b=0.4
// @param tint: mottle of the enamel in the albedo (1 = about 3% either way)
// @param a: enamel sheen (0 matte .. 1 glossy lacquer)
// @param b: relief of the art's own edges (0 none .. 1 embossed)
// Flat comic art, stickers, UI planes, sprites: the colours stay as drawn. The surface reads as a painted enamel: a
// soft orange-peel ripple (the GRAIN map at a 22-unit tile, features about a quarter of a world unit, so it still
// shows at the game's distance and fades out by its footprint beyond), a sheen where the colour is saturated, broken
// by that ripple so it is never a flat plastic gloss, and, from the art's own luminance edges, a faint emboss so
// outlines read as a pressed or moulded edge. Gold-ish texels (red >= green >= blue, saturated, bright; graded, no
// hard switch) get a metallic leaning sheen (atlases with fittings).
MatOut mat_cartoon_flat(MatIn m) {
    MatOut o = MatNone(m.albedo);
    // The art's edges as a very low relief (no fetch). Slope capped so it can never become a bevel.
    vec3 e = MatBumpScreen(m, m.lumD * (0.18 * m.scale));
    e *= min(1.0, 0.25 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float gold = smoothstep(0.45, 0.7, sat) * smoothstep(0.35, 0.6, lum)
               * smoothstep(0.02, 0.08, c.r - c.g) * smoothstep(0.02, 0.08, c.g - c.b);
    float ink = smoothstep(0.1, 0.45, sat) * smoothstep(0.08, 0.2, lum);   // coloured paint (not black, not grey)
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 22.0 * m.scale, 3.0);
    float var = MatMapVar(g);
    o.dn = e * (m.p.w * 1.2) + MatMapBump(m, g, 0.3);
    o.albedo = MatVary(c, 0.08 * m.p.y, 2.0 * MatMapHeight(g));
    float sh = m.p.z * ink;
    o.spec = 1.0 + 1.1 * sh + 0.8 * gold - 0.6 * var * (sh + 0.3);
    o.gloss = 1.0 + 1.2 * sh - 2.0 * var * sh + 1.0 * gold;
    return o;
}
// -- concrete_plaster.glsl
// @class concrete_plaster
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=0.3 b=0.3
// @param wear: grime in the pores and cracks (0 none, 1 heavy)
// @param tint: albedo variation, broad stains (1 = about 2.5% either way)
// @param a: relief from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance
// @param b: hairline cracks (a procedural network, no direction): 0 none, 1 strong
// Plaster, render and cast concrete: a hand-trowelled waviness at two sizes, fine pores from the stone map, hairline
// cracks, broad faint stains, very matte; the art's own carving or engraving lit as relief.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
vec3 mat_concrete_plaster_art(MatIn m, float depth) {
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    if (abs(det) < 1e-14) return vec3(0.0);
    vec2 ts = vec2(textureSize(texture0, 0));
    float tp = max(m.uvPx * max(ts.x, ts.y), 1e-6);
    float lod = max(log2(tp), 0.0);
    vec2 e = exp2(lod) / ts;
    float pp = MatLum(textureLod(texture0, m.uv + e, lod).rgb), mm = MatLum(textureLod(texture0, m.uv - e, lod).rgb);
    float pm = MatLum(textureLod(texture0, m.uv + vec2(e.x, -e.y), lod).rgb), mp = MatLum(textureLod(texture0, m.uv + vec2(-e.x, e.y), lod).rgb);
    vec2 sl = 0.25 * vec2(pp + pm - mp - mm, pp + mp - pm - mm) / e;
    vec3 d = MatBumpUv(m, sl * (depth * (1.0 - 0.4 * smoothstep(3.0, 8.0, 1.0 / tp))));
    // (The footprint's elongation on screen: 1 face on, about 1 / cos of the view angle when grazing.)
    float el = m.uvPx * m.uvPx / abs(det);
    return d * (min(1.0, 0.3 * inversesqrt(max(dot(d, d), 1e-8))) * (1.0 - smoothstep(2.0, 3.6, el)));
}

// Hairline cracks: where gradient noise crosses zero, a closed network with no direction, cells about sizeWorld apart
// (the two octaves blended as MatOctave does, from one lattice offset so the blend is continuous across octaves).
// jag (a fine height, e.g. the pores') makes the lines ragged instead of smooth loops; its own slope is left out.
// Returns (crack 0..1, d crack / duv); a crack's line is about w of a cell wide, faded out before it is under 2 pixels.
vec3 mat_concrete_plaster_crack(MatIn m, float sizeWorld, float w, float jag) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 r = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        float f = F0 * (1.0 + float(i));
        vec3 n = MatGNoise(m.uv * f + (6.1 + 9.0 * m.seed), f);
        float t = clamp(abs(n.x + jag) / w, 0.0, 1.0);
        vec3 k = vec3(1.0 - t * t * (3.0 - 2.0 * t), (-6.0 * t * (1.0 - t) / w * sign(n.x + jag) * f) * n.yz);
        r += k * (i == 0 ? 1.0 - fb : fb) * MatFadeUv(m, f / (2.0 * w));
    }
    return r;
}

// One octave-blended gradient noise for features sizeWorld apart: (value, d/duv), faded by its footprint (gone at
// 2 * strict pixels a cell). Both octaves from one lattice offset, so the 2 * F0 octave at blend 1 is the next F0
// octave at blend 0 (no switch of pattern).
vec3 mat_concrete_plaster_wave(MatIn m, float sizeWorld, float offset, float strict) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0 + offset, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + offset, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    return g * MatFadeUv(m, F0 * (1.0 + fb) * strict);
}

MatOut mat_concrete_plaster(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    o.dn = mat_concrete_plaster_art(m, (0.4 * m.p.z));
    // Trowelled render: broad waves about 9 world units across, 0.7 deep, and trowel strokes about 5 across, 0.15 deep,
    // each gone before a cell is under 4 pixels (what survives at the game's distance is the broad waves' light);
    // broad stains with the waves.
    vec3 g = mat_concrete_plaster_wave(m, 9.0 * m.scale, 2.9, 2.0);
    vec3 t = mat_concrete_plaster_wave(m, 5.0 * m.scale, 11.3, 2.0);
    o.dn += MatBumpUv(m, (g.yz * 0.7 + t.yz * 0.15) * m.scale);
    // Pores: the stone map, a tile about 18 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 18.0 * m.scale, 6.0);
    float h = MatMapHeight(s);
    o.dn += MatMapBump(m, s, 0.3);
    float pit = smoothstep(-0.28, -0.45, h);
    // Hairline cracks, cells about 10 world units across, 0.08 deep (a uniform branch on the parameter).
    if (m.p.w > 0.0) {
        vec3 k = mat_concrete_plaster_crack(m, 10.0 * m.scale, 0.03, 0.08 * h) * m.p.w;
        o.dn += MatBumpUv(m, k.yz * (-0.08 * m.scale));
        pit = max(pit, k.x);
    }
    o.ao = 1.0 - 0.2 * pit;
    o.albedo = MatVary(m.albedo, 0.025 * m.p.y, 1.6 * g.x + 0.4 * h);
    o.albedo *= 1.0 - 0.08 * m.p.x * pit;
    // Very matte, duller still in the pores and cracks.
    o.spec = 0.85 * (1.0 - 0.5 * pit);
    o.gloss = 0.8;
    return o;
}
// -- emissive_light.glsl
// @class emissive_light
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0
// @param tint: strength of the glow's inner variation (1 = about 6% either way, bright texels only; 0 for flat glows)
// @param a: pixel grid cells per texture unit (LED screens; 0 none)
// @param b: scanlines, in fours per texture unit (b=8: 32 lines; displays; 0 none)
// Light sources, glows, screens, sparks: stays unlit-looking, so no normal detail on a glow and the material's own
// specular (never less: a glow must not get darker). Only the colour moves, never down on average: a slow variation
// inside the bright part of the glow (zero mean), the hot core a little brighter, and optional LED grid / scanlines
// (zero mean). A black screen has no colour to move: its LED grid is in the light (each pixel domed, the gaps matte).
MatOut mat_emissive_light(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    vec3 c = m.albedo;
    if (m.p.y > 0.0) {
        float F0, fb;
        MatOctave(m, 3.0 * m.scale, F0, fb);
        float k = MatFadeUv(m, F0 * (1.0 + fb));
        float n = mix(MatGNoise(m.uv * F0, F0).x, MatGNoise(m.uv * (2.0 * F0) + 5.0, 2.0 * F0).x, fb);
        // Bright texels vary the most (the hot core flickers), dark ones stay put, and a saturated channel (which
        // would clip the upper half and darken on average) not at all.
        float mx = max(c.r, max(c.g, c.b));
        c *= 1.0 + 0.12 * m.p.y * k * smoothstep(0.1, 0.6, lum) * (1.0 - smoothstep(0.85, 0.98, mx)) * n;
    }
    // Hot core: a little brighter and a touch toward white.
    float hot = smoothstep(0.6, 1.0, lum);
    c *= 1.0 + 0.07 * hot;
    c = mix(c, vec3(max(c.r, max(c.g, c.b))), 0.06 * hot);
    float pat = 1.0;
    if (m.p.z > 0.0) {
        // Cells with gaps of about an eighth of a cell; the gap term's mean over a cell is 0.231, so the pattern
        // (and the specular one) averages to exactly 1. Faded by the gap's own frequency, not the cell's.
        vec2 f = fract(m.uv * m.p.z) - 0.5;
        float line = smoothstep(0.75, 1.0, 2.0 * max(abs(f.x), abs(f.y)));
        float kk = MatFadeUv(m, 5.0 * m.p.z);
        pat *= 1.0 + 0.3 * kk * (0.231 - line);
        o.spec = 1.0 + 0.8 * kk * (0.231 - line);
        o.gloss = 1.0 + 1.5 * kk;
        // Each LED a shallow dome (the slope grows from the centre), the gaps flat.
        o.dn = MatBumpUv(m, -f * (1.0 - line) * (0.5 * kk / m.uvPerWorld));
    }
    if (m.p.w > 0.0) {
        float sl = 4.0 * m.p.w, kk = MatFadeUv(m, 2.0 * sl);
        pat *= 1.0 + 0.16 * kk * cos(6.2831853 * m.uv.y * sl);
    }
    o.albedo = c * pat;
    return o;
}
// -- fabric_cloth.glsl
// @class fabric_cloth
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.25 b=0
// @param tint: thread-to-thread and band colour variation (1 = about 3% either way)
// @param wear: faded, pilled spots (0 none, 0.5 well used)
// @param a: thread spacing in world units (0.25 cotton twill; 0.4 canvas, burlap; 0.15 silk, satin ribbon)
// @param b: finish: -1 felt, wool or velvet nap (fuzz, no weave); 0 woven cotton or canvas; 1 satin or silk (sheen)
// Cloth: the painted folds get real relief from the art's own shading, the threads of the shared weave map (felt: a
// fine fuzz instead) come in close up, bands of slightly thicker and thinner threads stay from mid distance, and the
// game's plastic-like highlight becomes a broad, dim cloth sheen with a light lift at grazing angles (satin: a
// tighter, brighter one). Atlas parts that are not cloth keep the game's material: skin-like peach texels and dense
// art detail (chains, badges, rivets, lens rims: texels far from their blurred surroundings).
// Reads texture0 (the host's bound texture, declared before the materials block) for the blurred relief taps.

// The 1D value noise of whole cells along x (period P cells, seamless with the texture), -0.5..0.5.
float mat_fabric_cloth_band(float x, float P, float salt) {
    float i = floor(x), f = fract(x);
    float h0 = MatHash12(vec2(mod(i, P), salt)), h1 = MatHash12(vec2(mod(i + 1.0, P), salt));
    return mix(h0, h1, f * f * (3.0 - 2.0 * f)) - 0.5;
}

// Bands of 4 threads along u and along v at the weave's octave F (threads 16 a tile): (u bands, v bands).
vec2 mat_fabric_cloth_bands(MatIn m, float F) {
    float P = 4.0 * F;
    return vec2(mat_fabric_cloth_band(m.uv.y * P, P, 3.7 + m.seed), mat_fabric_cloth_band(m.uv.x * P, P, 9.1 + m.seed));
}

MatOut mat_fabric_cloth(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float b = clamp(m.p.w, -1.0, 1.0), felt = max(-b, 0.0), satin = max(b, 0.0);
    float tint = m.p.y;

    // ---- atlas key: 1 cloth, 0 keep the game's material. Peach skin (hands, faces in the glove and hat atlases) here,
    // dense art detail (busy, below) once the blurred taps are in.
    float r = max(c.r, 1e-3);
    float skin = step(c.g, c.r) * step(c.b, c.g) * smoothstep(0.5, 0.62, c.r)
               * (1.0 - smoothstep(0.07, 0.12, abs(c.g / r - 0.65))) * (1.0 - smoothstep(0.1, 0.16, abs(c.b / r - 0.42)));
    // ---- folds: the art's painted shading as soft relief (bright = raised). Three taps of the art blurred a mip or
    // two above the pixel's own (stipple and texel steps gone, the painted folds kept), a few texels apart.
    vec2 tsz = vec2(textureSize(texture0, 0));
    float lod = max(log2(max(m.uvPx * max(tsz.x, tsz.y), 1e-6)), 0.0) + 1.5;
    vec2 e = exp2(lod) / tsz;
    vec2 tc = m.uv - 0.5 * e;
    vec3 t0 = textureLod(texture0, tc, lod).rgb;
    vec3 su = textureLod(texture0, tc + vec2(e.x, 0.0), lod).rgb;
    vec3 sv = textureLod(texture0, tc + vec2(0.0, e.y), lod).rgb;
    float l0 = MatLum(t0), lu = MatLum(su), lv = MatLum(sv);
    // Printed colour boundaries (stripes, panels, logos, a band in another colour) are flat, not folds. A print border
    // is a sharp step in the art that also changes chromaticity (rgb over its sum: hue and saturation); painted
    // shading is a smooth ramp (the texel close to its blurred surroundings), and a painted crease keeps its hue.
    // Where both hold, the step gets no relief. (Measured on the class: shading's chromaticity step is under a tenth
    // of its relative value step on most textures, up to a half on the cushion's red-to-purple ramps, so the hue test
    // alone cannot tell them apart; the sharpness does.)
    vec3 q0 = t0 / max(dot(t0, vec3(1.0)), 0.08);
    float dq = max(length(su / max(dot(su, vec3(1.0)), 0.08) - q0), length(sv / max(dot(sv, vec3(1.0)), 0.08) - q0));
    float dl = max(abs(lu - l0), abs(lv - l0)) / max(l0, 0.05);
    float sharp = length(c - (t0 + su + sv) / 3.0) / (length(su - t0) + length(sv - t0) + 0.02);
    float print = smoothstep(0.1, 0.2, dq / (dl + 0.03)) * smoothstep(0.12, 0.3, sharp);
    // Dense detail (a chain, rivets, a badge's rim): the texel far from its blurred surroundings.
    float busy = smoothstep(0.1, 0.25, abs(MatLum(c) - (l0 + lu + lv) / 3.0));
    float cloth = (1.0 - skin) * (1.0 - 0.85 * busy);
    // Relief 2.2 world units per unit of luminance (scaled), slopes capped at 0.25.
    vec3 fold = MatBumpUv(m, vec2(lu - l0, lv - l0) / e * (2.2 * m.scale));
    // Toward the shadow side a third of it: there tilts toward the sun add light and tilts away clamp at zero, which
    // would brighten the whole surface.
    // Glossy game materials (eyepatches, the bishop's mitre, gloss 20 to 40): the folds and threads would break their
    // tight highlight into crinkled streaks; there the folds are a third, the threads a seventh, the threads' crowns
    // leave the highlight alone, and the lobe broadens (below).
    float glossy = smoothstep(12.0, 36.0, materialMatrix[3].y);
    float calm = 1.0 - 0.7 * glossy;
    fold *= min(1.0, 0.25 / max(length(fold), 1e-5)) * (1.0 - skin) * (1.0 - print) * mix(0.3, 1.0, smoothstep(-0.1, 0.35, m.ndl));
    o.dn += fold * mix(1.0, 0.6, satin) * calm;

    // ---- threads: the weave map, 16 threads a tile, two octaves blended. Felt: the grain map as a nap of fibre
    // clumps (a tile 10 world units across, clumps about 0.12 apart), with a faint mottle in the paint.
    float F0, fb;
    MatOctave(m, felt > 0.5 ? 10.0 * m.scale : 16.0 * max(m.p.z, 0.02) * m.scale, F0, fb);
    float texels = felt > 0.5 ? 3.0 : 8.0;  // (fully in at 4 px a feature: 8 px a thread, 4 px a clump; gone at half)
    float kw = MatMapFade(m, F0 * (1.0 + fb), texels);
    float h = 0.0, v = 0.0;
    if (kw > 0.0) {
        float layer = felt > 0.5 ? MAT_MAP_GRAIN : MAT_MAP_WEAVE;
        vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.37, 0.61)), fb);
        s = MatMapNeutral(s, kw * cloth);
        o.dn += MatMapBump(m, s, (felt > 0.5 ? 0.7 : 0.5 - 0.2 * satin - 0.32 * felt) * (1.0 - 0.85 * glossy));
        h = MatMapHeight(s);
        v = MatMapVar(s);
        o.ao *= 1.0 + 0.8 * min(h, 0.0);
    }

    // ---- bands of thicker and thinner threads, four threads wide: they outlast the threads (in at 8 px a band).
    float kb = felt > 0.5 ? 0.0 : MatFadeUv(m, 2.0 * F0 * (1.0 + fb)) * cloth * (1.0 - felt);
    float band = 0.0;
    if (kb > 0.0) {
        vec2 bd = mix(mat_fabric_cloth_bands(m, F0), mat_fabric_cloth_bands(m, 2.0 * F0), fb);
        band = (bd.x + bd.y) * kb;
    }

    // ---- colour: per thread and per band, a few percent, the hue kept.
    o.albedo = MatVary(c, 0.05 * tint, 1.2 * v * (felt > 0.5 ? -0.7 : 1.0 - felt) + 1.2 * band);

    // ---- sheen: cloth scatters toward grazing angles (fibres standing off the surface); about mean-neutral.
    float graze = 1.0 - m.ndv;
    graze *= graze * graze;
    o.albedo *= 1.0 + cloth * mix(0.14, 0.32, felt) * (1.0 - 0.5 * satin) * (graze - 0.12);

    // ---- highlight: matte cloth broad and dim, felt dimmer, satin tighter and brighter; threads' crowns catch it.
    // Glossy materials: a soft, broad lobe (a third of the exponent) instead of the tight one; the lighting's
    // normalised lobe keeps its energy, but the tight hot spot clipped at white and the broad one does not: the
    // specular comes down by almost half to keep the surface's brightness.
    float sp = mix(mix(0.7, 0.65, felt), 1.35, satin) * (1.0 + (0.8 * h + 0.6 * band) * (1.0 - glossy)) * (1.0 - 0.45 * glossy);
    float gl = mix(mix(mix(0.6, 0.55, felt), 2.2, satin), 0.35, glossy) * (1.0 - 0.4 * band);
    o.spec = mix(1.0, sp, cloth);
    // The lighting takes the sun's diffuse down by half the specular (energy kept): a lower specular lifts the paint,
    // which on a glossy white (70cb8e) outweighs the dimmer lobe. Give back about a third of that on the glossy
    // materials (all of it overshoots: the paint scale also reaches the ambient); measured, they then stay within 4%
    // of Sunstone without detail.
    float sk = dot(materialMatrix[0].xyz, vec3(0.333)) * sunstoneSpecular * 0.5;
    o.albedo *= 1.0 + 0.3 * glossy * ((1.0 - min(sk, 0.5)) / (1.0 - min(sk * o.spec, 0.5)) - 1.0) * smoothstep(-0.1, 0.35, m.ndl);
    o.gloss = mix(1.0, gl, cloth);

    // ---- wear (uniform): faded, pilled patches, a little lighter and greyer, threads flattened, rougher.
    if (m.p.x > 0.0) {
        vec4 w = MatMapWorld(m, MAT_MAP_WEAR, 24.0 * m.scale, 4.0);
        float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * cloth;
        float l = MatLum(o.albedo);
        o.albedo = mix(o.albedo, mix(vec3(l), o.albedo, 0.8) * 1.06, 0.6 * worn);
        o.gloss *= 1.0 - 0.4 * worn;
        o.dn *= 1.0 - 0.5 * worn;
    }

    // ---- energy: a tilted sunlit normal loses 1 - 1/sqrt(1 + slope^2) of the sun whichever way it tilts, which
    // would darken the cloth as a whole; give that back in the paint where the sun reaches.
    o.albedo *= 1.0 + (sqrt(1.0 + dot(o.dn, o.dn)) - 1.0) * smoothstep(-0.1, 0.35, m.ndl);
    return o;
}
// -- fur_hair.glsl
// @class fur_hair
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.35 b=0
// @param scale: strand and lock size (1: strands about 0.1 world units apart, about 12 locks across the texture)
// @param wear: which parts of an animal atlas are not hair (they get no strands): 0 none; otherwise strong art edges
//   (eyes, outlines) and saturated reds, blues and greens, and by step: 1 also pink skin, near-black and near-white;
//   0.75 pink and near-white (black fur); 0.5 pink and near-black (white or cream fur); 0.25 near-black and all but
//   light, unsaturated texels (wool: a sheep's skin, mouth and cape are not hair)
// @param tint: albedo variation strand to strand and lock to lock (1 = about 4% either way)
// @param a: flow, how far the strands wander from direction b (0 straight, 0.35 combed, 1 wavy fur, 2 curls; above
//   1.2 the locks go soft so the art's own painted curls lead)
// @param b: strand direction in turns from the texture's +v (0 along v, 0.25 along u; other values lose the wrap)
// Hair, fur and feathers that the Worm hair path leaves alone: strands along a direction field (b, bent by a periodic
// warp of strength a), bundled in locks of uneven width. The light does the work: a fine fibre normal across the
// strands, locks that roll and shade their partings, and in place of the material's round Blinn highlight a
// strand-shaped one, two Kajiya-Kay bands across the strands (a tight one shifted toward the tip, a broad one toward
// the root), sparkling per strand up close. The colour moves only a few percent.

// Gradient noise with its own period per axis (the strands are stretched along one axis): (value, d/dp).
vec3 mat_fur_hair_noise(vec2 p, vec2 period) {
    vec2 i = floor(p), f = fract(p), e = vec2(1.0, 0.0);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec2 ga = MatHash22(mod(i, period)) * 2.0 - 1.0, gb = MatHash22(mod(i + e, period)) * 2.0 - 1.0;
    vec2 gc = MatHash22(mod(i + e.yx, period)) * 2.0 - 1.0, gd = MatHash22(mod(i + 1.0, period)) * 2.0 - 1.0;
    float va = dot(ga, f), vb = dot(gb, f - e), vc = dot(gc, f - e.yx), vd = dot(gd, f - 1.0), k = va - vb - vc + vd;
    return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va));
}

// One-dimensional gradient noise of period `period`: (value about -0.5..0.5, d/dp).
vec2 mat_fur_hair_noise1(float p, float period) {
    float i = floor(p), f = p - i;
    float g0 = MatHash12(vec2(mod(i, period), 17.0)) * 2.0 - 1.0, g1 = MatHash12(vec2(mod(i + 1.0, period), 17.0)) * 2.0 - 1.0;
    float u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float v0 = g0 * f, v1 = g1 * (f - 1.0);
    return vec2(v0 + u * (v1 - v0), g0 + u * (g1 - g0) + du * (v1 - v0));
}

// What of an animal's atlas is not hair (0 hair .. 1 not), keyed on the texel; wear picks the keys (see @param).
float mat_fur_hair_bare(MatIn m) {
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = max(mx - mn, 1e-4);
    float sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float hue = (mx == c.r ? mod((c.g - c.b) / d, 6.0) : (mx == c.g ? (c.b - c.r) / d + 2.0 : (c.r - c.g) / d + 4.0)) / 6.0;
    float w4 = floor(m.p.x * 4.0 + 0.5);
    float kP = w4 > 1.5 ? 1.0 : 0.0, kW = w4 > 2.5 ? 1.0 : 0.0, kB = abs(w4 - 3.0) > 0.5 ? 1.0 : 0.0;
    float kWool = w4 < 1.5 ? 1.0 : 0.0;
    // Pink skin, noses, inner ears (blue at most about 0.05 below green; cream fur, far less blue, stays hair).
    float pink = smoothstep(0.55, 0.75, mx) * smoothstep(0.12, 0.25, sat) * (1.0 - smoothstep(0.65, 0.8, sat))
               * smoothstep(0.0, 0.08, c.r - c.g) * smoothstep(-0.09, -0.03, c.b - c.g);
    // Saturated colours away from the hair hues (orange to yellow, about 0.1 turns): bombs, fuses, bands, red eyes.
    // (Reds, which no fur has, from a lower saturation: glowing eyes, combs, blood.)
    float red = 1.0 - smoothstep(0.02, 0.045, abs(fract(hue + 0.5) - 0.5));
    float paint = smoothstep(0.25, 0.4, mx) * max(smoothstep(0.7, 0.85, sat) * smoothstep(0.07, 0.11, abs(fract(hue - 0.6) - 0.5)),
                                                  smoothstep(0.4, 0.55, sat) * red);
    // Near-white and the cream of eyes and teeth.
    float white = smoothstep(0.8, 0.9, lum) * (1.0 - smoothstep(0.18, 0.26, sat));
    // Near-black, and dark greys and slates (pupils and irises), not dark browns.
    float dark = 1.0 - smoothstep(0.25, 0.33, lum), grey = 1.0 - smoothstep(0.35, 0.5, sat);
    float black = max(1.0 - smoothstep(0.08, 0.15, lum), dark * grey);
    float wool = smoothstep(0.72, 0.82, mx) * (1.0 - smoothstep(0.3, 0.4, sat));
    // The art's strong edges (pupils, outlines, teeth): the luminance step per texel of a 128-texel texture.
    float edge = smoothstep(0.08, 0.2, length(m.lumD) / max(m.uvPx * 128.0, 1e-6));
    return max(max(max(kP * pink, paint), max(kW * white, kB * black)), max(kWool * (1.0 - wool), edge));
}

MatOut mat_fur_hair(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    // The strand frame on the texture: dir along the strands, per across them (b in turns from +v).
    float ang = 6.2831853 * m.p.w;
    vec2 dir = vec2(sin(ang), cos(ang)), per = vec2(dir.y, -dir.x);
    // The flow: a periodic warp of the across coordinate c, 4 waves per texture unit (an art-sized feature, fixed to
    // the texture); its slope bends the strands, and strong it curls them.
    // Curls (a toward 2): tighter waves, and shorter strands and locks below.
    float curl = clamp(m.p.z * 0.5, 0.0, 1.0);
    float Fw = curl > 0.6 ? 8.0 : 4.0, A = m.p.z * 0.35;
    vec3 w = A > 0.0 ? mat_fur_hair_noise(m.uv * Fw, vec2(Fw)) : vec3(0.0);
    float c = dot(m.uv, per) + A * w.x / Fw, s = dot(m.uv, dir);
    vec2 gc = per + A * w.yz, gs = dir;               // d c / d uv, d s / d uv
    // The warp packs the strands closer where it bends them: the across frequency grows by |gc| (up to about 2.4 at
    // a = 2), so every footprint fade below takes that stretch.
    float stretch = max(length(gc), 1.0);
    float hairy = m.p.x > 0.0 ? 1.0 - mat_fur_hair_bare(m) : 1.0;

    // Locks: stretched gradient noise, about 12 across a texture unit and a quarter as many along. Fixed to the
    // texture: a lock is the art's feature (its painted clumps are that size). Their width varies (the across
    // coordinate warped by a 1D noise 4 waves a unit, widths 0.5 to 1.5 times), so the partings never run as even
    // meridians. Curls: the art paints its own curls, so the locks only soften them.
    float FL = max(floor(12.0 / m.scale + 0.5), 1.0), FLs = max(floor(FL / mix(4.0, 1.5, curl) + 0.5), 1.0);
    vec2 lw = mat_fur_hair_noise1(c * 4.0, 4.0);
    float lws = 1.0 + 0.33 * lw.y;                    // d(lock coordinate) / d(c FL)
    vec3 lk = mat_fur_hair_noise(vec2(FL * (c + 0.0825 * lw.x + 0.04 * w.x), s * FLs), vec2(FL, FLs));
    vec2 gl = lws * gc + (0.04 * Fw) * w.yz;          // d(lock coordinate) / d uv, over FL
    vec2 glk = lk.y * FL * gl + lk.z * FLs * gs;      // d lk / d uv
    // (Faded from six pixels a lock: the partings and the rolls are sharper than one noise cell.)
    float kL = MatFadeUv(m, 1.5 * FL * max(length(gl), 1.0)) * hairy * (curl > 0.6 ? 0.4 : 1.0);
    // Strands about 0.1 world units apart and eight times as long, irregular (stretched gradient noise), two octaves
    // blended so the size never jumps.
    float F1, fb1;
    MatOctave(m, 0.1 * m.scale, F1, fb1);
    float F1s = max(F1 * exp2(-floor(mix(3.0, 1.0, curl) + 0.5)), 1.0);
    vec3 s0 = mat_fur_hair_noise(vec2(c * F1, s * F1s), vec2(F1, F1s)) * vec3(1.0, F1, F1s);
    vec3 s1 = mat_fur_hair_noise(vec2(c * F1 * 2.0 + 0.5, s * F1s * 2.0 + 0.3), vec2(F1, F1s) * 2.0)
            * vec3(1.0, 2.0 * F1, 2.0 * F1s);
    vec3 st = mix(s0, s1, fb1);
    float kS = MatFadeUv(m, F1 * (1.0 + fb1) * stretch) * hairy;

    // The normal from the heights in world units (locks a soft roll 0.07 high, strands 0.02): their slopes per
    // texture unit along c and s, carried to u, v.
    vec2 dh = (0.07 * kL) * glk + (0.02 * kS) * (st.y * gc + st.z * gs);
    o.dn = MatBumpUv(m, dh * m.scale);

    // Cavity: partings between locks and the grooves between strands.
    o.ao = (1.0 - 0.06 * kL * smoothstep(-0.05, 0.4, -lk.x)) * (1.0 - 0.08 * kS * smoothstep(0.0, 0.35, -st.x));
    // Colour: a strand a little lighter or darker, a lock a little; the mean stays.
    o.albedo = MatVary(m.albedo, m.p.y, 0.08 * kS * st.x + 0.03 * kL * lk.x);

    // The highlight along the strands: the strand's tangent in eye space (perpendicular to grad c on the surface).
    vec3 gcE = gc.x * m.gu + gc.y * m.gv;
    vec3 T = cross(m.n, gcE);
    T = dot(T, T) > 1e-20 ? normalize(T) : m.tv;
    vec3 h = normalize(m.l + m.v);
    float sh = 0.08 * lk.x * kL;                      // the bands wander with the locks
    vec3 t1 = normalize(T + m.n * (0.12 + sh)), t2 = normalize(T - m.n * (0.22 - sh));
    float d1 = dot(t1, h), d2 = dot(t2, h);
    float e1 = mix(12.0, 36.0, kS);
    float b1 = pow(max(1.0 - d1 * d1, 0.0), e1) * sqrt(e1 / 36.0), b2 = pow(max(1.0 - d2 * d2, 0.0), 8.0);
    float glint = mix(1.0, clamp(1.0 + 2.2 * st.x, 0.2, 2.0), kS) * (1.0 + 0.5 * lk.x * kL);
    float band = (1.2 * b1 + 0.45 * b2) * glint;
    // Off the bands the round highlight goes; the bands carry it, broad in the Blinn lobe (gloss down). Dark hair:
    // the same highlight is a bigger share of what it reflects, so less gain keeps its mean.
    // (Without the strands' cavities, far away, a little less, so the mean stays at every distance.)
    float gain = mix(0.8, 2.0, smoothstep(0.08, 0.5, MatLum(m.albedo))) * mix(0.85, 1.0, kS);
    o.spec = mix(1.0, 0.3 + gain * band, hairy);
    // What is not hair keeps the material's own highlight.
    o.gloss = mix(1.0, 0.45, hairy);
    return o;
}
// -- glass_gem.glsl
// @class glass_gem
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0.1
// @param wear: (no wear on glass) the art mask of an atlas: 0 every texel is glass; 1 gold, brown and unsaturated
// texels (bezels, corks, labels) keep their own look
// @param tint: a gem's inner variation of colour (1 = 3% either way); smooth glass and eyes have none
// @param a: facets per texture unit (0 = smooth glass, eyes, lenses: only the wet highlight)
// @param b: facet tilt (radians): how far each facet bends the highlight
// Gems, glass, eyes and lenses. Smooth glass: a tighter, wet highlight where the surface faces the eye. Gems: irregular
// facets (a Voronoi of the texture, so they wrap with it) that each tilt the highlight their own way, edges blended over
// a pixel, and a few facets that catch it hard (glints). The specular scale stays the material's own (the lighting is
// energy-conserving: a higher gloss is a smaller, brighter highlight at the same mean), so nothing darkens or blows out.
MatOut mat_glass_gem(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    // The art mask (uniform when wear is 0): gold and brown (red over green and blue) and grey texels are not glass.
    float glass = 1.0;
    if (m.p.x > 0.0) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        float sat = (mx - mn) / max(mx, 0.02);
        float warm = smoothstep(0.02, 0.1, min(c.r - c.b, c.r - c.g + 0.15));
        glass = mix(1.0, (1.0 - warm) * smoothstep(0.15, 0.35, sat), m.p.x);
    }
    if (m.p.z <= 0.0) {
        // Smooth: a wet highlight, tight only where the surface faces the eye (no glare at the rim).
        o.gloss = 1.0 + 5.0 * glass * smoothstep(0.35, 0.75, m.ndv);
        return o;
    }
    o.gloss = 1.0 + 1.0 * glass;
    // Facets: the nearest and second-nearest of jittered points, a whole number of cells per texture unit (wraps).
    float Fc = max(floor(m.p.z + 0.5), 1.0);
    float k = MatFadeUv(m, Fc) * glass;
    if (k <= 0.0) return o;
    vec2 p = m.uv * Fc, ip = floor(p), fp = p - ip;
    float d1 = 9.0, d2 = 9.0;
    vec2 h1 = vec2(0.0), h2 = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 e = vec2(float(i), float(j));
            vec2 r = MatHash22(mod(ip + e, Fc) + 17.0 * m.seed);
            vec2 q = e + 0.15 + 0.7 * r - fp;
            float d = dot(q, q);
            if (d < d1) {
                d2 = d1; h2 = h1; d1 = d; h1 = r;
            } else if (d < d2) {
                d2 = d; h2 = r;
            }
        }
    }
    d1 = sqrt(d1);
    d2 = sqrt(d2);
    // Each facet's tilt (x, y in -1..1) and whether it is a glint facet (one in five): from its hash, re-mixed.
    vec2 t1 = fract(h1 * 37.17 + h1.yx * 11.31), t2 = fract(h2 * 37.17 + h2.yx * 11.31);
    // Across the edge between two facets (half the distance difference, in cells) the tilt blends over one pixel.
    float px = max(Fc * m.uvPx, 1e-4);
    float w = 0.5 + 0.5 * smoothstep(0.0, 1.0, 0.5 * (d2 - d1) / px);
    vec2 t = mix(t2, t1, w) * 2.0 - 1.0;
    o.dn = (t.x * m.tu + t.y * m.tv) * (m.p.w * k);
    // Glints: one facet in five is cut toward the light. It turns to the half vector, and much glossier, once the face
    // is within its own random angle of it (0 to about 45 degrees): a few facets spark on a face turned to the light,
    // more near the highlight, none on a face turned away; each switches on over a few degrees as the gem turns.
    vec3 hv = normalize(m.l + m.v);
    float ndh = dot(m.n, hv);
    float r1 = fract(h1.x * 53.7), r2 = fract(h2.x * 53.7);
    float g1 = step(0.8, r1) * smoothstep(0.7 + 1.5 * (r1 - 0.8), 0.74 + 1.5 * (r1 - 0.8), ndh);
    float g2 = step(0.8, r2) * smoothstep(0.7 + 1.5 * (r2 - 0.8), 0.74 + 1.5 * (r2 - 0.8), ndh);
    float g = k * mix(g2, g1, w) * smoothstep(0.0, 0.15, m.ndl);
    o.dn = mix(o.dn, hv - m.n * ndh, 0.9 * g);
    o.gloss *= 1.0 + 3.0 * g;
    // A faint inner variation of the colour, per facet (a gem's depth), 3% either way at tint 1.
    o.albedo = MatVary(c, 0.03 * m.p.y * k, mix(t2.x, t1.x, w) * 2.0 - 1.0);
    return o;
}
// -- gold_brass.glsl
// @class gold_brass
// @default scale=1 strength=1 rough=0 wear=0.4 tint=1 a=0.5 b=0.3
// @param wear: tarnish and patina in the darker, recessed gold (0 bright polish everywhere .. 1 old brass)
// @param tint: the reflection of sky and ground in the gold (1 = up to about 12% either way)
// @param a: hammering: soft dents breaking the highlight (0 smooth cast or plated .. 1 hand-beaten)
// @param b: anisotropy of a light brushing along u (0 none .. 1 long streaks)
// Gold, gilding, brass and bronze. The art paints gold as bright yellow with darker engraved or recessed detail; this
// polishes the bright gold (a tight, warm highlight broken by soft hammer dents, the sky reflected), and dulls the
// recesses with tarnish (rougher, a touch darker and greener, a little cavity). Atlas texels that are not gold keep a
// plain response: gems and enamel (saturated other hues) a glassy gloss, grey or white parts a light polish, cloth and
// near black unchanged.

// Gold weight: yellow to orange-brown with some saturation; and how bright it is within the gold family.
float mat_gold_brass_key(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    return smoothstep(0.22, 0.38, sat) * smoothstep(0.34, 0.46, gr) * (1.0 - smoothstep(1.02, 1.12, gr))
         * step(c.b, c.g) * smoothstep(0.08, 0.2, mx);
}

// One octave of the hammer dents at F cells per texture unit, (value, d/duv). The lattice offset depends only on F, so
// the octave at 2 * F0 (blended in as the density falls) is the same field as the next F0 octave: no seam where F0
// doubles.
vec3 mat_gold_brass_dent(MatIn m, float F) {
    vec2 off = vec2(m.seed * 29.0) + fract(F * vec2(0.6180340, 0.4142136)) * 23.0;
    return MatGNoise(m.uv * F + off, F) * vec3(1.0, F, F);
}
// A shared map sized in world units, the two octaves blended (MatOctave) at offsets that depend only on the frequency,
// faded to neutral by the footprint of features texels across.
vec4 mat_gold_brass_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 o0 = fract(F0 * vec2(0.7548777, 0.5698403)), o1 = fract(2.0 * F0 * vec2(0.7548777, 0.5698403));
    vec4 s = mix(MatMapAt(m, layer, F0, o0), MatMapAt(m, layer, 2.0 * F0, o1), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_gold_brass(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gold = mat_gold_brass_key(c);
    // Other texels: gems and enamel (saturated), grey or white trim (unsaturated), the rest left alone.
    float gem = (1.0 - gold) * smoothstep(0.5, 0.7, sat) * smoothstep(0.1, 0.25, mx);
    float grey = (1.0 - gold) * (1.0 - smoothstep(0.12, 0.25, sat)) * smoothstep(0.25, 0.45, mx);
    float rest = 1.0 - gold - gem - grey;
    // Tarnish in the recesses: the darker gold (the art draws engraving and hollows darker), from wear.
    float tarn = gold * (1.0 - smoothstep(0.28, 0.6, mx)) * clamp(m.p.x * 1.5, 0.0, 1.0);

    // Hammer dents: smooth gradient noise, cells about 2.5 world units, two octaves blended.
    float D0, db;
    MatOctave(m, 2.5 * m.scale, D0, db);
    vec3 g = mix(mat_gold_brass_dent(m, D0), mat_gold_brass_dent(m, 2.0 * D0), db);
    float gk = MatFadeUv(m, D0 * (1.0 + db));
    // Fine polishing marks and scratches along u, a tile about 10 world units.
    vec4 s = mat_gold_brass_map(m, MAT_MAP_BRUSHED, 10.0 * m.scale, 3.0);
    // Tarnish mottle: the stone layer's variation, a tile about 30 world units.
    vec4 t = mat_gold_brass_map(m, MAT_MAP_STONE, 30.0 * m.scale, 4.0);

    o.dn = gold * (MatBumpUv(m, g.yz * ((0.04 + 0.22 * clamp(m.p.z, 0.0, 1.5)) * m.scale * gk)) + MatMapBump(m, s, 0.25))
         + tarn * MatMapBump(m, t, 0.4);
    float polish = 1.0 - clamp(0.6 * max(MatMapVar(s), 0.0) + 0.5 * g.x * gk, 0.0, 0.5);
    o.gloss = gold * mix(2.6 * polish, 0.9, tarn) + gem * 2.4 + grey * 1.8 + rest;
    o.spec = gold * mix(1.05, 0.7, tarn) + gem * 1.1 + grey + rest;

    // Anisotropy of the brushing (Ashikhmin-Shirley's exponent): only the gloss changes, never the diffuse light.
    vec3 n2 = normalize(m.n + o.dn);
    vec3 h = normalize(m.l + m.v);
    float hu = dot(h, m.tu), hv = dot(h, m.tv);
    float r = 1.0 - 0.85 * gold * clamp(m.p.w, 0.0, 1.0);
    o.gloss *= (hu * hu + r * hv * hv + 1e-4) / (hu * hu + hv * hv + 1e-4);

    // Cavity in the tarnished recesses; tarnish a little darker and toward olive (the hue barely moves), mottled.
    o.ao = 1.0 - 0.2 * tarn * (0.6 + 2.0 * max(-MatMapVar(t), 0.0));
    vec3 tarnished = c * vec3(0.96, 0.98, 0.93) * (1.0 + 0.1 * MatMapVar(t));
    // The sky and ground in the polished gold (brighter facing the sky, a dark horizon line), more at grazing angles.
    float ry = dot(reflect(-m.v, n2), m.up);
    float env = (0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.2) * (0.7 + 0.6 * (1.0 - m.ndv));
    o.albedo = mix(c, tarnished, tarn) * (1.0 + 0.25 * m.p.y * (gold - tarn + 0.5 * grey) * env);
    return o;
}
// -- grass_turf.glsl
// @class grass_turf
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.5 b=1
// @param tint: albedo tonal variation (1 = about 1.5% either way)
// @param a: blade spacing in world units
// @param b: blade relief amount (1 normal)
// Grass and turf: a suggestion of blades (thin strands along the texture's v: stretched value noise, no map) with a
// soft clump relief (the bumps map, tile about 14 units). Mostly light: the cavity and the mottle are small and zero-mean
// where they can be, so pale grass keeps its value, and both step back on the art's own edges (m.lumD) so drawn
// outlines stay clean. The blades blend their two octaves and fade by their anisotropic footprint (a blade cell covers
// 8 pixels on both screen axes for full, 4 for none), so they never turn into pixel dashes at grazing.
// 2 map fetches + 2 stretched value noises (8 hashes).
float mat_grass_turf_vn(vec2 p, vec2 period, out vec2 d) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
    float a = MatHash12(mod(i, period)), b = MatHash12(mod(i + vec2(1.0, 0.0), period));
    float c = MatHash12(mod(i + vec2(0.0, 1.0), period)), e = MatHash12(mod(i + 1.0, period));
    float k = a - b - c + e;
    d = du * vec2((b - a) + k * u.y, (c - a) + k * u.x);
    return a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y;
}
// One octave of blades, fx cells per texture unit across, a quarter of that along: (height about 0, d/du, d/dv),
// already faded by the cell's footprint along both screen axes. One offset for every octave, so the pattern stays the
// same where MatOctave's floor() flips per pixel (a texel density on a power of two).
vec3 mat_grass_turf_blades(MatIn m, float fx) {
    vec2 f = vec2(fx, max(fx / 4.0, 1.0));
    float k = MatFadeCells(2.0 * max(length(m.uvDx * f), length(m.uvDy * f)));
    vec2 d;
    float h = mat_grass_turf_vn(m.uv * f + 5.0, f, d) - 0.5;
    return k * vec3(h, d * f);
}
// A layer about tileWorld units a tile, both octaves blended with one offset (MatMapWorld's two offsets make a pixel
// maze where the texel density sits on a power of two).
vec4 mat_grass_turf_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.0)), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}
MatOut mat_grass_turf(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // The art's own edges (drawn outlines, leaf shapes): detail steps back there.
    float keep = 1.0 - smoothstep(0.01, 0.05, length(m.lumD));
    float fx, fb;
    MatOctave(m, max(m.p.z, 0.05) * m.scale, fx, fb);   // blade spacing along u
    vec3 bl = mix(mat_grass_turf_blades(m, fx), mat_grass_turf_blades(m, 2.0 * fx), fb) * keep;
    float h = bl.x;
    o.dn = MatBumpUv(m, bl.yz * (0.06 * m.scale * m.p.w));
    vec4 c = mat_grass_turf_map(m, MAT_MAP_BUMPS, 14.0 * m.scale, 8.0);
    o.dn += MatMapBump(m, c, 0.3 * (0.5 + 0.5 * keep));
    o.ao = 1.0 + (0.08 * min(h, 0.0) + 0.06 * min(MatMapHeight(c), 0.0)) * keep;
    o.albedo = MatVary(m.albedo, 0.015 * m.p.y * keep, h * 2.0 + MatMapVar(c));
    o.spec = 0.95 + 0.5 * max(h, 0.0);
    o.gloss = 0.6;
    return o;
}
// -- leaf_foliage.glsl
// @class leaf_foliage
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=3 b=0
// @param scale: size of the fine vein net (areoles, the cushions between the smallest veins): 1 = cushions about 0.6 world units (map tile 18)
// @param tint: albedo variation (1 = 3% either way)
// @param a: undulation of the blade, waves per texture unit (a whole number): sized to the drawn leaf, not the world
// @param b: translucency bias (-1 none, 0 the default, 1 double)
// Leaves, grass blades, petals, cacti and the odd flower or mushroom atlas. Keyed on the texel: greens (the leaves) get
// the full treatment, other colours (petals, fruit, mushroom caps, a strip of wood) a satin one.
// - The art's own drawn lines are raised in the light: a height from the texel's luminance, its slope taken by central
//   differences of four bilinear taps of the art (texture0) a texel (or a pixel's footprint) apart, so the slope is
//   continuous across texels (no stair-steps on magnified 32..128 px art) and fades once texels go below a pixel and
//   at alpha-cut outlines. Petals and caps get it about twice as deep: soft raised petals, gills and spots.
// - A faint fine vein net (normal only, from the organic map) and a slow undulation of the blade.
// - A waxy cuticle on the leaves (a tighter, slightly stronger highlight), a broad satin sheen on petals and caps.
// - Light through the leaf when the sun is behind it and the eye looks toward it: a modest brightening (at most +12%)
//   by a scalar, so hue and saturation stay exactly and Sunstone's leaf hue shift (applied after) finds the same greens.
// The undulation, the mottle, the extra gloss and the emboss go with the world footprint (gone by 0.45 world units a
// pixel, where a texture repeats many times on screen), so broad flat colour stays flat from afar.
// No derivatives (the bumps are built from m.uv's own frame), so the early return is safe.
// Cost: one gradient noise, two textureGrad of the shared maps (MatMapWorld), four textureGrad of the art, no loops.

MatOut mat_leaf_foliage(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), ch = mx - min(c.r, min(c.g, c.b));
    float S = ch / max(mx, 1e-3);
    // Hue in degrees (0..360), as the host's Hue().
    float H = 0.0;
    if (ch >= 1e-4) {
        float h = mx == c.r ? (c.g - c.b) / ch : (mx == c.g ? 2.0 + (c.b - c.r) / ch : 4.0 + (c.r - c.g) / ch);
        H = fract(h / 6.0) * 360.0;
    }
    // 1 a leaf green (yellow-green to blue-green, some saturation, not black); 0 a petal, fruit, cap or wood.
    float leaf = smoothstep(0.14, 0.3, S) * smoothstep(52.0, 78.0, H) * (1.0 - smoothstep(172.0, 195.0, H))
               * smoothstep(0.05, 0.14, mx);
    float amt = mix(0.35, 1.0, leaf);
    float ipw = 1.0 / max(m.uvPerWorld, 1e-6);   // world units per texture unit
    // 1 up close .. 0 from 0.45 world units a pixel (a worm's head under 30 px): what would repeat per tile goes.
    float kNear = 1.0 - smoothstep(0.2, 0.45, m.pxWorld);

    // ---- the blade's undulation: one gradient noise, a waves per texture unit (wrapping with the texture).
    float F = max(floor(m.p.z + 0.5), 1.0);
    vec3 nz = MatGNoise(m.uv * F + floor(m.seed * vec2(61.0, 37.0)), F);
    float kW = MatFadeUv(m, 4.0 * F) * kNear;
    o.dn = MatBumpUv(m, nz.yz * (0.12 * amt * kW * ipw));

    // ---- the art's drawn lines, raised: height = luminance x 6% of the texture's size on the object (lighter lines
    // up). Central differences of four bilinear taps d apart (a texel, or the pixel's footprint when minified) give a
    // slope that is continuous across texels. Faded from one to three texels a pixel (it would alias), from afar and
    // at alpha-cut outlines; the slope is limited softly (0.15 on leaves, 0.32 on petals and caps, whose raised
    // drawn shapes are their gain), so a hard drawn edge or a seam stays a soft bevel.
    vec2 ts = vec2(textureSize(texture0, 0));
    float texPx = m.uvPx * max(ts.x, ts.y);                       // texels one pixel covers
    float kEmb = (1.0 - smoothstep(1.0, 3.0, texPx)) * mix(0.25, 1.0, kNear);
    vec2 d = max(1.0 / ts, vec2(m.uvPx));
    vec4 tu0 = textureGrad(texture0, m.uv - vec2(d.x, 0.0), m.uvDx, m.uvDy);
    vec4 tu1 = textureGrad(texture0, m.uv + vec2(d.x, 0.0), m.uvDx, m.uvDy);
    vec4 tv0 = textureGrad(texture0, m.uv - vec2(0.0, d.y), m.uvDx, m.uvDy);
    vec4 tv1 = textureGrad(texture0, m.uv + vec2(0.0, d.y), m.uvDx, m.uvDy);
    vec2 dL = vec2(MatLum(tu1.rgb) - MatLum(tu0.rgb), MatLum(tv1.rgb) - MatLum(tv0.rgb)) / (2.0 * d);
    // Not across an alpha-cut outline (the cut-away texels are black: their edge is no drawn line).
    kEmb *= smoothstep(0.35, 0.9, min(min(tu0.a, tu1.a), min(tv0.a, tv1.a)));
    vec3 emb = MatBumpUv(m, dL * (mix(0.14, 0.06, leaf) * kEmb * ipw));
    o.dn += emb / (1.0 + length(emb) / mix(0.32, 0.15, leaf));

    // ---- fine vein net: the organic map's cells as a faint normal only (no cavity, no paint), so no crease lines.
    vec4 s = MatMapWorld(m, MAT_MAP_BUMPS, 12.0 * m.scale, 8.0);
    o.dn += MatMapBump(m, s, mix(0.03, 0.08, leaf));

    // ---- the cuticle: leaves waxy (tighter, a little stronger highlight), petals and caps a broad satin sheen. The
    // extra gloss goes with the world footprint (a whole leaf a speck: no glints, no per-tile sheen from afar).
    float wax = leaf * kNear;
    float satin = (1.0 - leaf) * kNear;
    o.gloss = mix(1.0, 2.2, wax) * mix(1.0, 0.7, satin);
    o.spec = mix(1.0, 1.2, wax) * mix(1.0, 1.6, satin);
    // Satin: a soft lift toward grazing, as a petal's fine hairs and cells scatter (a few percent, the hue kept).
    float graze = 1.0 - m.ndv;
    float sheen = satin * graze * graze * clamp(m.ndl * 0.5 + 0.5, 0.0, 1.0);

    // ---- colour: a faint mottle (hue kept), gone from afar.
    vec3 a = MatVary(c, 0.03 * m.p.y * kW, 2.0 * nz.x);

    // ---- light through the leaf: the sun behind it (n.l < 0) and the eye looking toward the sun, dark texels hardly.
    // A scalar gain (H, S and the leaf hue shift unchanged), at most +12%.
    float back = sqrt(clamp(-m.ndl, 0.0, 1.0));
    float fwd = clamp(-dot(m.v, m.l), 0.0, 1.0);
    float T = clamp(clamp(1.0 + m.p.w, 0.0, 2.0) * 0.5 * mix(0.5, 1.0, leaf) * smoothstep(0.08, 0.35, mx)
                    * back * (0.15 + 0.85 * fwd * fwd), 0.0, 1.0);
    o.albedo = a * (1.0 + 0.12 * T + 0.08 * sheen);
    return o;
}
// -- leather.glsl
// @class leather
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=1 b=0
// @param wear: scuffing (0 new .. 1 well worn): scuffs go matte and a touch lighter
// @param tint: albedo variation (1 = about 3% either way, from the pebble grain)
// @param a: pebble grain and crease depth (1 = the default; 0 = smooth)
// @param b: polish (0 = satin, the default; 1 = polished boot leather; -1 = suede-dull)
// Gloves, boots, straps, bags, caps: a pebbled grain whose cell tops are a little smoother than the creases between
// them, the art's own painted creases and seams turned into a slight relief, and scuffs that dull the satin sheen.
// The art's colours stay; from afar the grain fades to the plain satin surface.
// Cost: 3 texture fetches (MatMapWorld = 2, one MatMapAt), no noise calls, no loops.
MatOut mat_leather(MatIn m) {
    MatOut o = MatNone(m.albedo);
    // The art's creases and stitch lines as relief (derivatives, so before the early out): 0.06 world units of height
    // per unit of luminance, the slope capped at about 0.2 so hard decal edges do not turn into ridges.
    vec2 e = m.lumD * (0.06 * m.p.z * m.scale);
    float el = length(e);
    e *= min(1.0, 0.2 * m.pxWorld / max(el, 1e-6));
    vec3 crease = MatBumpScreen(m, e);
    if (m.fade <= 0.0) return o;
    // Bright trim (gold, lenses, white cuffs) and near-black gaps take less of the leather.
    float lum = MatLum(m.albedo);
    float hide = smoothstep(0.02, 0.08, lum) * (1.0 - 0.6 * smoothstep(0.75, 0.95, lum));
    // Pebble grain: a tile about 7 world units (cells about 0.2 across on a 12-unit worm head).
    vec4 g = MatMapWorld(m, MAT_MAP_BUMPS, 7.0 * m.scale, 8.0);
    float h = MatMapHeight(g), rv = MatMapVar(g) * 2.0;
    o.dn = crease + MatMapBump(m, g, 0.18 * m.p.z) * hide;
    // Scuffs: one fetch of the wear map, about 20 world units a tile.
    float F0, fb;
    MatOctave(m, 20.0 * m.scale, F0, fb);
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, F0, vec2(0.43, 0.17));
    float kw = MatMapFade(m, F0, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * kw * hide;
    // Light: satin (a little rougher and dimmer than the game's default), smoother on the cell tops, rougher in the
    // creases, matte where scuffed; polish (b) sharpens it.
    float pol = exp2(1.2 * m.p.w);
    o.gloss = mix(1.0, 0.85 * pol * (1.0 - 0.3 * rv) * mix(1.0, 0.7, worn), hide);
    o.spec = mix(1.0, (0.95 + 0.15 * m.p.w) * (1.0 - 0.15 * rv) * mix(1.0, 0.8, worn), hide);
    // Cavity in the grain's creases.
    o.ao = 1.0 - 0.4 * max(-h, 0.0) * m.p.z * hide;
    // Colour: the grain's own mottle, scuffs a hair lighter.
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * hide, -rv) + (vec3(1.0) - m.albedo) * 0.035 * worn;
    return o;
}
// -- other.glsl
// @class other
// @default scale=1 strength=0.8 rough=0 wear=0 tint=0.5 a=0.4 b=0.4
// @param tint: albedo mottle (1 = a few percent)
// @param a: sheen / wetness (0 dry .. 1 glazed or wet); above about 0.6 white and grey texels get a glaze as well
// @param b: surface relief (0 smooth .. 1 lumpy); up to 0.6 a fine calm grain, above it organic lumps
// The leftovers: foods, mushrooms, fruit, ceramics, odd props. Smooth things (cheese, bread, glaze, eggs, fruit: b up
// to 0.6) get a calm fine grain and mottle (the GRAIN map at a 12-unit tile, low relief), lumpy things (b above 0.6,
// e.g. the dog turds) the pebbled BUMPS map; the choice is per texture (uniform), one map either way. The texel decides
// the light: saturated colour is the body (a sheen scaled by `a`), dark stays glossy, and with a high `a` near-white
// and grey texels get a hard glaze too (porcelain, lacquer, egg white). The art's own edges (seams, seeds, sprinkles,
// rind lines) become a faint relief.
MatOut mat_other(MatIn m) {
    MatOut o = MatNone(m.albedo);
    vec3 e = MatBumpScreen(m, m.lumD * (0.2 * m.scale));
    e *= min(1.0, 0.28 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float body = smoothstep(0.06, 0.3, sat) * smoothstep(0.05, 0.15, lum);
    float dark = 1.0 - smoothstep(0.04, 0.16, lum);
    float glaze = smoothstep(0.55, 0.85, m.p.z) * smoothstep(0.45, 0.7, lum) * (1.0 - body);
    bool lumpy = m.p.w > 0.6;   // per texture: the same for every fragment of a draw
    vec4 g = lumpy ? MatMapWorld(m, MAT_MAP_BUMPS, 18.0 * m.scale, 8.0) : MatMapWorld(m, MAT_MAP_GRAIN, 12.0 * m.scale, 3.0);
    float h = MatMapHeight(g), var = MatMapVar(g);
    float k = mix(0.5, 1.0, body);
    float relief = lumpy ? 0.45 : 0.3;
    o.dn = (MatMapBump(m, g, relief * m.p.w) + e * (1.4 * m.p.w)) * k;
    o.ao = 1.0 + (lumpy ? 0.5 : 0.25) * m.p.w * min(h, 0.0);
    o.albedo = MatVary(c, 0.04 * m.p.y * body, 2.0 * h);
    o.spec = 1.0 + m.p.z * (0.85 * body + 1.0 * dark) + 1.6 * glaze - 0.3 * var * m.p.z;
    o.gloss = 1.0 + m.p.z * (1.5 * body + 2.0 * dark) + 3.0 * glaze - 2.0 * var * m.p.z * (body + 0.5 * glaze);
    return o;
}
// -- painted_metal.glsl
// @class painted_metal
// @default scale=1 strength=1 rough=0 wear=0.35 tint=1 a=0.5 b=7
// @param wear: chipping, scratches and rust (0 fresh paint, 0.35 used, 0.6 battered and rusting)
// @param tint: grime and paint mottle (1 = a few percent)
// @param a: paint gloss (0 flat primer .. 0.5 satin .. 1 glossy enamel)
// @param b: log2 of the texture's size in texels, 5..9 (sizes the relief taken from the art's own edges, close up)
// Painted sheet steel. From afar: a satin coat whose highlight ripples over the sheet's shallow dents and is dulled
// in soft grime blotches, worn patches showing as a cooler, sharper sheen. Close up: the art's seams and rivets pressed into the light, and wear from the shared
// wear map, gathered in patches: scuffed paint, scratches through the coat, chips showing bright steel, rust when
// battered. Two maps at two octaves each (four fetches) and two gradient noises.

// The art's luminance gradient per texel (lumD is per pixel): J^-T lumD over the texture's size.
vec2 mat_painted_metal_artSlope(MatIn m, float texels) {
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    det = abs(det) > 1e-14 ? det : 1e-14;
    vec2 g = vec2(m.uvDy.y * m.lumD.x - m.uvDx.y * m.lumD.y, m.uvDx.x * m.lumD.y - m.uvDy.x * m.lumD.x) / det;
    return g / texels;
}

// A shared map a tile about tileWorld across, as MatMapWorld but shifted by this texture's seed (both octaves by
// their own offsets), so every painted texture gets its own chips and scratches. kf: the footprint fade.
vec4 mat_painted_metal_map(MatIn m, float layer, float tileWorld, float texels, vec2 off, out float kf) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, fract(m.seed * vec2(0.37, 0.71) + off)),
                 MatMapAt(m, layer, 2.0 * F0, fract(m.seed * vec2(0.83, 0.29) + off + vec2(0.37, 0.61))), fb);
    kf = MatMapFade(m, F0 * (1.0 + fb), texels);
    return MatMapNeutral(s, kf);
}

MatOut mat_painted_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    // Atlases: near-black, greyish texels (tyres, holes, slots, shadows painted in) are not paint: no wear on them
    // and only half the sheen. Saturated darks (deep red, navy paint) stay paint.
    float mx = max(m.albedo.r, max(m.albedo.g, m.albedo.b));
    float sat = (mx - min(m.albedo.r, min(m.albedo.g, m.albedo.b))) / max(mx, 1e-3);
    // (A saturated dark, a deep blue-green bore or a navy hole, is paint only above about a tenth of value: chipped steel
    // would show as bright specks in it.)
    float paint = max(smoothstep(0.07, 0.2, lum), smoothstep(0.3, 0.55, sat) * smoothstep(0.08, 0.16, lum));
    float wear = clamp(m.p.x, 0.0, 1.0) * paint;

    // The sheet: a subtle ripple of shallow dents about 5 world units apart (two octaves blended so the size never jumps), 0.05 deep: any more splits a highlight on a helmet into two hot spots.
    // Their value also says where wear and grime gather.
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    vec2 sd = m.seed * vec2(37.0, 71.0);
    vec3 d = mix(MatGNoise(m.uv * F0 + sd, F0) * vec3(1.0, F0, F0),
                 MatGNoise(m.uv * (2.0 * F0) + sd + 5.3, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    float kd = MatFadeUv(m, F0 * (1.0 + fb));
    float clus = clamp(0.5 + 1.6 * d.x * kd, 0.0, 1.0);

    // The shared maps in world units: the wear map (chips, scratches, scuffs) a tile about 40 units across (chips
    // under a unit, shown only while one covers about six pixels), the brushed map about 16 (fine scratches at all
    // angles, and the steel's brushing inside the chips).
    // Each sampled at this texture's own offset (seeded), so no two painted textures share a chip or a scratch.
    float kw, ks;
    vec4 w = mat_painted_metal_map(m, MAT_MAP_WEAR, 40.0 * m.scale, 3.0, vec2(0.0), kw);
    vec4 s = mat_painted_metal_map(m, MAT_MAP_BRUSHED, 16.0 * m.scale, 3.0, vec2(0.53, 0.19), ks);

    // The art's own edges (seams, rivets, panel borders), per texel; only while a texel covers two pixels or more.
    float texels = exp2(clamp(m.p.w, 3.0, 11.0));
    vec2 art = mat_painted_metal_artSlope(m, texels) * MatFadeCells(m.uvPx * texels);
    art *= min(1.0, 1.0 / max(length(art), 1e-6));   // a degenerate mapping (collinear uvDx, uvDy): no wild bump
    float edge = smoothstep(0.03, 0.15, length(art));

    // Grime: a soft blotch field (the dent patches, and the wear map's quiet ground close up), more on faces turned
    // down, away from the sky.
    float mot = clamp((w.a - 0.36) * 8.0, -1.0, 1.0) * (1.0 - smoothstep(0.46, 0.5, w.a));
    float grime = clamp(0.5 - 0.25 * mot - 0.9 * d.x * kd, 0.0, 1.0) * (0.55 + 0.45 * (1.0 - m.sky)) * m.p.y;

    // Wear: worn where the order passes 1 - wear, in patches, more of it on the art's edges. Capped below the map's
    // neutral 0.5 so a faded (far) sample never reads as worn.
    float thr = max(1.0 - wear * (0.4 + 1.0 * clus) * (1.0 + 0.8 * edge), 0.53);
    float worn = smoothstep(thr, thr + 0.03, w.a);
    float hw = MatMapHeight(w);                        // < 0 in chips and scratches
    float chip = worn * (1.0 - smoothstep(-0.2, -0.06, hw));   // through the coat: steel
    float scuff = worn - chip;                         // scuffed, dulled paint
    float reach = smoothstep(thr - 0.05, thr + 0.02, w.a);  // the features' relief, a little past them
    // From afar the chips are below a pixel and the map fades to neutral: put their share of the surface back as a
    // tone (the wear map's order passes thr on about 0.55 * (0.96 - thr) of it, about two thirds of that chipped).
    float wornFar = (1.0 - kw) * 0.55 * max(0.96 - thr, 0.0);
    float chipFar = 0.65 * wornFar;
    scuff += 0.35 * wornFar;
    // Fine scratches in the coat (the brushed map's grooves), as many as the wear.
    float scr = (1.0 - smoothstep(0.2, 0.36, s.z)) * smoothstep(0.05, 0.5, wear * (0.4 + clus)) * (1.0 - chip);

    // Paint: satin to gloss, the sheen broken in soft blotches (rougher where grimy), dulled where scuffed;
    // scratches catch the light in thin broad glints.
    float gloss = mix(1.0, 2.0, m.p.z) * exp2(-0.8 * d.x * kd - 0.3 * mot - 1.1 * grime - 1.0 * scuff - 1.2 * scr);
    o.spec = mix(1.05, 1.3, m.p.z) * (1.0 - 0.3 * grime) * (1.0 + 0.8 * scr);
    gloss = mix(1.0, gloss, 0.5 + 0.5 * paint);

    // Bare steel in the chips: greyer and cooler than the paint, with small hard highlights; rusting when battered.
    float rust = smoothstep(0.4, 0.8, wear) * (0.5 + 0.5 * clus);
    // (The steel keeps about the paint's value, pulled a little toward a mid grey: the metal is in the specular.)
    vec3 steel = vec3(mix(lum, 0.45, 0.35)) * vec3(0.95, 0.98, 1.03);
    vec3 rustc = vec3(0.46, 0.25, 0.12) * (0.6 + 0.8 * lum);
    o.albedo = mix(m.albedo, mix(steel, rustc, rust), 0.7 * chip + 0.5 * chipFar);
    o.albedo = mix(o.albedo, m.albedo * vec3(1.05, 0.9, 0.78), 0.3 * rust * reach * (1.0 - chip));
    o.albedo *= 1.0 - 0.06 * (grime - 0.4) - 0.03 * scuff + 0.06 * scr;
    o.gloss = mix(gloss, 8.0 * (1.0 - 0.8 * rust), chip + 0.3 * chipFar);
    o.spec = mix(o.spec, 2.2 * (1.0 - 0.7 * rust), chip + chipFar);

    // Light: the dents, the chips' and scratches' relief, the steel's brushing in the chips, and the art's seams
    // pressed in (dark lower, light higher) a third of a texel deep. Cavity only at the chips' walls.
    o.dn = MatBumpUv(m, d.yz * (0.05 * m.scale * kd))
         + MatMapBump(m, w, 1.0) * reach
         + MatMapBump(m, s, 0.8 * chip + 0.3 * scr)
         + MatBumpUv(m, art * (0.35 / m.uvPerWorld));
    o.ao = 1.0 - 0.12 * chip;
    return o;
}
// -- paper_card.glsl
// @class paper_card
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1 b=0
// @param a: tooth and cockle amount (0.5 smooth coated, 1 paper, 1.6 cardboard)
// @param b: coating (0 matt, 1 glossy coated card / wrapping)
// @param wear: unused
// Paper and card: a fine isotropic tooth (soft grain, slight cavity in its pits) up close; from afar the light: a
// broad, faint cockle that breaks up the highlight, a matt sheen (dull and wide; coated card a satin one) and the soft
// whitening paper shows toward grazing angles. Blue-dominant texels (a metal clip or plastic part in a paper atlas)
// get none of it: paper and card art is warm or neutral.
// Cost: 4 textureGrad (two world-tiled pairs: tooth, cockle), no noise.
MatOut mat_paper_card(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, coat = clamp(m.p.w, 0.0, 1.0);
    float paper = 1.0 - smoothstep(0.0, 0.06, m.albedo.b - max(m.albedo.r, m.albedo.g));
    // tooth: fine grain, ~2.5 world unit tile of 3-texel features (no direction, no long strokes)
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 2.5 * m.scale, 3.0);
    // cockle: the stone layer's soft relief on a large tile, only as a gentle normal (a sheet is never quite flat)
    vec4 k = MatMapWorld(m, MAT_MAP_STONE, 18.0 * m.scale, 4.0);
    o.dn = (MatMapBump(m, g, 0.5 * amt * (1.0 - 0.5 * coat)) + MatMapBump(m, k, 0.22 * amt)) * paper;
    o.ao = 1.0 + 0.8 * min(MatMapHeight(g), 0.0) * amt * (1.0 - 0.5 * coat) * paper;
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * paper, MatMapVar(g) + 0.5 * MatMapVar(k));
    // grazing whitening of a matt sheet (a coated one keeps it in the highlight)
    float rim = 1.0 - m.ndv;
    rim *= rim * rim;
    o.albedo *= 1.0 + 0.10 * (1.0 - 0.6 * coat) * rim * paper;
    // matt: a dull, wide sheen, slightly rougher in the tooth's pits; coated: satin
    float gl = mix(0.45, 1.4, coat) * (1.0 + 0.3 * MatMapVar(g));
    float sp = mix(0.45, 1.3, coat);
    o.gloss = mix(1.0, gl, paper);
    o.spec = mix(1.0, sp, paper);
    return o;
}
// -- plastic.glsl
// @class plastic
// @default scale=1 strength=1 rough=0 wear=0.15 tint=1 a=1 b=1
// @param wear: how scuffed the shell is (0 factory fresh .. 1 well used); scuffs change only the sheen
// @param tint: albedo variation (1 = about 1.5% either way)
// @param a: moulding micro-texture amount (1 = the default; 0 = a smooth shell: lenses, film, card)
// @param b: clear-coat gloss multiplier (1 = a little glossier than the game's; 0.5 = satin)
// Moulded toys, shells, casings: a fine orange-peel micro-texture of the moulding and soft scuffs that dull the gloss
// (a hair lighter, never dented or darkened). Clean and glossy-ish: the colours stay, the sheen gets a little sharper
// and breaks up a little. No bevel from the art's edges: the bilinear texel luminance shows its grid when magnified,
// halos light shapes, and there is no window where it is both smooth and free of shimmer.
// Cost: 3 texture fetches, no noise calls, no derivatives of its own.
MatOut mat_plastic(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Nearly black texels (lenses, trim, gaps) take less of the paint-like detail.
    float paint = smoothstep(0.03, 0.12, MatLum(m.albedo));
    // The moulding micro-texture: grain tile about 5 world units (a worm's head is 12).
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0);
    o.dn = MatMapBump(m, g, 0.15 * m.p.z) * paint;
    // Scuffs: the wear map about 16 world units a tile, two octaves blended (no size jump at UV-island seams) and
    // faded to neutral by the footprint; the wear order past 1 - wear is scuffed. Sheen only: no bump, no cavity.
    vec4 w = MatMapWorld(m, MAT_MAP_WEAR, 16.0 * m.scale, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.16, w.a) * paint;
    // Light: a clear coat a little sharper than the game's, rougher where scuffed and by the grain's own variation.
    float rg = MatMapVar(g) * 2.0 * m.p.z;   // a = 0 (lenses): an unbroken sheen
    o.gloss = mix(1.0, (1.0 + 0.35 * m.p.w) * mix(1.0, 0.65, worn) * (1.0 - 0.2 * rg), paint);
    o.spec = mix(1.0, (1.05 + 0.1 * m.p.w) * mix(1.0, 0.75, worn) * (1.0 + 0.2 * rg), paint);
    // A faint mottle and a hair (1%) of lightening where scuffed.
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * paint, rg) + (vec3(1.0) - m.albedo) * 0.01 * worn;
    return o;
}
// -- rope_straw.glsl
// @class rope_straw
// @default scale=1 strength=1 rough=0 wear=1 tint=1 a=1 b=0
// @param a: relief amount (1 default; 1.5 coarse straw)
// @param b: thread tile in world units, 0 = 4
// @param wear: weave (1 the plain-weave map: rope, woven fabric; 0 fibres only, for art that paints its own weave,
//   coils or twigs, so no map pattern is laid over the art's)
// Rope, wicker, straw: the plain-weave map gives twisted fibres and ply gaps as a normal and a cavity (gaps dark,
// crowns light), a few percent thread-to-thread albedo variation, a dull rough sheen. With the weave off, only the fine
// fibres and the sheen.
// Cost: 4 textureGrad (two world-tiled pairs) with the weave, 2 without; no noise.
MatOut mat_rope_straw(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, tile = (m.p.w > 0.0 ? m.p.w : 4.0) * m.scale, weave = clamp(m.p.x, 0.0, 1.0);
    // fibres: the brushed layer on a small tile (its scratches stay short, under a world unit), along u
    vec4 f = MatMapWorld(m, MAT_MAP_BRUSHED, tile * 0.75, 3.0);
    o.dn = MatMapBump(m, f, 0.3 * amt);
    o.albedo = MatVary(m.albedo, 0.07 * m.p.y, 0.6 * MatMapVar(f));
    o.gloss = 0.7;
    o.spec = 0.8 + 0.8 * MatMapVar(f);
    if (weave > 0.0) {
        vec4 w = MatMapWorld(m, MAT_MAP_WEAVE, tile, 16.0);
        float h = MatMapHeight(w);
        o.dn += MatMapBump(m, w, 1.1 * amt * weave);
        o.ao = 1.0 + 1.1 * min(h, 0.0) * amt * weave;
        o.albedo = MatVary(o.albedo, 0.07 * m.p.y * weave, 1.8 * MatMapVar(w));
        o.albedo *= 1.0 + 0.08 * weave * clamp(h, -0.3, 0.3);
        o.spec += 0.6 * weave * max(h, 0.0);
    }
    return o;
}
// -- rubber.glsl
// @class rubber
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=1 b=0.3
// @param wear: dusty bloom at worn spots (0 none .. 1 a lot): matte and slightly lighter
// @param tint: albedo variation (1 = about 2% either way)
// @param a: relief: the fine moulded grain and the art's wrinkles (1 = the default; 0 = flat)
// @param b: finish (0 = matte rubber, broad dim highlight; 1 = glossy latex or oilskin, tight bright highlight)
// Gloves, seals, soles, hoses: a soft surface whose painted wrinkles become gentle folds that roll the highlight, a
// fine grain (matte) or almost none (latex), and a broad specular that never turns metallic. Colours stay as painted.
// Cost: 3 texture fetches (MatMapWorld = 2, one MatMapAt), no noise calls, no loops.
MatOut mat_rubber(MatIn m) {
    MatOut o = MatNone(m.albedo);
    float fin = clamp(m.p.w, 0.0, 1.0);
    // The art's wrinkles as soft folds (derivatives, so before the early out): 0.05 world units of height per unit of
    // luminance, slope capped at about 0.15 (low-res glove art: its texel steps must not show).
    vec2 e = m.lumD * (0.05 * m.p.z * m.scale);
    float el = length(e);
    e *= min(1.0, 0.15 * m.pxWorld / max(el, 1e-6));
    vec3 fold = MatBumpScreen(m, e);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    float body = smoothstep(0.01, 0.06, lum);
    // Fine moulded grain, a tile about 4 world units; latex is almost smooth.
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 4.0 * m.scale, 3.0);
    float rv = MatMapVar(g) * 2.0;
    o.dn = fold + MatMapBump(m, g, 0.18 * m.p.z * (1.0 - 0.7 * fin)) * body;
    // Worn bloom: one fetch of the wear map, about 16 world units a tile, scuffs only (no chips in rubber).
    float F0, fb;
    MatOctave(m, 16.0 * m.scale, F0, fb);
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, F0, vec2(0.71, 0.29));
    float kw = MatMapFade(m, F0, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.1, w.a) * kw * body;
    // Light: matte rubber spreads and dims the highlight, latex tightens and brightens it; the grain breaks it a little.
    float gl = mix(0.45, 1.6, fin) * (1.0 - 0.25 * rv * (1.0 - fin));
    float sp = mix(0.6, 1.3, fin);
    o.gloss = mix(1.0, gl * mix(1.0, 0.6, worn), body);
    o.spec = mix(1.0, sp * mix(1.0, 0.75, worn), body);
    o.ao = 1.0 - 0.3 * max(-MatMapHeight(g), 0.0) * m.p.z * body;
    o.albedo = MatVary(m.albedo, 0.02 * m.p.y * body, rv) + (vec3(1.0) - m.albedo) * 0.03 * worn;
    return o;
}
// -- rusted_metal.glsl
// @class rusted_metal
// @default scale=1 strength=1 rough=0 wear=0.5 tint=1 a=1.5 b=0.6
// @param wear: scratches and chips on the steel and paint (0 none .. 1 battered)
// @param tint: mottling of the rust's colour (1 = about 5% either way)
// @param a: relief of the rust: flakes and pits raised from the art's own speckle (0 flat .. 2 heavy)
// @param b: polish of the bare steel between the rust (0 dull .. 1 bright scratched steel)
// Rusty iron and steel, usually with paint: the texel says which. Rust (orange to dark brown, and speckled: the art
// paints it with a busy texture) turns matte and rough, pitted, the pits darker, and far away its painted speckle is
// raised a little; bare steel (grey) catches a tight scratched highlight; paint (any other colour, and flat orange or
// brown too: hazard yellow, red, green, orange) keeps a satin sheen with chips and scratches.

// Rust weight of a texel: orange to brown, from dark to bright.
float mat_rusted_metal_rust(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    return smoothstep(0.3, 0.5, sat) * smoothstep(0.18, 0.3, gr) * (1.0 - smoothstep(0.62, 0.74, gr))
         * step(c.b, c.g) * step(c.g, c.r) * smoothstep(0.06, 0.14, mx);
}

// A shared map sized in world units, the two octaves blended (MatOctave) at offsets that depend only on the frequency
// (so the octave at 2 * F0 is the same map as the next F0 one: no seam where F0 doubles between triangles), faded to
// neutral by the footprint of features texels across.
vec4 mat_rusted_metal_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 o0 = fract(F0 * vec2(0.7548777, 0.5698403)), o1 = fract(2.0 * F0 * vec2(0.7548777, 0.5698403));
    vec4 s = mix(MatMapAt(m, layer, F0, o0), MatMapAt(m, layer, 2.0 * F0, o1), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_rusted_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));

    // The art's luminance slope, solved from screen to texture space (no derivative is taken after the early out
    // above; the same as MatBumpScreen(m, m.lumD * k)), and how many of the texture's texels a pixel covers.
    float jd = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    vec2 dLuv = vec2(m.lumD.x * m.uvDy.y - m.lumD.y * m.uvDx.y, m.uvDx.x * m.lumD.y - m.uvDy.x * m.lumD.x)
              / (abs(jd) > 1e-20 ? jd : 1e-20);
    vec2 tsz = vec2(textureSize(texture0, 0));
    float texPx = m.uvPx * max(tsz.x, tsz.y);
    // Speckle: the luminance change from one texel to the next (far away the mips average the speckle out, about
    // as 1 / texels per pixel, which the second factor undoes). Rust is painted busy (a few percent a texel and
    // more); flat paint, orange or not, barely changes (under 1%).
    float speck = length(dLuv) / max(tsz.x, tsz.y) * max(texPx, 1.0);
    float rust = mat_rusted_metal_rust(c) * smoothstep(0.008, 0.03, speck);
    float steel = (1.0 - rust) * (1.0 - smoothstep(0.14, 0.3, (mx - mn) / max(mx, 1e-3))) * smoothstep(0.05, 0.15, mx);
    float paint = (1.0 - rust) * (1.0 - steel) * smoothstep(0.05, 0.15, mx);
    float dark = 1.0 - rust - steel - paint;   // near black (holes, gaps): left as it is

    // Pits, craters and fbm relief of the stone layer, a tile about 24 world units (pits about 0.4 units).
    vec4 st = mat_rusted_metal_map(m, MAT_MAP_STONE, 24.0 * m.scale, 4.0);
    // Chips and scratches, a tile about 20 world units.
    vec4 w = mat_rusted_metal_map(m, MAT_MAP_WEAR, 20.0 * m.scale, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.05 - m.p.x, w.a) * step(0.01, m.p.x);

    // Rust relief: the map's pits close up; and, where a texel is about a pixel or smaller, the art's own speckle
    // raised (darker = deeper, 0.6 world units per unit of luminance). Magnified, the bilinear texture is faceted per
    // texel, so its slope would light every texel's staircase: faded out by two pixels a texel. The art's slope is
    // filtered by the texture's mips, so it stays calm far away.
    float relief = clamp(m.p.z, 0.0, 2.0);
    vec3 dnRust = MatBumpUv(m, dLuv * (0.6 * relief * m.scale)) * smoothstep(0.5, 1.0, texPx);
    // (Capped low: at grazing angles a pixel spans a long stretch of surface and the screen slope would blow up.)
    dnRust = dnRust * min(1.0, 0.2 / max(length(dnRust), 1e-4)) + 0.5 * relief * MatMapBump(m, st, 1.0);
    vec3 dnHard = MatMapBump(m, w, 0.5);
    o.dn = rust * dnRust + (steel + paint) * (dnHard + 0.15 * MatMapBump(m, st, 1.0));

    // Matte rust; steel tight and bright where polished, rougher in scratches; paint satin, chips rougher.
    float scratch = max(MatMapVar(w), 0.0) * smoothstep(0.5, 0.62, w.a);
    o.gloss = rust * (0.5 + 0.3 * MatMapVar(st))
            + steel * mix(1.2, 1.9, m.p.w) * (1.0 - 0.8 * scratch)
            + paint * mix(1.5, 0.8, worn) + dark;
    o.spec = rust * 0.75 + steel * mix(1.0, 1.1, m.p.w) + paint * mix(1.05, 0.85, worn) + dark;
    // Pits a little darker (cavity), rust mottled a few percent; the cavity and the weaker specular keep the rust's
    // mean value where the art has it.
    float pit = min(MatMapHeight(st), 0.0);
    o.ao = 1.0 + rust * min(relief, 1.0) * 0.5 * pit + (steel + paint) * 0.5 * min(MatMapHeight(w), 0.0);
    // Steel reflects the sky and ground a little (brighter facing the sky, a dark horizon line), more at grazing angles.
    float ry = dot(reflect(-m.v, normalize(m.n + o.dn)), m.up);
    float env = (0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.1) * (0.7 + 0.6 * (1.0 - m.ndv));
    o.albedo = c * (1.0 + rust * 0.1 * m.p.y * MatMapVar(st) + steel * m.p.w * 0.15 * env);
    return o;
}
// -- sand_dirt.glsl
// @class sand_dirt
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=1 b=1
// @param tint: albedo mottle (1 = about 3% either way)
// @param a: pebble/clod relief amount (1 normal, 0 none)
// @param b: fine grain amount (1 normal, 0 none)
// Sand, dry earth, sandstone, soil: clods and pebbles (the stone map, tile about 24 units) and fine grain (the grain map,
// tile about 5 units) in the light, matte, with a shallow cavity (never below 0.8, so pits read as relief, not stains).
// Both maps blend the two octaves around their size (MatOctave), so the size never jumps between triangles of different
// texel density. 4 map fetches, no noise.

// A layer about tileWorld units a tile, as MatMapWorld but with one offset for both octaves: where the texel density
// sits on a power of two, floor() in MatOctave flips per pixel between (F, blend 0) and (F/2, blend 1), and both must
// then sample the same pattern (MatMapWorld's two offsets turn that into a pixel-scale maze).
vec4 mat_sand_dirt_map(MatIn m, float layer, float tileWorld, float texels, vec2 off) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, off), MatMapAt(m, layer, 2.0 * F0, off), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_sand_dirt(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Green texels (grass rims on craters) keep little.
    float green = clamp((m.albedo.g - max(m.albedo.r, m.albedo.b)) * 8.0, 0.0, 1.0);
    float k = (1.0 - 0.7 * green) * m.p.z;
    vec4 s = mat_sand_dirt_map(m, MAT_MAP_STONE, 24.0 * m.scale, 4.0, vec2(0.0));
    o.dn = MatMapBump(m, s, 1.1 * k);
    o.ao = 1.0 + 0.4 * k * min(MatMapHeight(s), 0.0);
    o.albedo = MatVary(m.albedo, 0.08 * m.p.y, MatMapVar(s) * 2.0 * (1.0 - 0.5 * green));
    vec4 g = mat_sand_dirt_map(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0, vec2(0.17, 0.43));
    o.dn += MatMapBump(m, g, 0.5 * m.p.w);
    o.spec = 0.8 + 0.5 * MatMapVar(g);
    o.gloss = 0.7;
    return o;
}
// -- skin.glsl
// @class skin
// @default scale=1 strength=1 rough=0 wear=0 tint=0.6 a=0.5 b=0.5
// @param tint: albedo mottle (1 = a few percent)
// @param a: wet sheen (0 dry .. 1 slick)
// @param b: pore and wrinkle relief (0 none .. 1 strong)
// Non-worm skin: creatures, faces, hands, hides. Fine pores and mottle (the GRAIN map at a 5-unit tile, features well
// under a tenth of a world unit, so no cell network: up close a soft stipple in the sheen, from afar only a slightly
// broken gloss), the art's own wrinkles and stitch lines as relief (luminance as a very low height), a soft sheen on
// fleshy texels, slick where it is dark (eyes, mouths, seams) and calmer where the texel is white or grey (sleeves,
// teeth, sclera: cloth and enamel in atlases). Textures on the worm's own material (specular 0.2/0.18/0.1, gloss 5,
// e.g. the Boggy eyes) never get material detail: the shader's worm skin path draws them.
MatOut mat_skin(MatIn m) {
    MatOut o = MatNone(m.albedo);
    vec3 e = MatBumpScreen(m, m.lumD * (0.22 * m.scale));
    e *= min(1.0, 0.3 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float flesh = smoothstep(0.08, 0.28, sat) * smoothstep(0.05, 0.16, lum) * (1.0 - smoothstep(0.88, 0.97, lum));
    float dark = 1.0 - smoothstep(0.04, 0.16, lum);
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0);
    float h = MatMapHeight(g), var = MatMapVar(g);
    float k = mix(1.0, 0.45, (1.0 - flesh) * (1.0 - dark));
    o.dn = (MatMapBump(m, g, 0.35 * m.p.w) + e * (1.5 * m.p.w)) * k;
    o.ao = 1.0 + 0.3 * m.p.w * min(h, 0.0) * flesh;
    o.albedo = MatVary(c, 0.04 * m.p.y * flesh, 2.0 * h);
    float wet = m.p.z;
    o.spec = 1.0 + wet * (0.9 * flesh + 1.2 * dark) - 0.3 * var * wet * flesh;
    o.gloss = 1.0 + wet * (1.4 * flesh + 2.0 * dark) - 2.0 * var * wet * flesh;
    return o;
}
// -- snow_ice.glsl
// @class snow_ice
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=1 b=1
// @param tint: unused
// @param a: sparkle amount (1 normal, 0 none)
// @param b: relief amount (1 normal)
// Snow and ice: soft lumps in the light up close (full while a lump covers 32 pixels on the worse screen axis, gone at
// 16, so flat snow stays flat from afar and at grazing), a fine grain, and static sparkle: small soft facets at hashed
// points on the surface that flash only where they mirror the sun to the eye, and change nothing otherwise. Saturated
// cold texels read as ice (glossy, smooth); dark or warm texels in an atlas (rock, wood, coal) get none of the sparkle
// and a little rocky grain. Lumps, grain and sparkle blend their two octaves (MatOctave, one offset or seed for both,
// so the pattern is continuous where floor() flips) and sizes never jump between triangles.
// 2 map fetches, 2 noise calls, 2 hashes.

// A layer about tileWorld units a tile, both octaves blended with one offset (MatMapWorld's two
// offsets make a pixel maze where the texel density sits on a power of two).
vec4 mat_snow_ice_map(MatIn m, float layer, float tileWorld, float texels, vec2 off) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, off), MatMapAt(m, layer, 2.0 * F0, off), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

// One octave of sparkle at F cells per texture unit: in one cell of three a facet, a dot of radius r cells at a hashed
// point, soft-edged and 0 at the cell's border, tilted by a hashed slope up to about 30 degrees. It flashes only while
// its facet mirrors the sun to the eye (within about 10 degrees of the half vector), so nothing changes off the flash
// (a raised specular alone would cost the dot diffuse light, see Light()'s keep, and leave it darker than the snow).
// Faded until the dot covers 4 pixels on the worse screen axis (0 at 2). (flash 0..1, the facet's normal tilt while it flashes).
vec4 mat_snow_ice_glint(MatIn m, float F, float r) {
    vec2 q = m.uv * F;
    vec3 h = MatHash32(mod(floor(q), F) + 11.0);
    vec2 ctr = vec2(r + 0.05) + h.xy * (1.0 - 2.0 * r - 0.1);
    float dot1 = 1.0 - smoothstep(0.3 * r, r, length(fract(q) - ctr));
    vec2 t = (fract(h.yx * 7.31 + h.z * 3.7) - 0.5) * 1.1;
    vec3 tilt = t.x * m.tu + t.y * m.tv;
    float al = dot(normalize(m.n + tilt), normalize(m.l + m.v));
    float k = dot1 * step(0.67, h.z) * MatFadeCells(F * m.uvPx * 0.5 / r);
    float fl = k * smoothstep(0.982, 0.996, al);
    return vec4(fl, fl * tilt);
}

MatOut mat_snow_ice(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    float mx = max(m.albedo.r, max(m.albedo.g, m.albedo.b)), mn = min(m.albedo.r, min(m.albedo.g, m.albedo.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float cold = step(m.albedo.r, m.albedo.b + 0.02);
    float snow = smoothstep(0.45, 0.7, lum) * (1.0 - smoothstep(0.25, 0.5, sat) * (1.0 - cold));
    float ice = smoothstep(0.12, 0.3, sat) * cold * smoothstep(0.35, 0.6, lum);
    float rock = 1.0 - max(snow, ice);
    // Soft lumps about 5 units across: light only (bump and a 2% mottle, no cavity), each octave faded while a lump
    // still covers 32 pixels on the worse screen axis (m.uvPx), long before it could turn into a blotch pattern.
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    float k0 = MatFadeCells(8.0 * F0 * m.uvPx) * (1.0 - fb);
    float k1 = MatFadeCells(16.0 * F0 * m.uvPx) * fb;
    vec3 n0 = MatGNoise(m.uv * F0 + 3.1, F0), n1 = MatGNoise(m.uv * (2.0 * F0) + 3.1, 2.0 * F0);
    vec3 nl = vec3(k0 * n0.x + k1 * n1.x, k0 * F0 * n0.yz + k1 * 2.0 * F0 * n1.yz);
    o.dn = MatBumpUv(m, nl.yz * (0.45 * m.scale * m.p.w) * (1.0 - 0.5 * ice));
    o.albedo = MatVary(m.albedo, 0.02, nl.x * 2.0);
    // Fine grain (the grain map, tile about 4 units, octaves blended and faded).
    vec4 g = mat_snow_ice_map(m, MAT_MAP_GRAIN, 4.0 * m.scale, 3.0, vec2(0.31, 0.77));
    o.dn += MatMapBump(m, g, (0.2 + 0.5 * rock) * (1.0 - 0.7 * ice));
    o.ao = 1.0 + 0.15 * min(MatMapHeight(g), 0.0);
    // Sparkle: cells about 0.6 units, one in three with a facet dot of radius 0.22 cells; only on snow and ice.
    float Fs, bs;
    MatOctave(m, 0.6 * m.scale, Fs, bs);
    vec4 gl = mix(mat_snow_ice_glint(m, Fs, 0.22), mat_snow_ice_glint(m, 2.0 * Fs, 0.22), bs) * ((1.0 - rock) * m.p.z);
    float glint = gl.x;
    o.dn += gl.yzw;
    o.spec = 1.0 + (0.8 + 5.0 * glint) * (0.4 + 0.6 * snow) - 0.4 * rock + 1.2 * ice;
    o.gloss = 1.0 + 3.0 * glint + 1.5 * ice - 0.5 * rock;
    return o;
}
// -- stone_rock.glsl
// @class stone_rock
// @default scale=1 strength=1 rough=0 wear=0.25 tint=1 a=0.5 b=0
// @param wear: grime and moss in the pits and cracks (0 none, 1 heavy)
// @param tint: albedo variation (1 = mottle and veins about 3% either way)
// @param a: relief carved from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance;
//   negative: polished, glassy stone (obsidian, polished marble) by -a: no art relief, pits or grain, a sharp sheen
// @param b: hairline cracks (a procedural network, no direction): 0 none, 1 strong
// Rock, carved and cut stone: the art's own carving lit as relief, broad hewn undulation, a pitted grain from the stone
// map sized in world units, cavity and dull sheen in the pits, faint veins and mottle, optional cracks and grime.
// Atlases: very saturated texels (a red glove, crate paint, flesh, glowing magma) are not stone and keep only a little
// of the art's relief.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
vec3 mat_stone_rock_art(MatIn m, float depth) {
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    if (abs(det) < 1e-14) return vec3(0.0);
    vec2 ts = vec2(textureSize(texture0, 0));
    float tp = max(m.uvPx * max(ts.x, ts.y), 1e-6);
    float lod = max(log2(tp), 0.0);
    vec2 e = exp2(lod) / ts;
    float pp = MatLum(textureLod(texture0, m.uv + e, lod).rgb), mm = MatLum(textureLod(texture0, m.uv - e, lod).rgb);
    float pm = MatLum(textureLod(texture0, m.uv + vec2(e.x, -e.y), lod).rgb), mp = MatLum(textureLod(texture0, m.uv + vec2(-e.x, e.y), lod).rgb);
    vec2 sl = 0.25 * vec2(pp + pm - mp - mm, pp + mp - pm - mm) / e;
    vec3 d = MatBumpUv(m, sl * (depth * (1.0 - 0.4 * smoothstep(3.0, 8.0, 1.0 / tp))));
    // (The footprint's elongation on screen: 1 face on, about 1 / cos of the view angle when grazing.)
    float el = m.uvPx * m.uvPx / abs(det);
    return d * (min(1.0, 0.3 * inversesqrt(max(dot(d, d), 1e-8))) * (1.0 - smoothstep(2.0, 3.6, el)));
}

// Hairline cracks: where gradient noise crosses zero, a closed network with no direction, cells about sizeWorld apart
// (the two octaves blended as MatOctave does, from one lattice offset so the blend is continuous across octaves).
// jag (a fine height, e.g. the pores') makes the lines ragged instead of smooth loops; its own slope is left out.
// Returns (crack 0..1, d crack / duv); a crack's line is about w of a cell wide, faded out before it is under 2 pixels.
vec3 mat_stone_rock_crack(MatIn m, float sizeWorld, float w, float jag) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 r = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        float f = F0 * (1.0 + float(i));
        vec3 n = MatGNoise(m.uv * f + (3.7 + 9.0 * m.seed), f);
        float t = clamp(abs(n.x + jag) / w, 0.0, 1.0);
        vec3 k = vec3(1.0 - t * t * (3.0 - 2.0 * t), (-6.0 * t * (1.0 - t) / w * sign(n.x + jag) * f) * n.yz);
        r += k * (i == 0 ? 1.0 - fb : fb) * MatFadeUv(m, f / (2.0 * w));
    }
    return r;
}

MatOut mat_stone_rock(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float lum = MatLum(c), mx = max(c.r, max(c.g, c.b));
    float st = 1.0 - smoothstep(0.74, 0.86, (mx - min(c.r, min(c.g, c.b))) / max(mx, 1e-3));
    // Polish (a < 0): the pits and grain ground away, the undulation mostly, a glassy sheen.
    float pol = clamp(-m.p.z, 0.0, 1.0), rgh = 1.0 - pol;
    // The art's relief: brighter is higher.
    o.dn = mat_stone_rock_art(m, (0.4 * max(m.p.z, 0.0) * (0.4 + 0.6 * st)));
    // Hewn undulation about 5 world units across, 0.2 deep: flat faces stop looking flat. Both octaves from one
    // lattice offset, so the 2 * F0 octave at blend 1 is the next F0 octave at blend 0 (no switch between patterns).
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0 + 5.3, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + 5.3, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    o.dn += MatBumpUv(m, g.yz * (0.2 * m.scale * st * (1.0 - 0.75 * pol) * MatFadeUv(m, F0 * (1.0 + fb))));
    // Pitted grain and veins: the stone map, a tile about 28 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 28.0 * m.scale, 6.0);
    float h = MatMapHeight(s) * (st * rgh), va = MatMapVar(s) * st;
    o.dn += MatMapBump(m, s, 0.35 * st * rgh);
    float pit = smoothstep(-0.22, -0.42, h);
    // Hairline cracks, cells about 7 world units across, 0.12 deep (a uniform branch on the parameter).
    if (m.p.w > 0.0) {
        vec3 k = mat_stone_rock_crack(m, 7.0 * m.scale, 0.04, 0.08 * MatMapHeight(s)) * (m.p.w * st);
        o.dn += MatBumpUv(m, k.yz * (-0.12 * m.scale));
        pit = max(pit, k.x);
        va -= 0.25 * k.x;
    }
    // Cavity in the pits and cracks; grime there (moss where they face the sky) by wear.
    o.ao = 1.0 - 0.35 * pit;
    o.albedo = MatVary(c, 0.03 * m.p.y, 1.5 * min(va + 0.1 * st, 0.0) + 0.5 * h + 0.4 * st * g.x);
    float grime = pit * m.p.x * 0.35;
    o.albedo *= mix(vec3(1.0), mix(vec3(0.85), vec3(0.84, 0.95, 0.78), smoothstep(0.55, 0.9, m.sky)), grime);
    // Dull in the pits and on dark art, a faint polish on raised grain and pale worn faces; glassy when polished.
    o.spec = mix(1.0, 0.8 + 0.45 * lum, st) * (1.0 - 0.6 * pit + 0.4 * max(h, 0.0)) * (1.0 + 0.6 * pol);
    o.gloss = (1.0 + st * (0.6 * max(h, 0.0) - 0.1) - 0.3 * pit) * (1.0 + 1.5 * pol);
    return o;
}
// -- wood_bark.glsl
// @class wood_bark
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.45 b=0
// @param tint: albedo variation along the fissures (1 = about 5% either way)
// @param a: relief from the art itself, world units of depth per unit of the texel's luminance (dark furrows sink,
// @param a: light ridges rise); 0 off
// @param b: fissure direction 0 along v (a trunk's texture standing up), 1 along u; add 2 for pale (silvered or
// @param b: bleached) bark: bright greys are then bark, not snow
// Bark, logs, posts, stumps, branches, husk. The art paints its furrows and knots: the snippet lifts them into relief
// (the art's own luminance as a height), cuts the shared bark map's fissures and crack network into the ridges, adds
// a fine fibre along the fissures (the wood map turned) and shades only the deep fissures. Ridges keep a faint dry
// sheen, fissures none. The texel decides in atlases: brown (warm, not too vivid) and green moss get the bark; snow
// and ice (bright, grey-blue) stay smooth with a crisp highlight; vivid paint (yellow, orange, cyan) and plain greys
// (cloth, stone) keep only a quarter of the map, no cavity and their own sheen. Pale bark gets a lighter map. Hue and
// value stay; albedo moves a few percent at most.

// The art's luminance slope (per texture unit) from three bilinear samples of texture0 on a circle a texel across
// (wider when minified), fitted with a plane: continuous across texels, unlike the screen derivative of the bilinear
// sample, which steps at every texel (seams then light up as stairs). Also returns texels per pixel.
vec2 mat_wood_bark_art(MatIn m, out float texPx) {
    vec2 ts = vec2(textureSize(texture0, 0));
    texPx = m.uvPx * max(ts.x, ts.y);
    vec2 h = max(1.0 / ts, vec2(m.uvPx));
    vec2 d1 = vec2(1.0, 0.0), d2 = vec2(-0.5, 0.8660254), d3 = vec2(-0.5, -0.8660254);
    float l1 = MatLum(textureGrad(texture0, m.uv + h * d1, m.uvDx, m.uvDy).rgb);
    float l2 = MatLum(textureGrad(texture0, m.uv + h * d2, m.uvDx, m.uvDy).rgb);
    float l3 = MatLum(textureGrad(texture0, m.uv + h * d3, m.uvDx, m.uvDy).rgb);
    return (2.0 / 3.0) * (l1 * d1 + l2 * d2 + l3 * d3) / h;
}

MatOut mat_wood_bark(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    bool swap = mod(m.p.w, 2.0) >= 0.5;
    bool pale = m.p.w >= 1.5;
    vec3 tc = swap ? m.tv : m.tu;   // across the fissures

    // What the texel is: bark, snow or ice (bright and nearly grey or bluish), moss (green).
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    // (Guarded: atan(0, 0) is undefined, and every pure grey or black texel has it.)
    float hy = sqrt(3.0) * (c.g - c.b), hx = 2.0 * c.r - c.g - c.b;
    float hue = degrees(atan(hy, hx + (abs(hx) + abs(hy) < 1e-5 ? 1e-5 : 0.0)));
    float snow = smoothstep(0.62, 0.78, mx) * (1.0 - smoothstep(0.12, 0.3, sat)) + smoothstep(0.55, 0.7, mx) * smoothstep(95.0, 115.0, -hue) * (1.0 - smoothstep(0.55, 0.7, sat));
    snow = pale ? 0.0 : clamp(snow, 0.0, 1.0);
    float moss = smoothstep(70.0, 85.0, hue) * (1.0 - smoothstep(165.0, 180.0, hue)) * smoothstep(0.2, 0.35, sat);
    // Brown: a red-brown to ochre hue that is not vivid (chroma mx - mn up to about 0.38; painted yellow and orange
    // run 0.5 to 0.8). Plain greys are cloth or stone unless the bark is pale. The rest keeps a quarter of the map.
    float brown = (1.0 - smoothstep(40.0, 60.0, abs(hue - 25.0))) * (1.0 - smoothstep(0.38, 0.5, mx - mn))
                * (pale ? 1.0 : smoothstep(0.04, 0.12, sat));
    float key = pale ? 1.0 : max(0.25, max(brown, moss));
    float bark = (1.0 - snow) * (1.0 - 0.45 * moss) * key;
    float cav = bark * key * (pale ? 0.4 : 1.0);   // cavity: none on paint, light on pale bark
    float mapK = bark * (pale ? 0.4 : 1.0);        // the bark map's normal

    // Relief from the art: its luminance as a height (dL/du, dL/dv); softer where one texel spans many pixels (big
    // soft bilinear bumps), where many texels share a pixel (it would sparkle), and on paint and cloth (key).
    float texPx;
    vec2 dL = mat_wood_bark_art(m, texPx);
    float artK = m.p.z * m.scale * mix(0.3, 1.0, smoothstep(0.12, 0.45, texPx)) * (1.0 - 0.75 * smoothstep(1.0, 3.0, texPx));
    vec3 s = MatBumpUv(m, dL * artK * mix(0.25, 1.0, key));
    o.dn = s * inversesqrt(1.0 + dot(s, s)) * (1.0 - 0.6 * snow);

    // Fissures and cracks: the bark map about 22 world units a tile (two octaves, faded by footprint).
    float F0, fb;
    MatOctave(m, 22.0 * m.scale, F0, fb);
    vec2 uv = swap ? m.uv.yx : m.uv, dx = swap ? m.uvDx.yx : m.uvDx, dy = swap ? m.uvDy.yx : m.uvDy;
    vec4 g = mix(textureGrad(sunstoneMat, vec3(uv * F0, MAT_MAP_BARK), dx * F0, dy * F0),
                 textureGrad(sunstoneMat, vec3(uv * 2.0 * F0 + vec2(0.37, 0.61), MAT_MAP_BARK), dx * 2.0 * F0, dy * 2.0 * F0), fb);
    g = MatMapNeutral(g, MatMapFade(m, F0 * (1.0 + fb), 5.0));
    float gh = MatMapHeight(g), gv = MatMapVar(g);
    vec2 t = (g.xy * 2.0 - 1.0) * 0.6 * mapK;
    o.dn += t.x * (swap ? m.tv : m.tu) + t.y * (swap ? m.tu : m.tv);

    // Fibre along the fissures: the wood map turned, a tile about 6 world units, one octave, faded early.
    float Ff, ff;
    MatOctave(m, 6.0 * m.scale, Ff, ff);
    Ff *= ff > 0.5 ? 2.0 : 1.0;
    vec2 fr = vec2(Ff, 2.0 * Ff);
    vec2 uf = swap ? m.uv : m.uv.yx, fdx = swap ? m.uvDx : m.uvDx.yx, fdy = swap ? m.uvDy : m.uvDy.yx;
    vec4 f = textureGrad(sunstoneMat, vec3(uf * fr + vec2(0.13, 0.71), MAT_MAP_WOOD), fdx * fr, fdy * fr);
    f = MatMapNeutral(f, MatMapFade(m, 2.0 * Ff, 6.0));
    o.dn += (f.y * 2.0 - 1.0) * 0.3 * bark * tc;

    // Deep fissures shaded, ridges with a faint dry sheen, a small variation in the paint (mean kept).
    o.ao = 1.0 - 1.4 * max(-gh - 0.1, 0.0) * cav;
    o.albedo = MatVary(c, 0.05 * m.p.y * cav, 2.0 * (gv + 0.03));
    o.spec = mix(mix(1.0, 0.85 + 0.8 * clamp(gh, -0.3, 0.3), key), 1.6, snow);
    o.gloss = mix(mix(1.0, 0.75, key), 2.5, snow);
    return o;
}
// -- wood_planks.glsl
// @class wood_planks
// @default scale=1 strength=1 rough=0 wear=0.25 tint=1 a=0.3 b=1
// @param wear: scuffs and scratches (0 none .. 1 battered): rougher, a touch lighter, dented
// @param tint: grain albedo variation (1 = about 4% either way along the latewood)
// @param a: relief from the art itself, world units of depth per unit of the texel's luminance (dark seams, gaps and
// @param a: grain lines sink, light boards rise); 0 off
// @param b: grain direction 0 along u, 1 along v; add 2 for pale weathered (grey) wood: low saturation is then wood,
// @param b: and only dark greys count as metal
// Planks, crates, fences, barrels, handles. The cartoon art already paints its grain, knots and seams: the snippet
// lifts them into relief (the art's own luminance as a height), lays a fine fibre and pore grain along the art's grain
// (the shared wood map, stretched across), gives latewood a faint sheen, and dents and scuffs the surface with the
// wear map. In atlases the texel decides: wood hues get everything; greys get metal (smooth, brighter, tighter
// highlight, no grain); other paint keeps a weaker grain. Hue and value stay; albedo moves a few percent at most.

// The art's luminance slope (per texture unit) from three bilinear samples of texture0 on a circle a texel across
// (wider when minified), fitted with a plane. Unlike the screen derivative of the bilinear sample (constant within a
// texel, so seams light up as texel-grid stairs) it is continuous across texels. Also returns texels per pixel.
vec2 mat_wood_planks_art(MatIn m, out float texPx) {
    vec2 ts = vec2(textureSize(texture0, 0));
    texPx = m.uvPx * max(ts.x, ts.y);
    vec2 h = max(1.0 / ts, vec2(m.uvPx));
    vec2 d1 = vec2(1.0, 0.0), d2 = vec2(-0.5, 0.8660254), d3 = vec2(-0.5, -0.8660254);
    float l1 = MatLum(textureGrad(texture0, m.uv + h * d1, m.uvDx, m.uvDy).rgb);
    float l2 = MatLum(textureGrad(texture0, m.uv + h * d2, m.uvDx, m.uvDy).rgb);
    float l3 = MatLum(textureGrad(texture0, m.uv + h * d3, m.uvDx, m.uvDy).rgb);
    return (2.0 / 3.0) * (l1 * d1 + l2 * d2 + l3 * d3) / h;
}

// The shared wood map along the texture's grain (swap: the grain runs along v), sized in world units like MatMapWorld,
// squeezed twice across the grain for long fibres: (sample, fade). Two textureGrad fetches.
vec4 mat_wood_planks_grain(MatIn m, float tileWorld, bool swap, out float k) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 uv = swap ? m.uv.yx : m.uv, dx = swap ? m.uvDx.yx : m.uvDx, dy = swap ? m.uvDy.yx : m.uvDy;
    vec2 f = vec2(F0, 2.0 * F0);
    vec4 s = mix(textureGrad(sunstoneMat, vec3(uv * f, MAT_MAP_WOOD), dx * f, dy * f),
                 textureGrad(sunstoneMat, vec3(uv * 2.0 * f + vec2(0.37, 0.61), MAT_MAP_WOOD), dx * 2.0 * f, dy * 2.0 * f), fb);
    k = MatMapFade(m, 2.0 * F0 * (1.0 + fb), 6.0);
    return MatMapNeutral(s, k);
}

MatOut mat_wood_planks(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    float bp = m.p.w;
    bool swap = mod(bp, 2.0) >= 0.5;
    bool pale = bp >= 1.5;
    vec3 ta = swap ? m.tv : m.tu, tc = swap ? m.tu : m.tv;   // along and across the grain

    // What the texel is: wood (warm hues, or any low saturation on pale wood), metal (greys), or other paint.
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    // Hue as the angle of (r - g, g - b), 0 red; wood lies from red-orange to yellow, around 30 degrees.
    // (Guarded: atan(0, 0) is undefined, and every pure grey or black texel has it.)
    float hy = sqrt(3.0) * (c.g - c.b), hx = 2.0 * c.r - c.g - c.b;
    float hue = degrees(atan(hy, hx + (abs(hx) + abs(hy) < 1e-5 ? 1e-5 : 0.0)));
    float warm = 1.0 - smoothstep(32.0, 46.0, abs(hue - 28.0));
    float grey = 1.0 - smoothstep(0.12, 0.24, sat);
    // (Near-white is paint or whitewash, not metal: bright fittings are rare, white boards common.)
    float metal = grey * (pale ? 1.0 - smoothstep(0.38, 0.5, mx) : smoothstep(0.1, 0.22, mx) * (1.0 - smoothstep(0.7, 0.8, mx)));
    float wood = pale ? 1.0 - metal : warm * smoothstep(0.16, 0.3, sat);
    float paint = max(1.0 - wood - metal, 0.0);

    // Relief from the art: its luminance as a height (dL/du, dL/dv). Softer where one texel spans many pixels (big soft
    // bilinear bumps) and where many texels share a pixel (it would sparkle).
    float texPx;
    vec2 dL = mat_wood_planks_art(m, texPx);
    float artK = m.p.z * m.scale * mix(0.3, 1.0, smoothstep(0.12, 0.45, texPx)) * (1.0 - 0.75 * smoothstep(1.0, 3.0, texPx));
    vec3 s = MatBumpUv(m, dL * artK);
    o.dn = s * inversesqrt(1.0 + dot(s, s)) * (1.0 - 0.5 * metal);   // a seam tilts the normal 45 degrees at most

    // Fibres, pores and latewood: a wood tile about 14 world units along the grain (planks of a 20-unit crate get a few
    // growth lines each, under the art's own bigger ones).
    float k;
    vec4 g = mat_wood_planks_grain(m, 14.0 * m.scale, swap, k);
    float gv = MatMapVar(g), gh = MatMapHeight(g);
    float grain = wood + 0.45 * paint;
    vec2 t = (g.xy * 2.0 - 1.0) * vec2(0.2, 0.35) * grain;
    o.dn += t.x * ta + t.y * tc;
    o.albedo = MatVary(c, 0.045 * m.p.y * grain, 2.0 * gv);
    // Latewood (darker bands) is denser and takes a faint sheen; open pores are rough and shaded.
    o.spec = 1.0 + (0.7 * -gv + 0.35 * gh) * grain;
    o.gloss = 1.0 + 0.6 * -gv * grain;
    o.ao = 1.0 - 1.6 * max(-gh - 0.12, 0.0) * grain;   // only the deep pores and ring cracks

    // Wear: scuffs, scratches and dents where the wear order passes 1 - wear. One fetch at the wear tile's octave.
    float Fw, fw;
    MatOctave(m, 22.0 * m.scale, Fw, fw);
    Fw *= fw > 0.5 ? 2.0 : 1.0;
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, Fw, vec2(0.21, 0.47));
    float kw = MatMapFade(m, Fw, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * kw;
    o.dn += MatMapBump(m, w, (0.15 + 0.2 * wood) * worn);
    // (Metal's brighter highlight takes from its diffuse in Light(): a few percent of albedo back keeps its mean.)
    // Only bare wood scuffs lighter: on paint and metal a light scratch reads as a hairline drawn over the art.
    o.albedo *= 1.0 + 0.04 * worn * wood + 0.05 * metal;

    // Metal: smooth, a tight bright highlight; scratches dull it. Wood scuffs are rough.
    o.spec = mix(o.spec * (1.0 - 0.25 * worn), 1.6 * (1.0 - 0.3 * worn), metal);
    o.gloss = mix(o.gloss * (1.0 - 0.35 * worn), 3.0 * (1.0 - 0.4 * worn), metal);
    return o;
}

// ---- generated: class ids (tools/materials/classes.json) and the dispatch
const int MAT_CLASSES = 26;
const int MAT_FALLBACK_METAL = 8;   // bare_metal
const int MAT_FALLBACK_MATTE = 0;   // generic
MatOut MatDispatch(int c, MatIn m) {
    if (c == 1) return mat_painted_metal(m);
    if (c == 2) return mat_fabric_cloth(m);
    if (c == 3) return mat_fur_hair(m);
    if (c == 4) return mat_leaf_foliage(m);
    if (c == 5) return mat_plastic(m);
    if (c == 6) return mat_stone_rock(m);
    if (c == 7) return mat_wood_planks(m);
    if (c == 8) return mat_bare_metal(m);
    if (c == 9) return mat_skin(m);
    if (c == 10) return mat_other(m);
    if (c == 11) return mat_leather(m);
    if (c == 12) return mat_gold_brass(m);
    if (c == 13) return mat_emissive_light(m);
    if (c == 14) return mat_glass_gem(m);
    if (c == 15) return mat_bone_teeth(m);
    if (c == 16) return mat_rusted_metal(m);
    if (c == 17) return mat_cartoon_flat(m);
    if (c == 18) return mat_wood_bark(m);
    if (c == 19) return mat_paper_card(m);
    if (c == 20) return mat_sand_dirt(m);
    if (c == 21) return mat_rope_straw(m);
    if (c == 22) return mat_concrete_plaster(m);
    if (c == 23) return mat_snow_ice(m);
    if (c == 24) return mat_grass_turf(m);
    if (c == 25) return mat_brick(m);
    if (c == 26) return mat_rubber(m);
    return mat_generic(m);
}
// The tag an untagged texture of a fallback class gets: (class, scale, strength, rough), (wear, tint, a, b).
void MatDefaults(int c, out vec4 t0, out vec4 t1) {
    if (c == 8) { t0 = vec4(8.0, 1.0, 1.0, 0.0); t1 = vec4(0.3, 1.0, 0.6, 0.0); return; }
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
    // A tilt of more than about 35 degrees is never wanted (a snippet's division by a degenerate density or gradient).
    o.dn *= min(1.0, 0.7 / max(length(o.dn), 1e-6));
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
