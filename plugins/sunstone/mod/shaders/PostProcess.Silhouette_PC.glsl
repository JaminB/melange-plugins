#version 120
// The game's Silhouette_PC (PostProcess.cg), which draws the turn's worm, where something stands between it and the camera
// (and the game's stencil allows), as a ghost of what is in front: the scene darkened and greyed, drawn into the worm's own
// target with blending (source alpha) before PostProcess.RecombineWorms lays that target over the scene. The game writes
// that ghost with alpha 1, which wiped out the worm under it: its colour, and the mark its skin carries for Bloodsand and
// Kindjal (see FixedFunction.FFFragmentMainTexLit.glsl, SkinMark), so their wounds and acid stopped in a hard line where the
// worm went behind a ledge. Here the ghost is written with alpha SIL_A instead: the same ghost over 40% of the worm's own
// colour (its skin tone carries on through the ledge, dimmed but still telling one tone from another, instead of a hard
// wedge of grey where it is cut off), and the worm's alpha comes out as SIL_A^2 + (1 - SIL_A) * its own, so a skin texel
// (mark 192..240 of 255) lands at 169..188 and anything else (alpha 1) at 194: PostProcess.RecombineWorms.glsl tells hidden
// skin by it. Keep SIL_A the same there.
// The game draws this quad with glBegin/glEnd, so it takes no parameters (see PostProcess.RecombineWorms.glsl). Sunstone's
// Lua runs it only while the Worm skin is re-toned or Sunstone draws the hair (with both off the game's ghost is kept).
uniform sampler2D texture0;   // the scene without the turn's worm: colour
uniform sampler2D texture1;   // ...and depth
uniform sampler2D texture2;   // the turn's worm: depth

const float SIL_A = 0.6;

void main() {
    vec2 uv = gl_TexCoord[0].xy;
    float wormDepth = texture2D(texture2, uv).r;
    gl_FragDepth = wormDepth;
    gl_FragColor = texture2D(texture1, uv).r < wormDepth ? vec4(texture2D(texture0, uv).rgb * 0.5 + 0.125, SIL_A) : vec4(0.0);
}
