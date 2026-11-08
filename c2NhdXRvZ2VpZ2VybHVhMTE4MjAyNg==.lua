local Cfg = {
  WorldGeiger    = "GEIGERB",
  WorldSave      = "OSMORAGEIGER",
  AliveGeigerBG  = 564,
  ItemDropBG     = 558,
  DeadDropBG     = 556,
  MinAliveGeiger = 5,      -- sisa Geiger Counter <= angka ini -> simpan item dulu
  BreakMinutes   = 5,      -- tiap sekian menit karakter dipindah 15 tile (anti macet)
  RingTimeout    = 8,      -- detik maksimal menunggu sinyal ring baru
  GhostFly       = true,
  Webhook        = true,
  WebhookUrl     = "https://discord.com/api/webhooks/1568619719681118219/on3j-Mt2PduT1yigcIbZJqfnDrMinWq-TiqNTgPJb5w3_ZMssWiEovklv1-Lm5jjOMXt",
}

local Defaults = {}
for k, v in pairs(Cfg) do Defaults[k] = v end

-- ===== KONSTANTA =====
local RED, YELLOW, GREEN = 0, 1, 2
local WORLD_MAX = 29                     -- world geiger 30x30
local ALIVE_ID, DEAD_ID = 2204, 2286
local RED_X = { 25, 5, 5, 25, 15, 14 }
local RED_Y = { 5, 25, 5, 25, 25, 3 }
local LOOT_NAMES = {
  "Stuff", "Crystal Black", "Crystal Green", "Crystal Red", "Crystal White",
  "Chemical Haunted", "Chemical Radioactive", "Growtoken", "Battery", "D Battery", "Charger",
}
local DROP_IDS = {
  [2242] = true, [2244] = true, [2246] = true, [2248] = true, [2250] = true,
  [3306] = true, [1962] = true, [2206] = true, [1482] = true,
}
local TRASH_IDS = { [1498] = true, [1500] = true, [2804] = true, [2806] = true, [15250] = true }
local THUMB = "https://cdn.discordapp.com/attachments/1568619668049104916/1568624801445191841/Osmora-Dusk.jpg?ex=6af07f30&is=6aef2db0&hm=a582a0056a4563ba6597640a6578c48eb264d54b2c8a7267e1055ea36f53fb51&"

-- ===== STATE =====
local S = {
  running = false, startRequested = false,
  ring = RED, newRing = false, itemFound = false, canDrop = true,
  alive = 0, totalFound = 0, found = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  lastBreak = 0, ringSeen = 0, warnedNoRing = false, warnedWebhook = false,
  webhookPending = false, playerName = "Unknown", lastX = 0, lastY = 0, flyOn = false,
  pktSeen = 0, typesSeen = {}, dumped = 0, lastPacket = nil,
}

-- ===== HELPER =====
local function Say(msg)
  if type(LogToConsole) == "function" then LogToConsole("`b[GEIGER]`` " .. msg) end
end

-- overlay + console, seperti log() di script asli
local function Log(k)
  if type(SendVariantList) == "function" then
    SendVariantList({ [0] = "OnTextOverlay", [1] = k })
  end
  if type(LogToConsole) == "function" then LogToConsole(k) end
end

local function toint(v)
  return math.floor(tonumber(v) or 0)
end

local function truthy(v)
  return v == true or v == 1 or v == "1" or v == "true"
end

local function jesc(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function siz(str)
  str = str:gsub("Dr%.", "")
  str = str:gsub("``", ""):gsub("`.", ""):gsub("@", ""):gsub(" of Legend", "")
  str = str:gsub("%[BOOST%]", ""):gsub("%[ELITE%]", ""):gsub("`w", "")
  return str
end

local function clamp(val, minVal, maxVal)
  return math.max(minVal, math.min(val, maxVal))
end

local function WorldInfo()
  local ok, w = pcall(GetWorld)
  if ok and type(w) == "table" and w.name and w.name ~= "" then return w end
  return nil
end

local function MyPos()
  local ok, me = pcall(GetLocal)
  if not ok or type(me) ~= "table" or not me.pos then return nil, nil end
  local x, y = math.floor(me.pos.x / 32), math.floor(me.pos.y / 32)
  S.lastX, S.lastY = x, y
  return x, y
end

local function PX()
  local x = MyPos()
  return x or S.lastX
end

local function PY()
  local _, y = MyPos()
  return y or S.lastY
end

local function SafeTile(x, y)
  local ok, t = pcall(GetTile, x, y)
  if ok then return t end
  return nil
end

local function GetItemCount(id)
  local ok, list = pcall(GetInventory)
  if not ok or type(list) ~= "table" then return 0 end
  for _, itm in pairs(list) do
    if itm.id == id then return itm.amount end
  end
  return 0
end

local function InventorySnapshot()
  local out = {}
  local ok, list = pcall(GetInventory)
  if ok and type(list) == "table" then
    for _, it in pairs(list) do
      out[#out + 1] = { id = it.id, amount = it.amount }
    end
  end
  return out
end

local function MoveTo(x, y)
  return pcall(FindPath, x, y)
end

local function WaitArrive(x, y, ms)
  local waited = 0
  while waited < ms and S.running do
    local px, py = MyPos()
    if px == x and py == y then return true end
    Sleep(200)
    waited = waited + 200
  end
  local px, py = MyPos()
  return px == x and py == y
end

-- pindah world lewat /warp, ulangi sampai berhasil (atau script dihentikan)
local function GoWorld(name)
  local tries = 0
  while S.running do
    local w = WorldInfo()
    if w and w.name:upper() == name:upper() then return true end
    tries = tries + 1
    if tries == 1 or tries % 6 == 0 then Say("`1Warp ke " .. name .. " (percobaan " .. tries .. ")") end
    pcall(SendPacket, 2, "action|input\n|text|/warp " .. name .. "\n")
    Sleep(5000)
  end
  return false
end

local function Reconnect()
  return GoWorld(Cfg.WorldGeiger)
end

local lastStatus = ""
local function UpdateStatus()
  local w = WorldInfo()
  local s = (S.running and "Running" or "Stopped") ..
            " | Found " .. S.totalFound ..
            " | Geiger " .. S.alive ..
            " | " .. (w and w.name or "offline")
  if s ~= lastStatus then
    lastStatus = s
    UI.Set("status", { text = s })
  end
end

-- cetak isi paket (untuk mencari nama field yang benar di CGT)
local function DumpPacket(p)
  local keys = {}
  for k, v in pairs(p) do
    local tv = type(v)
    if tv == "number" or tv == "string" or tv == "boolean" then
      keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  table.sort(keys)
  while #keys > 25 do table.remove(keys) end
  return table.concat(keys, ", ")
end

local function TypesSummary()
  local arr = {}
  for ty, n in pairs(S.typesSeen) do arr[#arr + 1] = { ty = ty, n = n } end
  table.sort(arr, function(a, b) return a.n > b.n end)
  local out = {}
  for i = 1, math.min(#arr, 6) do out[#out + 1] = "type " .. arr[i].ty .. " x" .. arr[i].n end
  return table.concat(out, ", ")
end

-- timer "Break" (pengganti RunThread): pindahkan karakter 15 tile secara vertikal
local function CheckBreak()
  if os.time() - S.lastBreak < Cfg.BreakMinutes * 60 then return false end
  S.lastBreak = os.time()
  Say("`1Break")
  local x, y = MyPos()
  if x then
    if y <= 15 then
      MoveTo(x, clamp(y + 15, 0, WORLD_MAX))
    else
      MoveTo(x, clamp(y - 15, 0, WORLD_MAX))
    end
  end
  return true
end

-- tunggu sinyal ring baru (dengan batas waktu supaya tidak hang kalau FindPath gagal)
local function RenewRing()
  local t0 = os.time()
  while not S.newRing and S.running do
    if not Reconnect() then return end
    Sleep(500)
    UpdateStatus()
    if os.time() - t0 >= Cfg.RingTimeout then
      if S.ringSeen == 0 and not S.warnedNoRing then
        S.warnedNoRing = true
        if S.pktSeen == 0 then
          Say("`4Hook ring tidak menerima paket apa pun (nama hook salah?) atau FindPath tidak menggerakkan karakter.")
        else
          Say("`4Hook menerima " .. S.pktSeen .. " paket tapi tidak ada ring terbaca. " .. TypesSummary())
        end
      end
      break
    end
  end
  S.newRing = false
end

-- ===== PENCARIAN (dari script asli) =====
local function SearchExhausted(cur)
  if cur > WORLD_MAX + 1 then
    Say("`4Pencarian melewati batas world, ulang dari awal")
    S.ring = RED
    return true
  end
  return false
end

-- fase sumbu Y (dipakai yellow dan green)
local function YAxisPhase(startLoc)
  local foundPosX, foundPosY = PX(), PY()
  local currentLoc = startLoc
  local isUp = false
  while true do
    if not S.running then return end
    if CheckBreak() then return end
    if S.itemFound then return end
    if SearchExhausted(currentLoc) then return end
    MoveTo(foundPosX, clamp(foundPosY + currentLoc, 0, WORLD_MAX))
    isUp = false
    RenewRing()
    if S.ring ~= GREEN then break end
    MoveTo(foundPosX, clamp(foundPosY - currentLoc, 0, WORLD_MAX))
    isUp = true
    RenewRing()
    if S.ring ~= GREEN then break end
    currentLoc = currentLoc + 1
  end
  -- Y Green -> Yellow
  if S.ring == YELLOW then
    if not isUp then
      MoveTo(foundPosX, clamp(PY() - 5, 0, WORLD_MAX))
    else
      MoveTo(foundPosX, clamp(PY() + 5, 0, WORLD_MAX))
    end
    Sleep(10000)
  end
end

local function foundYellow()
  local foundPosX, foundPosY = PX(), PY()
  local currentLoc = 2
  local isLeft = false

  while true do
    if not S.running then return end
    if CheckBreak() then return end
    if S.itemFound then return end
    if SearchExhausted(currentLoc) then return end
    MoveTo(clamp(foundPosX + currentLoc, 0, WORLD_MAX), foundPosY)
    isLeft = false
    RenewRing()
    if S.ring ~= YELLOW then break end
    MoveTo(clamp(foundPosX - currentLoc, 0, WORLD_MAX), foundPosY)
    isLeft = true
    RenewRing()
    if S.ring ~= YELLOW then break end
    currentLoc = currentLoc + 2
  end

  -- X Yellow -> Red
  if S.ring == RED then
    if not isLeft then
      MoveTo(clamp(PX() - 12, 0, WORLD_MAX), foundPosY)
    else
      MoveTo(clamp(PX() + 12, 0, WORLD_MAX), foundPosY)
    end
    RenewRing()
    if S.ring ~= GREEN then
      if PY() >= 20 then
        MoveTo(PX(), clamp(PY() - 8, 0, WORLD_MAX))
      else
        MoveTo(PX(), clamp(PY() + 8, 0, WORLD_MAX))
      end
      return
    end
    Sleep(10000)
  -- X Yellow -> Green
  elseif S.ring == GREEN then
    if not isLeft then
      MoveTo(clamp(PX() + 4, 0, WORLD_MAX), foundPosY)
    else
      MoveTo(clamp(PX() - 4, 0, WORLD_MAX), foundPosY)
    end
    Sleep(10000)
  end

  YAxisPhase(1)
end

local function foundGreen()
  local foundPosX, foundPosY = PX(), PY()
  local currentLocX = 1
  local isLeft = false

  while true do
    if not S.running then return end
    if CheckBreak() then return end
    if S.itemFound then return end
    if SearchExhausted(currentLocX) then return end
    MoveTo(clamp(foundPosX + currentLocX, 0, WORLD_MAX), foundPosY)
    isLeft = false
    RenewRing()
    if S.ring ~= GREEN then break end
    MoveTo(clamp(foundPosX - currentLocX, 0, WORLD_MAX), foundPosY)
    isLeft = true
    RenewRing()
    if S.ring ~= GREEN then break end
    currentLocX = currentLocX + 1
  end

  -- X Green -> Yellow
  if S.ring == YELLOW then
    if not isLeft then
      MoveTo(clamp(PX() - 5, 0, WORLD_MAX), foundPosY)
    else
      MoveTo(clamp(PX() + 5, 0, WORLD_MAX), foundPosY)
    end
    Sleep(10000)
  end

  YAxisPhase(1)
end

-- ===== HOOK =====
-- nilai ring ada di pos2_x (Libre) atau xspeed (BotHax): 2.0 = green, 1.0 = yellow, lainnya = red
local function ReadRingValue(p)
  for _, k in ipairs({ "pos2_x", "xspeed", "speed_x" }) do
    local v = tonumber(p[k])
    if v then return v end
  end
  return nil
end

local function ringHook(packet)
  if not S.running or type(packet) ~= "table" then return end
  if packet == S.lastPacket then return end   -- paket sama dari beberapa nama hook
  S.lastPacket = packet
  S.pktSeen = S.pktSeen + 1
  local ty = tostring(packet.type)
  S.typesSeen[ty] = (S.typesSeen[ty] or 0) + 1
  if packet.type ~= 17 then return end

  local xs = ReadRingValue(packet)
  if not xs then
    if S.dumped < 3 then
      S.dumped = S.dumped + 1
      Say("`4Paket type 17 tanpa nilai ring yang dikenal. Isi paket: " .. DumpPacket(packet))
    end
    return
  end

  S.ringSeen = S.ringSeen + 1
  if math.abs(xs - 2.0) < 0.05 then
    Log("`2Green...")
    S.ring = GREEN
  elseif math.abs(xs - 1.0) < 0.05 then
    Log("`9Yellow...")
    S.ring = YELLOW
  else
    Log("`4Red...")
    S.ring = RED
  end
  S.newRing = true
end

local function classify(msg)
  local function has(p) return msg:find(p, 1, true) ~= nil end
  if has("Stuff") then return 1 end
  if has("Crystal") then
    if has("Black") then return 2 end
    if has("Green") then return 3 end
    if has("Red") then return 4 end
    if has("White") then return 5 end
    return nil
  end
  if has("Haunted") then return 6 end
  if has("Radioactive") then return 7 end
  if has("Growtoken") then return 8 end
  if has("`w1 Battery") then return 9 end
  if has("D Battery") then return 10 end
  if has("Charger") then return 11 end
  return nil
end

-- hook ini tidak boleh Sleep dan tidak boleh request jaringan (webhook dikirim dari loop utama)
local function variantHook(var)
  if not S.running or type(var) ~= "table" then return false end
  local ev, v1 = var[0], var[1]
  if type(v1) ~= "string" then return false end
  if ev == "OnConsoleMessage" and v1:find("oGiven", 1, true) then
    local idx = classify(v1)
    if idx then
      S.found[idx] = S.found[idx] + 1
      S.totalFound = S.totalFound + 1
      S.webhookPending = true
    end
    Log(string.format([[
Item Found : %d
Stuff : %d
Crystal Black : %d
Crystal Green : %d
Crystal Red : %d
Crystal White : %d
Chemical Haunted : %d
Chemical Radioactive : %d
Growtoken : %d
Battery : %d
D Battery : %d
Geiger Charger : %d
]], S.totalFound, S.found[1], S.found[2], S.found[3], S.found[4], S.found[5], S.found[6],
      S.found[7], S.found[8], S.found[9], S.found[10], S.found[11]))
    S.itemFound = true
  elseif ev == "OnTextOverlay" and v1:find("You can't drop", 1, true) then
    S.canDrop = false
  end
  return false
end

-- ===== WEBHOOK =====
local function FlushWebhook()
  if not S.webhookPending then return end
  S.webhookPending = false
  if not Cfg.Webhook or Cfg.WebhookUrl == "" then return end
  if type(MakeRequest) ~= "function" then
    if not S.warnedWebhook then
      S.warnedWebhook = true
      Say("`4MakeRequest tidak tersedia, webhook dilewati")
    end
    return
  end
  local items = {}
  for i, name in ipairs(LOOT_NAMES) do
    if S.found[i] > 0 then items[#items + 1] = name .. " : " .. S.found[i] end
  end
  if #items == 0 then return end
  local w = WorldInfo()
  local wname = w and w.name:upper() or Cfg.WorldGeiger:upper()
  local payload = '{"embeds":[{"title":"Geiger Webhook","fields":[' ..
    '{"name":"<a:aOnline:1089435878583173200> Player Name","value":"' .. jesc(S.playerName) .. '","inline":false},' ..
    '{"name":"<:growscan:1210567190022070312> Found Items","value":"' .. table.concat(items, "\\n") .. '","inline":true},' ..
    '{"name":"<:globee:1326955204263805001> World Name","value":"' .. jesc(wname) .. '","inline":true}],' ..
    '"color":11393254,"thumbnail":{"url":"' .. THUMB .. '"}}]}'
  pcall(MakeRequest, Cfg.WebhookUrl, "POST", { ["Content-Type"] = "application/json" }, payload)
end

-- ===== LOKASI DROP BERDASARKAN BACKGROUND ID =====
local function ScanBG(bg)
  local list = {}
  local w = WorldInfo()
  if not w or not bg or bg <= 0 then return list end
  local step = 100
  for cy = 0, w.height - 1, step do
    for cx = 0, w.width - 1, step do
      local cw = math.min(step, w.width - cx)
      local ch = math.min(step, w.height - cy)
      local ok, tiles = pcall(function() return Client.GetTiles(cx, cy, cw, ch) end)
      if ok and type(tiles) == "table" then
        for _, t in ipairs(tiles) do
          if t.bg == bg then list[#list + 1] = { x = t.x, y = t.y, fg = t.fg or 0 } end
        end
      else
        for y = cy, cy + ch - 1 do
          for x = cx, cx + cw - 1 do
            local t = SafeTile(x, y)
            if t and t.bg == bg then list[#list + 1] = { x = x, y = y, fg = t.fg or 0 } end
          end
        end
      end
    end
  end
  -- tile kosong dulu, lalu dari atas ke bawah, dan dari kanan ke kiri (seperti script asli)
  table.sort(list, function(a, b)
    local af = (a.fg == 0) and 0 or 1
    local bf = (b.fg == 0) and 0 or 1
    if af ~= bf then return af < bf end
    if a.y ~= b.y then return a.y < b.y end
    return a.x > b.x
  end)
  return list
end

-- jatuhkan semua item yang cocok dengan match(id); pindah ke tile berikutnya kalau penuh
local function DropGroup(tiles, match, label)
  local idx = 1
  while S.running do
    if not WorldInfo() then return false end
    local todo = {}
    for _, it in ipairs(InventorySnapshot()) do
      if match(it.id) and it.amount > 0 then todo[#todo + 1] = it end
    end
    if #todo == 0 then return true end

    local tile = tiles[idx]
    if not tile then
      Log("`4Area drop " .. label .. " penuh / tidak cukup tile")
      return false
    end

    MoveTo(tile.x, tile.y)
    if not WaitArrive(tile.x, tile.y, 4000) then
      idx = idx + 1
    else
      Sleep(500)
      for _, it in ipairs(todo) do
        S.canDrop = true
        local before = GetItemCount(it.id)
        pcall(SendPacket, 2, "action|dialog_return\ndialog_name|drop\nitem_drop|" .. it.id ..
          "|\nitem_count|" .. it.amount .. "\n")
        Sleep(700)
        if not S.canDrop or GetItemCount(it.id) >= before then
          idx = idx + 1   -- tile ini penuh, coba tile berikutnya
          break
        end
      end
    end
  end
  return false
end

local function TrashJunk()
  for _, it in ipairs(InventorySnapshot()) do
    if TRASH_IDS[it.id] and it.amount > 0 then
      pcall(SendPacket, 2, "action|dialog_return\ndialog_name|trash\nitem_trash|" .. it.id ..
        "|\nitem_count|" .. it.amount .. "\n")
      Sleep(500)
    end
  end
end

-- ambil Geiger Counter hidup: berjalan di atas tile ber-background AliveGeigerBG
local function PickupAlive()
  if Cfg.AliveGeigerBG <= 0 then return end
  local tiles = ScanBG(Cfg.AliveGeigerBG)
  if #tiles == 0 then
    Log("`4Tidak ada tile dengan AliveGeigerBG " .. Cfg.AliveGeigerBG .. " di " .. Cfg.WorldSave)
    return
  end
  for i, t in ipairs(tiles) do
    if not S.running or i > 40 then break end
    MoveTo(t.x, t.y)
    WaitArrive(t.x, t.y, 4000)
    Sleep(1500)
  end
  Say("`1Geiger Counter sekarang: " .. GetItemCount(ALIVE_ID))
end

-- simpan loot ke world save, lalu kembali ke world geiger
local function SaveLoot()
  Log("`9Menyimpan item di " .. Cfg.WorldSave)
  if not GoWorld(Cfg.WorldSave) then return false end
  Sleep(3000)

  PickupAlive()

  local itemTiles = ScanBG(Cfg.ItemDropBG)
  local deadTiles = itemTiles
  if Cfg.DeadDropBG > 0 then deadTiles = ScanBG(Cfg.DeadDropBG) end
  Say(string.format("`1Area drop: item %d tile, dead geiger %d tile", #itemTiles, #deadTiles))

  local ok = true
  if #itemTiles == 0 then
    Log("`4Tidak ada tile dengan ItemDropBG " .. Cfg.ItemDropBG .. " di " .. Cfg.WorldSave)
    ok = false
  else
    TrashJunk()
    if not DropGroup(itemTiles, function(id) return DROP_IDS[id] == true end, "item") then ok = false end
    if #deadTiles == 0 then
      Log("`4Tidak ada tile dengan DeadDropBG " .. Cfg.DeadDropBG .. " di " .. Cfg.WorldSave)
      ok = false
    elseif not DropGroup(deadTiles, function(id) return id == DEAD_ID end, "dead geiger") then
      ok = false
    end
  end

  GoWorld(Cfg.WorldGeiger)
  return ok
end

-- ===== LOOP UTAMA =====
local function RunGeiger()
  local w = WorldInfo()
  if not w then
    Log("`4Masuk ke world dulu")
    return
  end
  if Cfg.ItemDropBG <= 0 then
    Log("`4Isi ItemDropBG dulu (background tile tempat drop item)")
    return
  end

  local okMe, me = pcall(GetLocal)
  local nm = okMe and type(me) == "table" and me.name or "Unknown"
  S.playerName = siz(tostring(nm)):match("%S+") or "Unknown"

  S.ring, S.newRing, S.itemFound = RED, false, false
  S.ringSeen, S.warnedNoRing, S.webhookPending = 0, false, false
  S.pktSeen, S.typesSeen, S.dumped, S.lastPacket = 0, {}, 0, nil
  S.lastBreak = os.time()
  S.alive = GetItemCount(ALIVE_ID)
  if S.alive <= 0 then
    Log("`4Tidak ada Geiger Counter di inventory")
    return
  end

  if Cfg.GhostFly then
    local ok = pcall(EditToggle, "Ghost Fly", true)
    S.flyOn = ok
    if not ok then Say("`4EditToggle Ghost Fly gagal / tidak ada di CGT") end
  end
  Say("`2Auto Geiger jalan. Geiger Counter: " .. S.alive)

  if not Reconnect() then return end

  while S.running do
    CheckBreak()

    for i = 1, #RED_X do
      if not S.running then break end
      if S.itemFound then
        S.ring = RED
        break
      end
      if S.ring ~= RED then break end
      MoveTo(RED_X[i], RED_Y[i])
      RenewRing()
    end

    if S.running then
      if S.ring == YELLOW then
        foundYellow()
      elseif S.ring == GREEN then
        foundGreen()
      end

      S.itemFound = false
      FlushWebhook()
      -- pakai jumlah asli di inventory (bukan hitungan per siklus) supaya tidak meleset
      S.alive = GetItemCount(ALIVE_ID)
      UpdateStatus()

      if S.alive <= Cfg.MinAliveGeiger then
        if not SaveLoot() then
          if S.running then
            Log("`4Gagal menyimpan item, script dihentikan")
            S.running = false
          end
        else
          S.alive = GetItemCount(ALIVE_ID)
          if S.running and S.alive <= Cfg.MinAliveGeiger then
            -- tanpa ini script akan bolak-balik warp tanpa henti
            Log("`4Geiger Counter masih " .. S.alive .. " (<= " .. Cfg.MinAliveGeiger .. ") setelah menyimpan, script dihentikan")
            S.running = false
          end
        end
      end
    end
  end

  if S.flyOn then
    pcall(EditToggle, "Ghost Fly", false)
    S.flyOn = false
  end
  Say("`4Stopped")
end

-- ===== UI =====
local WIN = "geiger"
local Bound, Buttons = {}, {}
local uid = 0
local function nid(p)
  uid = uid + 1
  return p .. uid
end

UI.Window(WIN, { title = "Osmora AI | Auto Geiger", width = 380, height = 600 })

local function Head(text)
  UI.Separator(nid("sep"), { parent = WIN })
  UI.Text(nid("hd"), { parent = WIN, text = text })
end

local function Check(key, label)
  local id = "c_" .. key
  UI.Checkbox(id, { parent = WIN, text = label, value = Cfg[key] and true or false })
  Bound[id] = { key = key, kind = "bool" }
end

local function Field(key, label, kind)
  local id = "f_" .. key
  UI.Text(nid("lb"), { parent = WIN, text = label })
  UI.Input(id, { parent = WIN, value = tostring(Cfg[key]) })
  Bound[id] = { key = key, kind = kind }
end

local function Btn(id, label, fn, same)
  if same then UI.SameLine(nid("sl"), { parent = WIN }) end
  UI.Button(id, { parent = WIN, text = label })
  Buttons[id] = fn
end

local function RefreshUI()
  for id, b in pairs(Bound) do
    if b.kind == "bool" then
      UI.Set(id, { value = Cfg[b.key] and true or false })
    else
      UI.Set(id, { value = tostring(Cfg[b.key]) })
    end
  end
end

local function CaptureBG(key, fieldId)
  local x, y = MyPos()
  if not x then
    Log("`4Posisi tidak terbaca")
    return
  end
  local t = SafeTile(x, y)
  local bg = t and t.bg or 0
  if bg == 0 then
    Log("`4Tile tempat kamu berdiri tidak punya background")
    return
  end
  Cfg[key] = bg
  UI.Set(fieldId, { value = tostring(bg) })
  Log("`2" .. key .. " = " .. bg)
end

Btn("b_start", "Start Geiger", function()
  if S.running or S.startRequested then
    Log("`9Script already running")
  else
    S.startRequested = true
  end
end)
Btn("b_stop", "Stop Geiger", function()
  if S.running then
    S.running = false
    Log("`4Stop requested")
  else
    Log("`9Script not running")
  end
end, true)
Btn("b_defaults", "Defaults", function()
  for k, v in pairs(Defaults) do Cfg[k] = v end
  RefreshUI()
  Log("`2Defaults restored")
end, true)

UI.Text("status", { parent = WIN, text = "Stopped" })

Head("World")
Field("WorldGeiger", "World Geiger", "str")
Field("WorldSave", "World Simpan Item", "str")

Head("Lokasi Simpan (Background ID)")
Field("AliveGeigerBG", "AliveGeigerBG (ambil Geiger Counter, 0 = lewati)", "int")
Field("ItemDropBG", "ItemDropBG (drop item)", "int")
Field("DeadDropBG", "DeadDropBG (drop Dead Geiger, 0 = sama dgn item)", "int")
Btn("b_cap_alive", "Ambil BG Alive dari posisiku", function() CaptureBG("AliveGeigerBG", "f_AliveGeigerBG") end)
Btn("b_cap_item", "Ambil BG Item dari posisiku", function() CaptureBG("ItemDropBG", "f_ItemDropBG") end)
Btn("b_cap_dead", "Ambil BG Dead dari posisiku", function() CaptureBG("DeadDropBG", "f_DeadDropBG") end, true)
Btn("b_scan", "Cek jumlah tile area simpan", function()
  local a = #ScanBG(Cfg.ItemDropBG)
  local b = (Cfg.DeadDropBG > 0) and #ScanBG(Cfg.DeadDropBG) or a
  local c = #ScanBG(Cfg.AliveGeigerBG)
  Log("`2Tile alive: " .. c .. " | item: " .. a .. " | dead geiger: " .. b)
end)

Head("Pengaturan")
Field("MinAliveGeiger", "Simpan item jika Geiger Counter <=", "int")
Field("BreakMinutes", "Break tiap (menit)", "int")
Field("RingTimeout", "Timeout sinyal ring (detik)", "int")
Check("GhostFly", "Ghost Fly")

AddHook("OnUI", "geiger_ui", function(id, event, value)
  local b = Bound[id]
  if b then
    if event == "close" then return end
    local c = UI.Get(id)
    local val = c and c.value
    if val == nil then val = value end
    if b.kind == "bool" then
      Cfg[b.key] = truthy(val)
    elseif b.kind == "int" then
      local n = tonumber(val)
      if n and n >= 0 then Cfg[b.key] = math.floor(n) end
    else
      Cfg[b.key] = tostring(val or "")
    end
  elseif event == "click" and Buttons[id] then
    Buttons[id]()
  end
end)

-- ===== REGISTRASI HOOK =====
AddHook("OnVariant", "geiger_variant", variantHook)
-- hook packet ring: nama bisa berbeda antar versi, jadi didaftarkan beberapa nama
for _, n in ipairs({ "OnProcessTankUpdatePacket", "OnGamePacket", "OnIncomingRawPacket" }) do
  local ok = pcall(AddHook, n, "geiger_ring_" .. n, ringHook)
  if not ok then Say("`4Hook " .. n .. " tidak dikenali") end
end

-- ===== MAIN =====
while true do
  if S.startRequested then
    S.startRequested = false
    if not S.running then
      S.running = true
      for _, k in ipairs({ "AliveGeigerBG", "ItemDropBG", "DeadDropBG", "MinAliveGeiger", "BreakMinutes", "RingTimeout" }) do
        Cfg[k] = toint(Cfg[k])
      end
      if Cfg.BreakMinutes < 1 then Cfg.BreakMinutes = 1 end
      if Cfg.RingTimeout < 3 then Cfg.RingTimeout = 3 end
      RunGeiger()
      S.running = false
    end
  end
  UpdateStatus()
  Sleep(250)
end
