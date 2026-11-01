-- Holo 1.2's Spotify setup (src/46_spotify.lua, src/87_music_ui.lua) against fake_spotify.lua's Melange 0.14 surface:
-- the Music tab's cards (signin, setup, waiting, account) and their transitions, the setup guide's three steps with
-- their click-gated buttons, the device picker (transfer, remembering), and the fallbacks on Melange 0.13 (Holo 1.1's
-- ini flow) and 0.12 (no Spotify).
local MW = require("mock_wum")
local FS = require("fake_spotify")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local ID = "0a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P"     -- 32 letters and digits
assert(#ID == 32)

local function machine(fsOpts)
  local wum, mock = MW.new()
  local fs = fsOpts and FS.install(wum, mock, fsOpts) or nil
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  mock.cursorSource = "frontend"
  mock.cursorPos = {2, 2}
  return {wum = wum, mock = mock, fs = fs, ns = wum._holoTest.ns}
end

local function v14(o)
  o = o or {}
  o.api = "0.14"
  if o.builtin == nil then o.builtin = true end
  return machine(o)
end

local function regions(m)
  local out = {}
  for _, r in ipairs(m.mock.regions()) do out[r.id] = r end
  return out
end

local function clickRegion(m, id)
  local r = regions(m)[id]
  if not r then return nil end
  return m.mock.click((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
end

-- Clicks a control and runs a frame (the control consumes the click and acts).
local function press(m, id, frames)
  local hit = clickRegion(m, id)
  m.mock.frames(frames or 1)
  return hit == id
end

local function texts(m)
  local out = {}
  for _, c in ipairs(m.mock.drawOf("hudText")) do out[#out + 1] = tostring(c.args[3]) end
  return table.concat(out, " ")       -- wrapped lines join back with a space
end
local function has(m, s) return texts(m):find(s, 1, true) ~= nil end
local function textIs(m, s)
  for _, c in ipairs(m.mock.drawOf("hudText")) do if c.args[3] == s then return true end end
  return false
end

local function openMusicTab(m)
  m.ns.PARTY.setSetup(true)
  m.ns.SETUP.setTab("music")
  m.mock.frames(40)                      -- regions exist for more than half a second
end

local function typeText(m, text)
  for ch in text:gmatch(".") do m.mock.emitNow("melange.input.char", {text = ch}) end
  m.mock.frame()
end

local function noErrors(m, what)
  check(#m.mock.logsOf("error") == 0, what .. ": no errors: " .. table.concat(m.mock.logsOf("error"), "; "))
end

-- 1. Melange 0.14 with the shared app, signed out: Sign in -> waiting (re-open, countdown, help) -> Cancel.
do
  local m = v14{app = "builtin"}
  local MUI, SPOT = m.ns.MUI, m.ns.SPOT
  check(SPOT.hasSetup() and SPOT.hasTransfer(), "0.14 surface detected")
  local su = SPOT.setup()
  check(su and su.app == "builtin" and su.appHint == "abcd" and su.builtin == true and su.ini == false
    and su.redirectUri == "http://127.0.0.1:8780/callback", "setup() cleaned")
  openMusicTab(m)
  check(MUI.spotifyCard() == "signin", "card: signin (" .. MUI.spotifyCard() .. ")")
  check(has(m, "Sign in with Spotify") and has(m, "Play music with the party") and has(m, "Holo never sees it"),
    "the sign-in card's texts")
  check(has(m, "Use my own Spotify app") and regions(m)["music.ownapp"] ~= nil, "the own-app link")
  check(not has(m, "Link your Spotify account"), "not the 1.1 consent block")
  local r = regions(m)["music.link"]
  check(r and (r.x1 - r.x0) * (r.y1 - r.y0) <= 1920 * 1080 / 4, "Sign in is at most a quarter of the window")
  local before = m.fs.connects
  check(press(m, "music.link"), "click Sign in")
  check(m.fs.connects == before + 1, "connect called once from the click")
  m.mock.frames(2)
  check(MUI.spotifyCard() == "waiting", "card: waiting")
  check(has(m, "Finish signing in in your browser") and has(m, "press Agree"), "the waiting texts")
  check(has(m, "Waiting for Spotify, 2:5") or has(m, "Waiting for Spotify, 3:00"), "the countdown: " .. texts(m))
  check(has(m, "Open the page again") and regions(m)["music.cancel"] ~= nil, "re-open and Cancel")
  check(regions(m)["music.wait.help"] == nil, "no help link in the first 15 s")
  m.mock.frames(40)
  check(press(m, "music.reopen"), "click re-open")
  check(m.fs.reopens == 1 and m.fs.status.state == "connecting", "the page opened again, same sign-in")
  m.mock.frame(16)                       -- 16 s later
  m.mock.frames(40)
  check(regions(m)["music.wait.help"] ~= nil and has(m, "Spotify shows an error?") and has(m, "Use your own app"),
    "the help link after 15 s (shared app wording)")
  check(not has(m, "Waiting for Spotify, 2:5"), "the countdown runs")
  check(press(m, "music.cancel", 3), "click Cancel")
  check(m.fs.cancels == 1 and m.fs.disconnects == 0, "Cancel ends the sign-in without signing out")
  check(MUI.spotifyCard() == "signin" and SPOT.status().state == "disconnected", "back to signin")
  -- sign in, finish in the browser: "Signed in as", account card
  m.mock.frames(40)
  press(m, "music.link", 2)
  m.fs.link(true, "Bee")
  m.mock.frames(3)
  check(MUI.spotifyCard() == "account", "card: account")
  check(MUI.status() == "Signed in as Bee", "says who signed in: " .. tostring(MUI.status()))
  -- the help link opens the guide (and cancels the sign-in)
  m.fs.setStatus{state = "disconnected", linked = false}
  m.mock.frames(40)
  press(m, "music.link", 2)
  m.mock.frame(16)
  m.mock.frames(40)
  local cancels = m.fs.cancels
  check(press(m, "music.wait.help", 2), "click the help link")
  check(m.fs.cancels == cancels + 1 and MUI.guideOpen(), "help: cancel and open the guide")
  noErrors(m, "1")
end

-- 2. No Client ID at all (a build without the shared app): the setup card and the guide's three steps.
do
  local m = v14{app = nil, builtin = false}
  local MUI, SPOT, U = m.ns.MUI, m.ns.SPOT, m.ns.U
  check(select(2, SPOT.available()) == "no-client-id", "available: no-client-id")
  openMusicTab(m)
  check(MUI.spotifyCard() == "setup", "card: setup (" .. MUI.spotifyCard() .. ")")
  check(has(m, "Set up Spotify") and has(m, "about two minutes") and has(m, "Set up my Spotify app"), "setup texts")
  check(not has(m, "not on the shared app's list") and regions(m)["music.shared"] == nil, "no shared-app wording")
  check(press(m, "music.setupapp"), "click Set up my Spotify app")
  check(MUI.guideOpen() and MUI.modalOpen(), "the guide opens")
  m.mock.frames(40)
  check(has(m, "Use your own Spotify app") and has(m, "Three steps:") and has(m, "Create a free app")
    and has(m, "Add this Redirect URI") and has(m, "Paste your Client ID"), "the guide's texts")
  check(has(m, "http://127.0.0.1:8780/callback"), "the Redirect URI shows")
  check(regions(m)["music.guide"] and regions(m)["music.setupapp"] == nil and regions(m)["music.ownapp"] == nil
    and regions(m)["music.guide.shared"] == nil,
    "the modal covers the card; no shared link without a shared app")
  for _, id in ipairs{"music.guide.open", "music.guide.copy", "music.guide.id", "music.guide.paste",
    "music.guide.save", "music.guide.close"} do
    local r = regions(m)[id]
    check(r ~= nil and (r.x1 - r.x0) * (r.y1 - r.y0) <= 1920 * 1080 / 4, id .. " is a small region")
  end
  -- step 1
  check(press(m, "music.guide.open"), "click Open Spotify for Developers")
  check(m.fs.dashboards == 1 and m.fs.gestureUntil < 0, "the dashboard opened; the click was used up")
  m.mock.frame()
  check(has(m, "Opened in your browser"), "step 1 says it opened")
  -- step 2
  check(press(m, "music.guide.copy"), "click Copy")
  check(m.fs.copies == 1 and m.fs.clipboard == "http://127.0.0.1:8780/callback", "the URI copied")
  m.mock.frame()
  check(textIs(m, "Copied"), "the button says Copied")
  m.mock.frames(150)
  check(textIs(m, "Copy") and not textIs(m, "Copied"), "and Copy again after 2 s")
  -- a click Melange did not see: "Click the button again"
  clickRegion(m, "music.guide.copy")
  m.fs.gesture(false)
  m.mock.frame()
  check(m.fs.copies == 1 and MUI.guide().err == "Click the button again", "gesture: " .. tostring(MUI.guide().err))
  m.mock.frame()
  check(has(m, "Click the button again"), "the gesture text shows")
  -- step 3: 31 characters leave Save disabled
  press(m, "music.guide.id")
  check(MUI.guide().box.focused and m.mock.focused(), "the box takes the keyboard")
  typeText(m, ID:sub(1, 31))
  check(MUI.guide().box.text == ID:sub(1, 31), "typed")
  local connects = m.fs.connects
  press(m, "music.guide.save")
  check(#m.fs.clientIds == 0 and m.fs.connects == connects and MUI.guideOpen(), "31 characters: Save does nothing")
  -- 32: Save and sign in
  press(m, "music.guide.id")
  m.mock.emitNow("melange.input.key", {key = "END", down = true})
  typeText(m, ID:sub(32))
  check(MUI.guide().box.text == ID, "32 characters")
  check(press(m, "music.guide.save", 3), "click Save and sign in")
  check(m.fs.clientIds[1] == ID, "setClientId got the ID")
  check(m.fs.connects == connects + 1, "connect from the same click")
  check(not MUI.guideOpen(), "the guide closed")
  check(m.fs.app == "user" and MUI.spotifyCard() == "waiting", "the user's app; waiting for the browser")
  m.mock.frame()
  check(has(m, "Spotify says the redirect URI is wrong?") == false, "no help yet")
  m.mock.frame(16)
  m.mock.frames(2)
  check(has(m, "Spotify says the redirect URI is wrong?") and has(m, "Check the setup"), "own-app help wording")
  check(U.pref("spotifyOwnApp") == nil, "no own-app flag")
  noErrors(m, "2")
end

-- 2b. Paste: an ID found on the clipboard fills the box and saves; junk says so; Ctrl+V and Enter in the box.
do
  local m = v14{app = "builtin", clipboard = "Client ID: " .. ID .. "\r\n"}
  local MUI, SPOT = m.ns.MUI, m.ns.SPOT
  openMusicTab(m)
  check(press(m, "music.ownapp"), "click Use my own Spotify app")
  check(MUI.guideOpen(), "the guide opens from the sign-in card")
  m.mock.frames(40)
  check(has(m, "32 letters and digits"), "the placeholder")
  check(regions(m)["music.guide.shared"] == nil, "the shared app is in use: no shared link")
  local connects = m.fs.connects
  check(press(m, "music.guide.paste", 3), "click Paste")
  check(m.fs.clientIds[1] == ID and m.fs.connects == connects + 1 and not MUI.guideOpen(),
    "Paste found the ID, saved it and signed in with one click")
  check(m.fs.status.state == "connecting", "the browser sign-in started")
  -- back to the guide while signing in: Cancel, then the user's app (Change app) with junk on the clipboard
  SPOT.cancel()
  m.mock.frames(40)
  check(MUI.spotifyCard() == "signin" and has(m, "Using your own Spotify app, ID ending " .. ID:sub(-4)),
    "the sign-in card names the user's app")
  check(has(m, "Change app"), "Change app link")
  press(m, "music.ownapp")
  m.mock.frames(40)
  check(has(m, "yours ends " .. ID:sub(-4)), "the placeholder names the saved ID's end")
  check(regions(m)["music.guide.shared"] ~= nil and has(m, "Use the shared app instead"), "the shared app link")
  m.fs.clipboard = "hello " .. string.rep("x", 31) .. " world"
  local n = #m.fs.clientIds
  press(m, "music.guide.paste")
  check(#m.fs.clientIds == n and MUI.guideOpen(), "junk: nothing saved")
  check(MUI.guide().err == SPOT.WHY.clipboard, "junk: " .. tostring(MUI.guide().err))
  m.mock.frame()
  check(has(m, "No Client ID on the clipboard"), "junk: the reason shows")
  -- two IDs on the clipboard are ambiguous
  m.fs.clipboard = ID .. " " .. ID:lower()
  press(m, "music.guide.paste")
  check(#m.fs.clientIds == n, "two candidates: nothing")
  -- Ctrl+V in the box (Melange's paste event), then Enter
  press(m, "music.guide.id")
  m.mock.emitNow("melange.input.paste", {text = "  " .. ID:upper() .. "\n"})
  m.mock.frame()
  check(MUI.guide().err == nil, "typing clears the error")
  m.mock.emitNow("melange.input.key", {key = "RETURN", down = true})
  m.mock.frames(2)
  check(m.fs.clientIds[#m.fs.clientIds] == ID:upper(), "Enter saves the pasted ID (trimmed)")
  check(not MUI.guideOpen(), "and closes the guide")
  -- the shared app instead
  m.fs.setStatus{state = "disconnected"}
  m.mock.frames(2)
  MUI.openGuide()
  m.mock.frames(40)
  check(press(m, "music.guide.shared", 2), "click Use the shared app instead")
  check(m.fs.clientIds[#m.fs.clientIds] == false and m.fs.app == "builtin" and not MUI.guideOpen(),
    "cleared: the shared app again")
  check(MUI.status() == "Using the shared Spotify app", "says so")
  noErrors(m, "2b")
end

-- 3. The shared app refuses this account: own-app flag, setup card, the guide opens by itself, "Try again".
do
  local m = v14{app = "builtin"}
  local MUI, SPOT, U = m.ns.MUI, m.ns.SPOT, m.ns.U
  openMusicTab(m)
  m.fs.notAllowlisted()
  m.mock.frame()
  check(SPOT.status().error == "not-allowlisted" and SPOT.status().app == "builtin", "status: not-allowlisted, builtin")
  check(U.pref("spotifyOwnApp") == true, "the own-app flag is remembered")
  check(MUI.guideOpen(), "the guide opens by itself on the Music tab")
  m.mock.frame()
  check(has(m, "not on the shared app's list"), "the guide says why")
  MUI.closeGuide()
  m.mock.frames(40)
  check(MUI.spotifyCard() == "setup", "card: setup")
  check(has(m, "Your Spotify account is not on the shared app's list.") and has(m, "Set up my Spotify app"),
    "the setup card explains")
  check(regions(m)["music.shared"] ~= nil and has(m, "Try the shared app again"), "Try the shared app again")
  check(press(m, "music.shared", 2), "click it")
  check(U.pref("spotifyOwnApp") == nil and m.fs.cancels == 1 and SPOT.status().state == "disconnected",
    "flag cleared, error cleared")
  check(MUI.spotifyCard() == "signin", "card: signin")
  -- the flag outlives the error (a restart): still the setup card
  U.setPref("spotifyOwnApp", true)
  m.mock.frame()
  check(MUI.spotifyCard() == "setup", "flag alone: setup")
  -- a sign-in clears it
  m.fs.link(true, "Bee")
  m.mock.frame()
  check(U.pref("spotifyOwnApp") == nil, "a sign-in clears the flag")
  noErrors(m, "3")
end

-- 3b. Not on the Music tab: no guide pops up. The user's own app refusing the account: User Management.
do
  local m = v14{app = "builtin"}
  m.fs.notAllowlisted()
  m.mock.frame()
  check(not m.ns.MUI.guideOpen() and m.ns.U.pref("spotifyOwnApp") == true, "panel closed: flag only")
  local m2 = v14{app = "user"}
  local MUI, U = m2.ns.MUI, m2.ns.U
  openMusicTab(m2)
  m2.fs.notAllowlisted()
  m2.mock.frames(2)
  check(U.pref("spotifyOwnApp") == nil and not MUI.guideOpen(), "own app: no flag, no guide")
  check(MUI.spotifyCard() == "signin" and has(m2, "add it under User Management"), "own app: the User Management text")
  noErrors(m2, "3b")
end

-- 4. The account card: initial, plan badge, app line, Sign out.
do
  local m = v14{app = "builtin"}
  local MUI = m.ns.MUI
  m.fs.link(true, "bee")
  m.mock.frame()
  openMusicTab(m)
  check(MUI.spotifyCard() == "account", "card: account")
  check(textIs(m, "B") and textIs(m, "bee"), "the avatar's initial and the name")
  check(textIs(m, "Premium") and not textIs(m, "Free"), "Premium badge")
  check(has(m, "Shared Spotify app") and regions(m)["music.changeapp"] ~= nil, "app line and Change app")
  check(has(m, "Plays on") and regions(m)["music.device"] ~= nil, "Plays on and the device button")
  check(regions(m)["music.browse"] ~= nil and regions(m)["music.unlink"] ~= nil, "browse and Sign out")
  m.fs.setStatus{premium = false}
  m.mock.frames(2)
  check(textIs(m, "Free") and has(m, "Free account: you see what plays"), "Free badge and warning")
  m.fs.status.premium = nil
  m.fs.setStatus{}
  m.mock.frames(2)
  check(has(m, "Plan not known yet") and not textIs(m, "Free") and not textIs(m, "Premium"), "plan not known")
  -- a long name is cut, not spilled
  m.fs.setStatus{user = string.rep("W", 40)}
  m.mock.frames(2)
  local cut = false
  for _, c in ipairs(m.mock.drawOf("hudText")) do
    if c.args[3] == string.rep("W", 40) then cut = c.args[6] and c.args[6].maxWidth ~= nil and c.args[6].ellipsis end
  end
  check(cut, "a long name gets a maxWidth and an ellipsis")
  -- hover on the Sign out link underlines it
  local r = regions(m)["music.unlink"]
  m.mock.cursorPos = {(r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2}
  m.mock.frame()
  check(#m.mock.drawOf("hudLine") > 0, "hovered link underlined")
  check(press(m, "music.changeapp"), "click Change app")
  check(MUI.guideOpen(), "Change app opens the guide")
  m.mock.frame()
  check(has(m, "Saving a different app signs you out of Spotify here."), "the guide warns while signed in")
  MUI.closeGuide()
  m.mock.frames(40)
  check(press(m, "music.unlink", 2), "click Sign out")
  check(m.fs.disconnects == 1 and MUI.spotifyCard() == "signin", "signed out")
  noErrors(m, "4")
end

-- 5. The device picker: rows, restricted rows, transfer, remembering, empty list, Refresh.
do
  local m = v14{app = "builtin"}
  local MUI, SPOT, U, MUSIC = m.ns.MUI, m.ns.SPOT, m.ns.U, m.ns.MUSIC
  m.fs.devices = {
    {id = "pc1", name = "DESKTOP", type = "Computer", active = true, restricted = false, volume = 60},
    {id = "ph1", name = "Bee's phone", type = "Smartphone", active = false, restricted = false},
    {id = "tv1", name = "Living room TV", type = "TV", active = false, restricted = true},
    {id = "web1", name = "Web Player (Chrome)", type = "Computer", active = false, restricted = false, private = true},
    {id = "xb1", name = string.rep("Very long console name ", 4), type = "GameConsole", active = false},
  }
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  openMusicTab(m)
  check(has(m, "Choose a device") or has(m, "DESKTOP"), "the device button names something")
  check(press(m, "music.device", 6), "click the device button")
  check(MUI.devicesOpen() and MUI.modalOpen() and not MUI.libOpen(), "the picker opens")
  m.mock.frames(40)
  check(has(m, "Play music on") and has(m, "signed in as Bee"), "title and subtitle")
  local rg = regions(m)
  check(rg["music.dev.r.pc1"] and rg["music.dev.r.ph1"] and rg["music.dev.r.web1"] and rg["music.dev.r.xb1"],
    "a row region per usable device")
  check(rg["music.dev.r.tv1"] == nil, "a restricted device has no region")
  check(has(m, "Spotify does not let apps control this device"), "restricted explained")
  check(has(m, "Computer · Playing now") and has(m, "Phone") and has(m, "Private session") and has(m, "Console"),
    "type labels, active and private")
  check(#m.mock.drawOf("hudLine") > 0 and #m.mock.drawOf("hudRect") > 0, "device glyphs drawn")
  -- pick the phone; nothing plays here, so play = false
  check(MUSIC.audible() == false, "nothing audible")
  check(press(m, "music.dev.r.ph1"), "click the phone")
  local tr = m.fs.callsOf("transfer")
  check(#tr == 1 and tr[1].args[1].deviceId == "ph1" and tr[1].args[1].play == false, "transfer to the phone, play false")
  check(MUI.devicesState().pending == "ph1", "pending while Spotify answers")
  m.mock.frames(6)
  check(U.pref("spotifyDevice") == "ph1" and U.pref("spotifyDeviceName") == "Bee's phone", "both prefs saved")
  check(MUI.status() == "The party's music will play on Bee's phone", "status: " .. tostring(MUI.status()))
  local nDev = #m.fs.callsOf("devices")
  m.mock.frames(100)                     -- the listing 1.5 s after a move
  check(#m.fs.callsOf("devices") > nDev, "devices listed again after the move")
  check(has(m, "Phone · Playing now"), "the phone now plays")
  MUI.closeDevices()
  m.mock.frames(2)
  check(has(m, "Bee's phone"), "the device button shows the chosen phone")
  -- with the party's music audible: play = true, "Now playing on"
  MUSIC.add({FS.song(1)})
  MUSIC.toggle()
  m.mock.frames(30)
  check(MUSIC.audible(), "the party's music plays here")
  press(m, "music.device", 6)
  m.mock.frames(40)
  press(m, "music.dev.r.pc1", 6)
  tr = m.fs.callsOf("transfer")
  check(#tr == 2 and tr[2].args[1].deviceId == "pc1" and tr[2].args[1].play == true, "transfer to the PC, play true")
  check(MUI.status() == "Now playing on DESKTOP", "status: " .. tostring(MUI.status()))
  check(m.fs.player.device.id == "pc1" and m.fs.player.playing, "the music moved")
  m.mock.frames(200)
  check(not MUSIC.detached(), "the move is not a takeover")
  -- a device that went away; a Free account
  m.fs.devices[2].id = "gone"
  m.mock.frames(40)
  press(m, "music.dev.r.ph1", 6)
  check(MUI.status() == "That device went away; press Refresh", "not-found: " .. tostring(MUI.status()))
  -- empty list and Refresh
  m.fs.devices = {}
  local n = #m.fs.callsOf("devices")
  m.mock.frames(10)
  check(press(m, "music.dev.refresh", 6), "click Refresh")
  check(#m.fs.callsOf("devices") > n, "Refresh lists the devices")
  check(has(m, "No devices found") and has(m, "then press Refresh"), "the empty list explains")
  -- the picker refreshes by itself every 10 s
  n = #m.fs.callsOf("devices")
  m.mock.frame(10.5)
  m.mock.frames(2)
  check(#m.fs.callsOf("devices") == n + 1, "refreshed after 10 s")
  check(press(m, "music.dev.close"), "close")
  check(not MUI.devicesOpen(), "closed")
  -- one modal at a time
  MUI.openDevices()
  MUI.openLibrary()
  check(MUI.libOpen() and not MUI.devicesOpen(), "the library closes the picker")
  MUI.openGuide()
  check(MUI.guideOpen() and not MUI.libOpen(), "the guide closes the library")
  m.ns.SETUP.setTab("videos")
  check(not MUI.modalOpen(), "leaving the Music tab closes the modal")
  noErrors(m, "5")
end

-- 5b. Free accounts: a move needs Premium; the pick is still remembered.
do
  local m = v14{app = "builtin"}
  local MUI, U = m.ns.MUI, m.ns.U
  m.fs.devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = true},
    {id = "ph1", name = "Phone", type = "Smartphone", active = false}}
  m.fs.link(false, "Bee")
  m.mock.frames(10)
  openMusicTab(m)
  MUI.openDevices()
  m.mock.frames(40)
  press(m, "music.dev.r.ph1", 6)
  check(MUI.status() == "Moving the music needs Spotify Premium" and U.pref("spotifyDevice") == "ph1",
    "premium: remembered, explained")
  noErrors(m, "5b")
end

-- 6. Melange 0.13: Holo 1.1's sign-in block, no re-open, no help, no guide; picking a device only remembers it.
do
  local m = machine({})
  local MUI, SPOT, U = m.ns.MUI, m.ns.SPOT, m.ns.U
  check(not SPOT.hasSetup() and not SPOT.hasTransfer() and SPOT.setup() == nil, "0.13: no setup surface")
  check(select(2, SPOT.copyRedirect()) == "old-melange" and select(2, SPOT.pasteClientId()) == "old-melange"
    and select(2, SPOT.transfer("pc1")) == "old-melange", "0.13: old-melange")
  openMusicTab(m)
  check(MUI.spotifyCard() == "signin", "card: signin")
  check(has(m, "Link your Spotify account") and has(m, "Link Spotify"), "the 1.1 consent and Link Spotify")
  check(regions(m)["music.ownapp"] == nil and not has(m, "Sign in with Spotify"), "no own-app link")
  check(MUI.openGuide() == false and not MUI.guideOpen(), "no guide on 0.13")
  press(m, "music.link", 2)
  check(MUI.spotifyCard() == "waiting" and regions(m)["music.reopen"] == nil, "waiting without re-open")
  m.mock.frame(16)
  m.mock.frames(2)
  check(regions(m)["music.wait.help"] == nil, "no help link on 0.13")
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  check(MUI.spotifyCard() == "account" and regions(m)["music.changeapp"] == nil and not has(m, "Shared Spotify app"),
    "the account card without the app line")
  check(#m.fs.callsOf("devices") == 0, "0.13: no device listing at sign-in")
  m.mock.frames(40)
  press(m, "music.device", 6)
  m.mock.frames(40)
  check(MUI.devicesOpen() and regions(m)["music.dev.r.pc1"] ~= nil, "the picker works on 0.13")
  press(m, "music.dev.r.pc1", 2)
  check(#m.fs.callsOf("transfer") == 0 and U.pref("spotifyDevice") == "pc1" and U.pref("spotifyDeviceName") == "DESKTOP",
    "0.13: remembered, no transfer")
  check(MUI.status() == "The party's music will play on DESKTOP from the next song", "0.13 text: "
    .. tostring(MUI.status()))
  -- the legacy no-client-id text
  local m2 = machine({why = "no-client-id"})
  openMusicTab(m2)
  check(m2.ns.MUI.spotifyCard() == "unavailable" and has(m2, "update Melange to 0.14"), "0.13 no-client-id text")
  noErrors(m, "6")
end

-- 7. Melange 0.12: the old card, no Spotify controls, nothing new called.
do
  local m = machine(nil)
  local MUI = m.ns.MUI
  openMusicTab(m)
  check(MUI.spotifyCard() == "old" and has(m, "Melange 0.13.0 or later"), "the old card")
  for id in pairs(regions(m)) do
    check(not (id:find("^music%.link") or id:find("^music%.guide") or id:find("^music%.dev") or id == "music.device"
      or id == "music.ownapp" or id == "music.unlink"), "no Spotify region: " .. id)
  end
  check(MUI.openGuide() == false, "no guide")
  check(m.ns.SPOT.setup() == nil and m.ns.SPOT.cancel() == nil, "setup nil, cancel nothing")
  noErrors(m, "7")
end

-- 8. After a sign-in with one usable device and none chosen, that device is remembered (nothing is moved).
do
  local m = v14{app = "builtin"}
  local U, SPOT = m.ns.U, m.ns.SPOT
  m.fs.devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = false},
    {id = "tv1", name = "TV", type = "TV", active = false, restricted = true}}
  local signed
  U.on("spot.signedIn", function(user) signed = user end)
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  check(signed == "Bee", "spot.signedIn")
  check(U.pref("spotifyDevice") == "pc1" and U.pref("spotifyDeviceName") == "DESKTOP", "the one device is remembered")
  check(#m.fs.callsOf("transfer") == 0 and #m.fs.callsOf("devices") == 1, "listed once, nothing moved")
  check(SPOT.deviceList().items[1].kind == "computer" and SPOT.deviceList().items[2].label == "TV", "the device model")
  -- two usable devices: nothing chosen
  local m2 = v14{app = "builtin"}
  m2.fs.devices = {{id = "pc1", name = "DESKTOP", type = "Computer"}, {id = "ph1", name = "Phone", type = "Smartphone"}}
  m2.fs.link(true, "Bee")
  m2.mock.frames(10)
  check(m2.ns.SPOT.chosen() == nil, "two devices: none chosen")
  -- an existing choice is kept
  local m3 = v14{app = "builtin"}
  m3.ns.SPOT.choose({id = "old", name = "Old PC"})
  m3.fs.link(true, "Bee")
  m3.mock.frames(10)
  check(m3.ns.SPOT.chosen() == "old", "a chosen device is kept")
  -- signing out forgets the listing
  m.fs.setStatus{state = "disconnected", linked = false}
  m.mock.frame()
  check(#SPOT.deviceList().items == 0, "signed out: the listing is forgotten")
  noErrors(m, "8")
end

-- 9. The adapter's pieces: kinds and labels, setup() cleaning and its cache, the new reasons.
do
  local m = v14{app = "ini"}
  local SPOT = m.ns.SPOT
  local kinds = {Computer = "computer", Smartphone = "phone", Tablet = "phone", Speaker = "speaker", AVR = "speaker",
    AudioDongle = "speaker", CastAudio = "speaker", TV = "tv", STB = "tv", CastVideo = "tv", GameConsole = "console",
    Automobile = "car", Unknown = "device", Fridge = "device"}
  for t, k in pairs(kinds) do check(SPOT.kindOf(t) == k, "kindOf " .. t) end
  check(SPOT.typeLabel("AVR") == "Receiver" and SPOT.typeLabel("CastVideo") == "Chromecast"
    and SPOT.typeLabel("STB") == "TV box" and SPOT.typeLabel("x") == "Device", "typeLabel")
  local items = SPOT.normDevices({{id = "a", name = "", type = 5}, {id = nil, name = "x"}, {id = "b", name = "B",
    type = "Speaker", private = true, volume = 40}})
  check(#items == 2 and items[1].name == "Unnamed device" and items[1].type == "Unknown" and items[2].private
    and items[2].volume == 40 and items[2].kind == "speaker", "normDevices")
  check(SPOT.status().app == "ini" and SPOT.setup().app == "ini", "app from the status and setup")
  -- a bad Redirect URI falls back; the cache holds for 1 s and drops on an event
  local real = m.wum.spotify.setup
  m.wum.spotify.setup = function()
    local t = real()
    t.redirectUri, t.app, t.appHint = "javascript:alert(1)", "weird", 1234
    return t
  end
  check(SPOT.setup().app == "ini", "cached for a second")
  m.mock.frame(1.1)
  local su = SPOT.setup()
  check(su.redirectUri == "http://127.0.0.1:8780/callback" and su.app == nil and su.appHint == nil, "cleaned")
  m.wum.spotify.setup = function() error("boom") end
  m.mock.frame(1.1)
  check(SPOT.setup() == nil, "a raising setup() is nil")
  m.wum.spotify.setup = real
  for _, r in ipairs{"not-allowlisted", "clipboard", "io", "gesture", "no-client-id"} do
    check(type(SPOT.WHY[r]) == "string" and #SPOT.WHY[r] > 5, "SPOT.WHY[" .. r .. "]")
  end
  check(SPOT.WHY.gesture == "Click the button again", "gesture text")
  -- setClientId's reasons come back
  check(select(2, SPOT.setClientId(ID)) == "gesture", "no click: gesture")
  m.fs.gesture(true)
  check(select(2, SPOT.setClientId("short")) == "invalid", "invalid")
  m.fs.setClientIdWhy = "io"
  check(select(2, SPOT.setClientId(ID)) == "io", "io")
  noErrors(m, "9")
end

-- 10. Review regressions.
-- 10a. The guide's fallback link: clearing the in-game ID falls back to Melange.ini's app before the shared one, and
-- an ini app (which the game cannot clear) gets no link that would do nothing.
do
  local m = v14{app = "user", ini = true, builtin = true}
  local MUI, SPOT = m.ns.MUI, m.ns.SPOT
  openMusicTab(m)
  MUI.openGuide()
  m.mock.frames(40)
  check(has(m, "Use the app from Melange.ini") and not has(m, "Use the shared app instead"),
    "user app over an ini one: the link names Melange.ini")
  check(press(m, "music.guide.shared", 2), "click it")
  check(m.fs.clientIds[#m.fs.clientIds] == false and m.fs.app == "ini" and not MUI.guideOpen(), "cleared: ini again")
  check(MUI.status() == "Using the Spotify app from Melange.ini", "says the ini app: " .. tostring(MUI.status()))
  -- now the ini app is in use: clearing would change nothing, so no link
  MUI.openGuide()
  m.mock.frames(40)
  check(regions(m)["music.guide.shared"] == nil and not has(m, "Use the shared app instead"),
    "ini app in use: no fallback link")
  local m2 = v14{app = "user", ini = false, builtin = false}
  m2.ns.MUI.openGuide()
  openMusicTab(m2)
  check(regions(m2)["music.guide.shared"] == nil, "no ini, no shared app: no fallback link")
  noErrors(m, "10a")
end

-- 10b. Device answers speak of devices: "rate" and "invalid" are not the song queue's texts, and a listing that fails
-- with "rate" says to wait (Holo does not retry a move by itself).
do
  local m = v14{app = "builtin"}
  local MUI = m.ns.MUI
  m.fs.devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = true},
    {id = "ph1", name = "Phone", type = "Smartphone", active = false}}
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  openMusicTab(m)
  MUI.openDevices()
  m.mock.frames(40)
  m.fs.respond.transfer = function() return {error = "rate", retryAfter = 3} end
  press(m, "music.dev.r.ph1", 6)
  check(MUI.status() == "Spotify asks to slow down; try again in a moment", "transfer rate: " .. tostring(MUI.status()))
  check(MUI.devicesState().pending == nil and m.ns.U.pref("spotifyDevice") ~= "ph1", "not moved, not pending")
  check(MUI.devWhy("invalid") == "Spotify cannot use that device", "invalid: a device text")
  check(not MUI.devWhy("rate"):find("adding", 1, true), "rate: not the song queue's text")
  m.fs.respond.devices = function() return {error = "rate", retryAfter = 3} end
  m.fs.devices = {}
  m.ns.SPOT.forgetDevices()
  press(m, "music.dev.refresh", 6)
  m.mock.frames(2)
  check(has(m, "Spotify asks to slow down; try again in a moment") and not has(m, "before adding again"),
    "a failed listing: the device text")
  noErrors(m, "10b")
end

-- 10c. The shared app's busy ports: [Spotify] RedirectPort does not apply to it; a user app keeps that advice. The
-- shared app refusing the Client ID points to the user's own app, not to Melange.ini.
do
  local m = v14{app = "builtin"}
  local MUI = m.ns.MUI
  openMusicTab(m)
  m.fs.connectWhy = "port-busy"
  press(m, "music.link", 2)
  check(MUI.status() == "Ports 8780 to 8782 are all in use by other programs; close one and try again",
    "builtin port-busy: " .. tostring(MUI.status()))
  local m2 = v14{app = "user"}
  openMusicTab(m2)
  m2.fs.connectWhy = "port-busy"
  press(m2, "music.link", 2)
  check(m2.ns.MUI.status() == m2.ns.SPOT.WHY["port-busy"], "user app port-busy: RedirectPort advice")
  check(MUI.errorText({error = "invalid-client", app = "builtin"}):find("own Spotify app", 1, true) ~= nil
    and not MUI.errorText({error = "invalid-client", app = "builtin"}):find("ClientId", 1, true),
    "builtin invalid-client: no ini advice")
  noErrors(m, "10c")
end

-- 10d. Melange 0.13 does not bring the game back after the sign-in: the waiting card does not promise it.
do
  local m = machine({})
  openMusicTab(m)
  press(m, "music.link", 2)
  m.mock.frames(2)
  check(m.ns.MUI.spotifyCard() == "waiting", "0.13 waiting")
  check(has(m, "then come back to the game") and not has(m, "comes back here by itself"), "0.13 waiting text")
  noErrors(m, "10d")
end

-- 10e. A listing that answers between the press and the release cannot turn a click into a move to another device.
do
  local m = v14{app = "builtin"}
  local MUI, SPOT = m.ns.MUI, m.ns.SPOT
  m.fs.devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = true},
    {id = "ph1", name = "Phone", type = "Smartphone", active = false},
    {id = "sp1", name = "Speaker", type = "Speaker", active = false}}
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  openMusicTab(m)
  MUI.openDevices()
  m.mock.frames(40)
  check(clickRegion(m, "music.dev.r.ph1") == "music.dev.r.ph1", "pressed the phone's row")
  local items = SPOT.deviceList().items                -- the new listing, in another order, lands now
  items[2], items[3] = items[3], items[2]
  m.mock.frames(6)
  local tr = m.fs.callsOf("transfer")
  check(#tr == 1 and tr[1].args[1].deviceId == "ph1", "the clicked device moves, not the row's new one")
  check(MUI.deviceRowId({id = string.rep("a", 128)}):len() <= 64, "a long id still makes a valid region id")
  noErrors(m, "10e")
end

-- 10f. Signing out (Sign out, revoked, not allowlisted) closes the device picker; reopening it at once reuses the
-- fresh listing instead of spending a request.
do
  local m = v14{app = "builtin"}
  local MUI = m.ns.MUI
  m.fs.link(true, "Bee")
  m.mock.frames(10)
  openMusicTab(m)
  local n = #m.fs.callsOf("devices")
  MUI.openDevices()
  m.mock.frames(10)
  check(#m.fs.callsOf("devices") == n, "the sign-in's listing is fresh: reused")
  MUI.closeDevices()
  m.mock.frames(240)                                     -- 4 s later
  n = #m.fs.callsOf("devices")
  MUI.openDevices()
  m.mock.frames(10)
  check(#m.fs.callsOf("devices") == n + 1, "an older listing: opening lists the devices")
  MUI.closeDevices()
  MUI.openDevices()
  m.mock.frames(10)
  check(#m.fs.callsOf("devices") == n + 1, "reopening at once reuses the listing")
  m.mock.frames(700)                                     -- the 10 s refresh still runs
  check(#m.fs.callsOf("devices") == n + 2, "refreshed 10 s after the listing: " .. #m.fs.callsOf("devices"))
  m.fs.setStatus{state = "error", error = "revoked", linked = false}   -- Spotify ended the sign-in
  m.mock.frames(2)
  check(not MUI.devicesOpen() and not MUI.guideOpen(), "signed out: the picker closes")
  local after = #m.fs.callsOf("devices")
  m.mock.frames(700)
  check(#m.fs.callsOf("devices") == after, "nothing listed while signed out")
  noErrors(m, "10f")
end

-- 10g. The Client ID box takes the one ID in pasted text ("Client ID 0a1b..."), as Melange's Paste does.
do
  local m = v14{app = "builtin"}
  local MUI = m.ns.MUI
  openMusicTab(m)
  MUI.openGuide()
  m.mock.frames(40)
  press(m, "music.guide.id")
  m.mock.emitNow("melange.input.paste", {text = "Client ID " .. ID})
  m.mock.frames(2)
  check(MUI.idIn(MUI.guide().box.text) == ID, "the ID in the text")
  check(MUI.idIn(ID .. " " .. ID:lower()) == nil and MUI.idIn("x" .. ID) == nil, "two IDs or 33 characters: none")
  m.mock.frames(40)
  local connects = m.fs.connects
  check(press(m, "music.guide.save", 2), "click Save and sign in")
  check(m.fs.clientIds[1] == ID and m.fs.connects == connects + 1, "the found ID is saved and signed in")
  noErrors(m, "10g")
end

-- 10h. Melange 0.12: the chip does not ask to link Spotify, which that Melange cannot do.
do
  local m = machine(nil)
  m.mock.cursorPos = {5, 500}
  m.ns.MUSIC.addLocal({{uri = FS.uri(1), title = "Song 1", name = "Song 1", artists = "Artist", durationMs = 600000}})
  m.ns.MUSIC.toggle()
  m.mock.frames(10)
  check(has(m, "Song 1"), "the chip shows: " .. texts(m))
  check(has(m, "Listening needs Melange 0.13.0 or later") and not has(m, "to listen"), "0.12 chip text")
  noErrors(m, "10h")
end

-- 10i. A sign-in failure longer than the Spotify column takes two lines under the card instead of being cut.
do
  local m = v14{app = "user"}
  openMusicTab(m)
  m.fs.connectWhy = "port-busy"
  press(m, "music.link", 2)
  local all = texts(m)
  check(all:find("RedirectPort", 1, true) ~= nil and all:find("Redirect URI", 1, true) ~= nil,
    "the whole reason shows: " .. all)
  -- every drawn piece of it fits the column (a single 14 px line of it would be cut by the core's maxWidth)
  local col = (1920 - 960) / 2 + 960 - 28 - ((1920 - 960) / 2 + 650)
  local pieces = 0
  for _, c in ipairs(m.mock.drawOf("hudText")) do
    local t = tostring(c.args[3])
    if t:find("sign-in port", 1, true) or t:find("Redirect URI", 1, true) then
      pieces = pieces + 1
      check(#t * c.args[5] * 0.5 <= col + 0.5, "fits the column: " .. t)
    end
  end
  check(pieces == 2, "two lines: " .. pieces)
  noErrors(m, "10i")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_spotify_setup: all checks passed")
