-- skin (P3): the themed atlases and fonts of P1 (SKIN.atlas, SKIN.fonts from 55_atlas.lua), loaded once without
-- mips, and the drawing helpers every UI fragment uses: nine-slices that put a shape's visible edge on the given rect
-- (the baked shadow margin goes outside it), atlas icons in four states, and text in the four baked fonts with a
-- cached measure (I4: no layout of the same string twice). Every helper falls back to plain rects and the default
-- font when an atlas or a font is missing, so a broken file shows an ugly player, never no player.
do
  -- Palette of design 2.8 (r-style.md 2), 0xRRGGBB.
  SKIN.C = {
    panel = 0x1D5060, panelTop = 0x1F5E70, dark = 0x153443, dark2 = 0x194356, light = 0x31636B, light2 = 0x477776,
    btn = 0x005372, btnHover = 0x0E6C8E, btnPress = 0x00435C, off = 0x605284, offText = 0x94A1B8,
    cream = 0xFEE195, title = 0xFFF59B, gold = 0xEFDE84, paper = 0xFFEFD6, ink = 0x1A1004, black = 0x000000,
    white = 0xFFFFFF, seek = 0xFFD24A, buffered = 0x477776, error = 0xE8221A, ok = 0x5BD15B, warn = 0xFFB020,
  }
  local C = SKIN.C
  local STATE = {normal = 1, hover = 2, press = 3, off = 4}

  local tex = {}             -- panels, icons, cursor -> texture id (false once a load failed)
  local fonts = {}           -- display, display_s, body, body_s -> font id (false once a load failed)
  local loaded = false
  local uv = {}              -- "panels:name" / "icons:name:state" -> {u0, v0, u1, v1}

  SKIN.alpha = 1             -- multiplies every colour drawn; a caller sets it around a faded surface
  SKIN.s = 1                 -- the layout scale (LAYOUT.scale()), set once per frame by MAIN

  local function loadTex(key)
    local a = SKIN.atlas and SKIN.atlas[key]
    if not a then return false end
    local ok, id, why = pcall(wum.draw.texture, a.file, {mips = false})
    if ok and id then return id end
    U.log("warn", "could not load", a.file, ok and why or id)
    return false
  end

  -- Loads the textures and fonts the first time a frame draws (the draw callback is where the game has a context).
  function SKIN.ensure()
    if loaded then return end
    loaded = true
    for _, k in ipairs{"panels", "icons", "cursor"} do tex[k] = loadTex(k) end
    for _, k in ipairs{"display", "display_s", "body", "body_s"} do
      local f = SKIN.fonts and SKIN.fonts[k]
      local ok, id, why = false, nil, nil
      if f and wum.draw.font then ok, id, why = pcall(wum.draw.font, f.png, f.json) end
      fonts[k] = ok and id or false
      if f and not fonts[k] then U.log("warn", "could not load font", f.png, ok and why or id) end
    end
  end

  function SKIN.texture(key) return tex[key] or nil end
  function SKIN.font(key) return fonts[key] or nil end

  -- 0xRRGGBBAA from 0xRRGGBB and an alpha 0..1, times SKIN.alpha.
  function SKIN.col(rgb, a)
    local al = math.floor(U.clamp((a or 1) * SKIN.alpha, 0, 1) * 255 + 0.5)
    return ((rgb or 0xFFFFFF) << 8) | al
  end
  local col = SKIN.col

  local function rectUV(atlas, r)
    return {r.x / atlas.w, r.y / atlas.h, (r.x + r.w) / atlas.w, (r.y + r.h) / atlas.h}
  end

  local function panelRect(name)
    local p = SKIN.atlas and SKIN.atlas.panels
    return p and p.rects[name], p
  end

  local function cachedUV(key, atlas, r)
    local u = uv[key]
    if not u then
      u = rectUV(atlas, r)
      uv[key] = u
    end
    return u
  end

  local FALLBACK = {panel = C.panel, panel_dark = C.dark, tooltip = C.dark2, btn = C.btn, btn_hover = C.btnHover,
    btn_press = C.btnPress, btn_off = C.off, pill = C.panel, tag = C.paper, well = C.dark, bar_track = C.dark,
    bar_fill = C.seek, frame_video = C.black, frame_corner = C.black}

  -- A nine-slice whose visible shape covers x0..x1, y0..y1. The scale is the 2x atlas at the layout scale, shrunk when
  -- the rect is smaller than the corners. o: {tint = 0xRRGGBB, a = alpha, s = scale}.
  function SKIN.nine(name, x0, y0, x1, y1, o)
    local r, atlas = panelRect(name)
    local w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 then return end
    local tint, a = o and o.tint or 0xFFFFFF, o and o.a or 1
    if not r or not tex.panels then
      local fill = tint ~= 0xFFFFFF and tint or FALLBACK[name] or C.panel
      wum.draw.hudRect(x0, y0, x1, y1, col(fill, a), true)
      wum.draw.hudRect(x0, y0, x1, y1, col(C.black, a), false, 2)
      return
    end
    local ns = 0.5 * (o and o.s or SKIN.s)
    local pad = r.pad
    local vlr, vtb = (r.l - pad.l) + (r.r - pad.r), (r.t - pad.t) + (r.b - pad.b)
    if vlr > 0 and w < vlr * ns then ns = w / vlr end
    if vtb > 0 and h < vtb * ns then ns = h / vtb end
    local u = cachedUV("panels:" .. name, atlas, r)
    wum.draw.hudNine(x0 - pad.l * ns, y0 - pad.t * ns, x1 + pad.r * ns, y1 + pad.b * ns, tex.panels,
      r.l, r.t, r.r, r.b, {scale = ns, uv = u, tint = col(tint, a)})
  end

  -- A video frame drawn around a picture rect, so that its hole is exactly the picture (design 2.8: the frame hugs
  -- the rect wum.draw.media returned; its inner corners cover the picture's corners).
  function SKIN.frameAround(name, x0, y0, x1, y1, o)
    local r = panelRect(name)
    local s = o and o.s or SKIN.s
    if not r or not r.inner or not tex.panels then
      local b = 6 * s
      SKIN.rect(x0 - b, y0 - b, x1 + b, y1 + b, C.black, o and o.a)
      return
    end
    local ns = 0.5 * s
    local p, i = r.pad, r.inner
    SKIN.nine(name, x0 - (i.l - p.l) * ns, y0 - (i.t - p.t) * ns, x1 + (i.r - p.r) * ns, y1 + (i.b - p.b) * ns,
      {tint = o and o.tint, a = o and o.a, s = s})
  end

  -- A plain (not sliced) part of the panels atlas stretched over the rect, its shadow margin outside: scrim,
  -- divider, swash, knob, tail.
  function SKIN.part(name, x0, y0, x1, y1, o)
    local r, atlas = panelRect(name)
    local a = o and o.a or 1
    if not r or not tex.panels then
      if name ~= "scrim" then wum.draw.hudRect(x0, y0, x1, y1, col(o and o.tint or C.black, a * 0.5), true) end
      return
    end
    local pad = r.pad
    local vw, vh = r.w - pad.l - pad.r, r.h - pad.t - pad.b
    local kx, ky = (x1 - x0) / math.max(vw, 1), (y1 - y0) / math.max(vh, 1)
    local u = cachedUV("panels:" .. name, atlas, r)
    wum.draw.hudImageUV(x0 - pad.l * kx, y0 - pad.t * ky, x1 + pad.r * kx, y1 + pad.b * ky, tex.panels,
      u[1], u[2], u[3], u[4], col(o and o.tint or 0xFFFFFF, a))
  end

  -- An icon `size` pixels square at x, y. state: "normal", "hover", "press" or "off".
  function SKIN.icon(name, x, y, size, state, o)
    local icons = SKIN.atlas and SKIN.atlas.icons
    local rs = icons and icons.rects[name]
    local si = STATE[state or "normal"] or 1
    local a = o and o.a or 1
    if not rs or not tex.icons then
      local c = si == 4 and C.offText or (si == 2 and C.white or C.cream)
      local inset = size * 0.25
      wum.draw.hudRect(x + inset, y + inset, x + size - inset, y + size - inset, col(c, a), true)
      return
    end
    local u = cachedUV("icons:" .. name .. ":" .. si, icons, rs[si] or rs[1])
    wum.draw.hudImageUV(x, y, x + size, y + size, tex.icons, u[1], u[2], u[3], u[4], col(o and o.tint or 0xFFFFFF, a))
  end

  ---------------------------------------------------------------- text

  -- The baked font for a style ("display" or "body") at a pixel size: the nearer of its two bakes.
  local function fontFor(kind, size)
    if kind == "display" then
      if size >= 24 then return fonts.display or fonts.display_s or nil end
      return fonts.display_s or fonts.display or nil
    end
    if size >= 18 then return fonts.body or fonts.body_s or nil end
    return fonts.body_s or fonts.body or nil
  end
  SKIN.fontFor = fontFor

  -- Measures are cached per (style, size, text): the queue and the peers list draw the same strings every frame.
  local MEASURE_CAP = 600
  local measures, nMeasures = {}, 0

  function SKIN.measure(text, size, kind)
    text = tostring(text)
    size = math.floor(size * 2 + 0.5) / 2
    kind = kind or "body"
    local key = kind .. "\0" .. size .. "\0" .. text
    local m = measures[key]
    if m then return m[1], m[2] end
    local f = fontFor(kind, size)
    local ok, w, h
    if f then ok, w, h = pcall(wum.draw.textSize, text, size, {font = f})
    else ok, w, h = pcall(wum.draw.textSize, text, size) end
    if not ok or type(w) ~= "number" then w, h = #text * size * 0.5, size end
    if type(h) ~= "number" then h = size end
    if nMeasures >= MEASURE_CAP then measures, nMeasures = {}, 0 end
    measures[key] = {w, h}
    nMeasures = nMeasures + 1
    return w, h
  end

  -- Text whose top-left (or top-centre / top-right with o.align) is x, y. o: {kind = "display"|"body", align,
  -- maxWidth (cut with an ellipsis), a, vcenter = a box height to centre the line in}.
  function SKIN.text(x, y, text, size, rgb, o)
    text = tostring(text)
    if text == "" then return end
    local kind = o and o.kind or "body"
    local f = fontFor(kind, size)
    if o and o.vcenter then
      local _, h = SKIN.measure(text, size, kind)
      y = y + (o.vcenter - h) / 2
    end
    local opts = {align = o and o.align or "left"}
    if f then opts.font = f else opts.shadow = col(C.black, o and o.a or 1) end
    if o and o.maxWidth then
      opts.maxWidth = math.max(1, o.maxWidth)
      opts.ellipsis = true
    end
    wum.draw.hudText(x, y, text, col(rgb or C.cream, o and o.a or 1), size, opts)
  end

  -- Word wrap to a width, cached like the measures: an array of lines (at most maxLines, the last one marked "...").
  local wraps, nWraps = {}, 0
  function SKIN.wrap(text, size, kind, width, maxLines)
    text = tostring(text)
    local key = (kind or "body") .. "\0" .. size .. "\0" .. math.floor(width) .. "\0" .. (maxLines or 0) .. "\0" .. text
    local hit = wraps[key]
    if hit then return hit end
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if line ~= "" and SKIN.measure(try, size, kind) > width then
        lines[#lines + 1] = line
        line = word
      else
        line = try
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if maxLines and #lines > maxLines then
      for i = #lines, maxLines + 1, -1 do lines[i] = nil end
      lines[maxLines] = lines[maxLines] .. " ..."
    end
    if nWraps >= 64 then wraps, nWraps = {}, 0 end
    wraps[key] = lines
    nWraps = nWraps + 1
    return lines
  end

  -- A plain filled rect in the palette (fills the atlas has no piece for: progress, markers, the empty video well).
  function SKIN.rect(x0, y0, x1, y1, rgb, a)
    if x1 <= x0 or y1 <= y0 then return end
    wum.draw.hudRect(x0, y0, x1, y1, col(rgb, a), true)
  end

  -- The spinner frame for now (12 frames a second).
  function SKIN.spinner()
    return "spinner" .. (math.floor(U.now() / 83) % 8 + 1)
  end

  -- Clips nest at most 4 deep in the core; callers use at most two.
  function SKIN.clip(x0, y0, x1, y1)
    if wum.draw.hudClip then wum.draw.hudClip(x0, y0, x1, y1) end
  end
  function SKIN.clipEnd()
    if wum.draw.hudClipEnd then wum.draw.hudClipEnd() end
  end
end
