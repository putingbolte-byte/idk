--[[
    fisch.lua
    landscape liquid-glass panel · fishing automation · mobile + pc
    ui lineage: gun.lua (palette, primitives, draggable, config)
    features: auto-fish, auto-sell, auto-claim, auto-appraise, auto-enchant,
              skin crates, north exp, esp (players/npcs/prompts), teleport,
              movement, anti-afk, stealth governor
    keybinds: RSHIFT toggle panel · END panic · long-press launcher = panic
    mobile:  auto-opens on inject, horizontal tab strip, 48px touch targets
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")
local GuiService        = game:GetService("GuiService")
local VirtualUser       = game:GetService("VirtualUser")

local lp = Players.LocalPlayer
if not lp then return end

if type(_G.__fischlua_cleanup) == "function" then
    pcall(_G.__fischlua_cleanup)
end

-- ============================================================
-- HELPERS
-- ============================================================

local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then inst[k] = v end
    end
    if parent then inst.Parent = parent end
    return inst
end

local function tween(inst, goal, time, style)
    local t = TweenService:Create(
        inst,
        TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        goal
    )
    t:Play()
    return t
end

local function isTouchDevice()
    local ok, val = pcall(function()
        return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    end)
    return ok and val or false
end

local function viewport()
    local cam = Workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

-- ============================================================
-- CONFIG
-- ============================================================

local cfg = {
    -- fishing
    autoFish        = false,
    autoSell        = false,
    autoClaim       = false,
    autoAppraise    = false,
    autoEnchant     = false,
    skinCrates      = false,
    northExp        = false,
    fishDelay       = 0.35,
    sellInterval    = 8,
    claimInterval   = 15,
    -- esp
    espPlayers      = false,
    espNpcs         = false,
    espPrompts      = false,
    espDist         = true,
    -- movement
    noclip          = false,
    walkSpeed       = 16,
    infiniteJump    = false,
    antiAfk         = true,
    -- stealth
    stealth         = true,
    jitter          = 0.18,
    rateLimit       = 18,
    -- ui
    tab             = "Fishing",
}

local CONFIG_PATH = "fischlua_config.json"
local saveQueued = false

local SAVE_KEYS = {
    "autoFish", "autoSell", "autoClaim", "autoAppraise", "autoEnchant",
    "skinCrates", "northExp", "fishDelay", "sellInterval", "claimInterval",
    "espPlayers", "espNpcs", "espPrompts", "espDist",
    "noclip", "walkSpeed", "infiniteJump", "antiAfk",
    "stealth", "jitter", "rateLimit", "tab",
}

local function serializeConfig()
    local data = {}
    for _, k in ipairs(SAVE_KEYS) do data[k] = cfg[k] end
    local ok, json = pcall(function()
        return HttpService:JSONEncode(data)
    end)
    if ok and type(json) == "string" then return json end
    local parts = {"{"}
    for i, k in ipairs(SAVE_KEYS) do
        local v = cfg[k]
        local str
        if type(v) == "string" then
            str = '"' .. v .. '"'
        elseif type(v) == "boolean" then
            str = tostring(v)
        else
            str = tostring(tonumber(v) or 0)
        end
        parts[#parts + 1] = ('"%s":%s'):format(k, str)
        if i < #SAVE_KEYS then parts[#parts + 1] = "," end
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function() writefile(CONFIG_PATH, serializeConfig()) end)
end

local function queueSave()
    if saveQueued then return end
    saveQueued = true
    task.delay(0.6, function()
        saveQueued = false
        saveConfig()
    end)
end

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return false end
    local ok, raw = pcall(function()
        if isfile(CONFIG_PATH) then return readfile(CONFIG_PATH) end
    end)
    if not ok or type(raw) ~= "string" or #raw < 2 then return false end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then return false end
    for _, k in ipairs(SAVE_KEYS) do
        local v = data[k]
        if v ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
    end
    cfg.fishDelay     = math.clamp(tonumber(cfg.fishDelay) or 0.35, 0.05, 5)
    cfg.sellInterval  = math.clamp(tonumber(cfg.sellInterval) or 8, 2, 120)
    cfg.claimInterval = math.clamp(tonumber(cfg.claimInterval) or 15, 5, 300)
    cfg.walkSpeed     = math.clamp(tonumber(cfg.walkSpeed) or 16, 8, 500)
    cfg.jitter        = math.clamp(tonumber(cfg.jitter) or 0.18, 0, 1)
    cfg.rateLimit     = math.clamp(tonumber(cfg.rateLimit) or 18, 1, 120)
    return true
end

loadConfig()

local COL = {
    bg     = Color3.fromRGB(14, 16, 24),
    text   = Color3.fromRGB(236, 240, 250),
    sub    = Color3.fromRGB(148, 157, 180),
    cyan   = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    pink   = Color3.fromRGB(255, 122, 198),
    danger = Color3.fromRGB(255, 108, 122),
    ok     = Color3.fromRGB(120, 240, 170),
    off    = Color3.fromRGB(40, 44, 58),
}

-- ============================================================
-- REMOTES + STEALTH GOVERNOR
-- ============================================================
-- argument shapes are best-effort; tryShapes fails softly instead
-- of throwing into the executor console.

local Net
do
    local ok, folder = pcall(function()
        return ReplicatedStorage:WaitForChild("packages", 5):WaitForChild("Net", 5)
    end)
    Net = ok and folder or nil
end

local function remote(path)
    local head, tail = path:match("^(%a+)/(.+)$")
    if not head or not Net then return nil end
    local node = Net:FindFirstChild(head)
    if not node then return nil end
    local cur = node
    for seg in tail:gmatch("[^/]+") do
        cur = cur:FindFirstChild(seg)
        if not cur then return nil end
    end
    return cur
end

local function eventsRemote(name)
    local ok, folder = pcall(function() return ReplicatedStorage.events end)
    if not ok or not folder then return nil end
    local ok2, ev = pcall(function() return folder:FindFirstChild(name) end)
    return ok2 and ev or nil
end

local Bucket = { tokens = cfg.rateLimit, last = os.clock() }
local lastCall = {}
local errorStreak = {}

local function bucketRefill()
    local now = os.clock()
    local elapsed = now - Bucket.last
    Bucket.last = now
    Bucket.tokens = math.min(cfg.rateLimit, Bucket.tokens + elapsed * cfg.rateLimit)
end

local function jitterSleep()
    if not cfg.stealth then return end
    if cfg.jitter <= 0 then return end
    task.wait(math.random() * cfg.jitter)
end

local function callRemote(key, inst, cooldown, fn)
    if not inst then return false, "missing" end
    if cfg.stealth then
        bucketRefill()
        if Bucket.tokens < 1 then return false, "ratelimited" end
        local now = os.clock()
        if now - (lastCall[key] or 0) < cooldown then return false, "cooldown" end
        Bucket.tokens = Bucket.tokens - 1
        lastCall[key] = now
        jitterSleep()
    end
    local ok, err = pcall(fn)
    if not ok then
        errorStreak[key] = (errorStreak[key] or 0) + 1
        if errorStreak[key] > 5 then
            lastCall[key] = os.clock() + 8
        end
        return false, tostring(err)
    end
    errorStreak[key] = 0
    return true
end

local function tryShapes(key, inst, cooldown, shapes)
    for _, args in ipairs(shapes) do
        local ok, res = callRemote(key, inst, cooldown, function()
            if inst.ClassName == "RemoteFunction" then
                return inst:InvokeServer(table.unpack(args))
            else
                inst:FireServer(table.unpack(args))
            end
        end)
        if ok then return true, res end
    end
    return false
end

-- ============================================================
-- FISHING ENGINE
-- ============================================================

local Fish = {}
do
    Fish.cast      = remote("RF/FishingRod/Cast")
    Fish.handle    = remote("RE/FishingRod/HandleBobber")
    Fish["break"]  = remote("RE/FishingRod/BreakBobber")
    Fish.reset     = remote("RE/FishingRod/Reset")
    Fish.reelStart = remote("RF/Reel/Start")
    Fish.reelFin   = remote("RE/Reel/Finish")
    Fish.reelAbort = remote("RE/Reel/Abort")
    Fish.stabStart = remote("RF/Stab/Start")
    Fish.stabFin   = remote("RE/Stab/Finish")
    Fish.harpStart = remote("RF/HarpoonMinigame/Start")
    Fish.harpFin   = remote("RE/HarpoonMinigame/Finish")

    local ok, folder = pcall(function()
        return ReplicatedStorage.shared.modules.fishing.rodresources.events
    end)
    if ok and folder then
        local function fev(n)
            local o, i = pcall(function() return folder[n] end)
            return o and i or nil
        end
        Fish.castAsync   = fev("castAsync")
        Fish.catchFinish = fev("catchfinish")
        Fish.handleBob   = fev("handlebobber")
        Fish.breakBob    = fev("breakbobber")
        Fish.resetEvt    = fev("reset")
    end
end

local fishState = { lastAction = 0 }

local function fishStep()
    if not cfg.autoFish then return end
    local now = os.clock()
    if now - fishState.lastAction < cfg.fishDelay then return end
    fishState.lastAction = now

    if Fish.cast then
        callRemote("fish.cast", Fish.cast, math.max(0.5, cfg.fishDelay), function()
            Fish.cast:InvokeServer()
        end)
    elseif Fish.castAsync then
        pcall(function() Fish.castAsync:InvokeServer() end)
    end
    task.wait(cfg.fishDelay + math.random() * 0.2)

    if Fish.handle then
        tryShapes("fish.handle", Fish.handle, 0.4, { {}, {true}, {1}, {"start"} })
    end
    task.wait(cfg.fishDelay + math.random() * 0.15)

    if Fish.reelFin then
        tryShapes("fish.reelFin", Fish.reelFin, 0.4, { {}, {true}, {1} })
    end
    task.wait(cfg.fishDelay + math.random() * 0.15)

    if Fish.catchFinish then
        pcall(function() Fish.catchFinish:FireServer() end)
    end
    task.wait(cfg.fishDelay + math.random() * 0.2)

    if Fish.reset then
        pcall(function() Fish.reset:FireServer() end)
    elseif Fish.resetEvt then
        pcall(function() Fish.resetEvt:FireServer() end)
    end
end

-- ============================================================
-- SELL
-- ============================================================

local Sell = {}
do
    Sell.all        = eventsRemote("SellAll")
    Sell.everything = eventsRemote("selleverything")
    for _, name in ipairs({
        "SellAllStorage", "FischFrightSellAll", "FischfestSellAll",
        "FischmasSellAll", "ShadySellAll", "ValentinesSellAll",
    }) do
        local r = eventsRemote(name)
        if r then Sell[name] = r end
    end
end

local function doSell()
    local ok = false
    if Sell.all then
        ok = select(1, callRemote("sell.all", Sell.all, 4, function()
            Sell.all:InvokeServer()
        end))
    end
    if not ok and Sell.everything then
        ok = select(1, callRemote("sell.everything", Sell.everything, 4, function()
            Sell.everything:InvokeServer()
        end))
    end
    return ok
end

-- ============================================================
-- CLAIM
-- ============================================================

local Claim = {}
do
    local list = {
        daily       = remote("RE/DailyReward/Claim"),
        timemission = remote("RE/TimeMission/ClaimReward"),
        challenges  = remote("RF/Challenges/Claim"),
        crabcage    = remote("RF/CrabCage/Claim"),
        mastery     = remote("RE/Mastery/ClaimQuest"),
        rodreward   = remote("RE/RodJournal/ClaimRodReward"),
        milestone   = remote("RE/RodJournal/ClaimMilestoneReward"),
        cupid       = remote("RE/CupidPromise/ClaimRewards"),
        aquarium    = remote("RE/PersonalAquarium/ClaimRewards"),
        podium      = remote("RF/PodiumService/Claim"),
        devgift     = remote("RF/DevGift/Claim"),
        totem       = remote("RE/TotemCrafting/ClaimCraft"),
        meteor      = remote("RE/Meteor/Claim"),
        witcherfish = remote("RE/WitcherPotion/ClaimFish"),
        salesbooth  = remote("RE/SalesBoothService/Claim"),
        groupreward = eventsRemote("claimGroupReward"),
        reputation  = remote("RE/ReputationQuests/ClaimQuest"),
        companion   = remote("RE/Companion/OllieOtter/ClaimTreasure"),
        mermaidcove = remote("RE/MermaidCove/AltarClaim"),
        questprop   = remote("RE/QuestProps/Claimed"),
    }
    for k, v in pairs(list) do
        if v then Claim[k] = v end
    end
end

local function doClaim()
    local any = false
    for key, inst in pairs(Claim) do
        local ok = callRemote("claim." .. key, inst, 2.5, function()
            if inst.ClassName == "RemoteFunction" then
                inst:InvokeServer()
            else
                inst:FireServer()
            end
        end)
        if ok then any = true end
        task.wait(0.08 + math.random() * 0.12)
    end
    return any
end

-- ============================================================
-- APPRAISE / ENCHANT / CRATES / NORTH EXP
-- ============================================================

local Appraise = {
    fire = remote("RF/AppraiseAnywhere/Fire"),
    cost = remote("RF/AppraiseAnywhere/GetCost"),
}

local Enchant = {
    select  = remote("RF/Enchant/SelectEnchant"),
    confirm = remote("RF/Enchant/ConfirmTarget"),
    altar   = remote("RF/EnchantAltar/Interact"),
}

local Crates = {
    open  = remote("RF/RequestOpenSkinCrates"),
    spin  = remote("RF/SkinCrates/RequestSpin"),
    buy   = remote("RF/SkinCrates/Purchase"),
}

local NorthExp = {
    kill  = remote("RF/NorthExp/Kill"),
    shard = remote("RF/NorthExp/PurchaseShard"),
}

local function doAppraise()
    if not Appraise.fire then return false end
    return select(1, callRemote("appraise.fire", Appraise.fire, 3, function()
        Appraise.fire:InvokeServer()
    end))
end

local function doEnchant()
    if not Enchant.select then return false end
    tryShapes("enchant.select", Enchant.select, 2, { {1}, {true}, {} })
    task.wait(0.25)
    if Enchant.confirm then
        tryShapes("enchant.confirm", Enchant.confirm, 2, { {}, {true} })
    end
    return true
end

local function doCrates()
    if Crates.open then
        callRemote("crates.open", Crates.open, 5, function()
            Crates.open:InvokeServer()
        end)
    end
    task.wait(0.2)
    if Crates.spin then
        tryShapes("crates.spin", Crates.spin, 3, { {}, {1}, {"free"} })
    end
end

local function doNorthExp()
    if NorthExp.kill then
        callRemote("north.kill", NorthExp.kill, 6, function()
            NorthExp.kill:InvokeServer()
        end)
    end
end

-- ============================================================
-- TELEPORT
-- ============================================================

local TP = {
    cframe = remote("RF/RequestTeleportCFrame"),
    reveal = remote("RE/RequestTeleport"),
    elev   = remote("RF/ElevatorPrompt/RequestTeleport"),
    deep   = remote("RF/Deep/Teleport"),
    veil   = remote("RF/MarianasVeil/Teleport"),
    spawn  = remote("RF/GetSpawnPosition"),
    fast   = remote("RE/FastTravel/Teleport"),
    hawaii = remote("RF/HawaiiTeleport/Request"),
    mirror = remote("RE/MysticMirror/Teleport"),
}

local function teleportLocal(pos)
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        pcall(function()
            root.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))
        end)
    end
end

-- ============================================================
-- LOOPS
-- ============================================================

local running = true
local threads = {}

local function spawnLoop(fn)
    table.insert(threads, task.spawn(fn))
end

spawnLoop(function()
    while running do
        if cfg.autoFish then pcall(fishStep) end
        task.wait(0.15)
    end
end)

spawnLoop(function()
    local lastSell, lastClaim, lastExtras = 0, 0, 0
    while running do
        local now = os.clock()
        if cfg.autoSell and now - lastSell >= cfg.sellInterval then
            lastSell = now
            pcall(doSell)
        end
        if cfg.autoClaim and now - lastClaim >= cfg.claimInterval then
            lastClaim = now
            pcall(doClaim)
        end
        if now - lastExtras >= 20 then
            lastExtras = now
            if cfg.autoAppraise then pcall(doAppraise) end
            if cfg.autoEnchant  then pcall(doEnchant) end
            if cfg.skinCrates   then pcall(doCrates) end
            if cfg.northExp     then pcall(doNorthExp) end
        end
        task.wait(0.5)
    end
end)

spawnLoop(function()
    while running do
        pcall(function()
            local char = lp.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.WalkSpeed ~= cfg.walkSpeed then
                hum.WalkSpeed = cfg.walkSpeed
            end
        end)
        task.wait(0.4)
    end
end)

track(RunService.Stepped:Connect(function()
    if not cfg.noclip then return end
    local char = lp.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            pcall(function() part.CanCollide = false end)
        end
    end
end))

track(lp.Idled:Connect(function()
    if not cfg.antiAfk then return end
    pcall(function() VirtualUser:CaptureController() end)
    pcall(function() VirtualUser:ClickButton2(Vector2.new()) end)
end))

track(UserInputService.JumpRequest:Connect(function()
    if not cfg.infiniteJump then return end
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end))

-- ============================================================
-- ESP
-- ============================================================

local espFolder
do
    local ok, hui = pcall(function() return gethui and gethui() end)
    local parent
    if ok and hui then
        parent = hui
    else
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        parent = (ok2 and cg) or lp:WaitForChild("PlayerGui")
    end
    for _, c in ipairs(parent:GetChildren()) do
        if c.Name == "fischlish_esp" then pcall(function() c:Destroy() end) end
    end
    espFolder = create("Folder", { Name = "fischlish_esp" }, parent)
end

local espEntries = {}

local function makeEsp(model, label, color)
    if not model or not model:IsA("Model") then return end
    if espEntries[model] then return end
    local head = model:FindFirstChild("Head")
        or model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
    if not head then return end

    local bill = create("BillboardGui", {
        Name = "fischesp",
        Size = UDim2.fromOffset(170, 36),
        AlwaysOnTop = true,
        StudsOffset = Vector3.new(0, 2.6, 0),
        Adornee = head,
    }, espFolder)

    local nameLbl = create("TextLabel", {
        Size = UDim2.new(1, 0, 0.55, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = color or COL.cyan,
        TextStrokeTransparency = 0.6,
        Text = label or model.Name,
    }, bill)

    local distLbl = create("TextLabel", {
        Position = UDim2.new(0, 0, 0.55, 0),
        Size = UDim2.new(1, 0, 0.45, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = COL.sub,
        Text = "",
    }, bill)

    local highlight
    pcall(function()
        highlight = create("Highlight", {
            FillColor = color or COL.cyan,
            FillTransparency = 0.75,
            OutlineColor = color or COL.cyan,
            OutlineTransparency = 0.35,
            Adornee = model,
        }, espFolder)
    end)

    espEntries[model] = {
        bill = bill, nameLbl = nameLbl, distLbl = distLbl, highlight = highlight,
    }
end

local function clearEsp()
    for model, entry in pairs(espEntries) do
        for _, obj in pairs(entry) do
            pcall(function() obj:Destroy() end)
        end
        espEntries[model] = nil
    end
end

local espPromptSeen = {}

local function refreshEsp()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local origin = cam.CFrame.Position

    if cfg.espPlayers then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= lp and plr.Character then
                makeEsp(plr.Character, plr.Name, COL.pink)
            end
        end
    end

    if cfg.espNpcs then
        local world = Workspace:FindFirstChild("world")
        local npcs = world and world:FindFirstChild("npcs")
        if npcs then
            for _, m in ipairs(npcs:GetChildren()) do
                if m:IsA("Model") then
                    makeEsp(m, m.Name, COL.violet)
                end
            end
        end
    end

    if cfg.espPrompts then
        for _, p in ipairs(Workspace:GetDescendants()) do
            if p:IsA("ProximityPrompt") then
                local part = p.Parent
                if part and part:IsA("BasePart") and not espPromptSeen[p] then
                    espPromptSeen[p] = true
                    makeEsp(part, p.ActionText .. " · " .. p.ObjectText, COL.cyan)
                end
            end
        end
    end

    for model, entry in pairs(espEntries) do
        local head = model:FindFirstChild("Head")
            or model:FindFirstChild("HumanoidRootPart")
            or model.PrimaryPart
        if not head or not model.Parent then
            for _, obj in pairs(entry) do pcall(function() obj:Destroy() end) end
            espEntries[model] = nil
        else
            entry.bill.Adornee = head
            if cfg.espDist then
                entry.distLbl.Text = string.format("%d studs", math.floor((head.Position - origin).Magnitude))
            else
                entry.distLbl.Text = ""
            end
        end
    end
end

local function pruneEsp()
    if not cfg.espPlayers and not cfg.espNpcs and not cfg.espPrompts then
        clearEsp()
        espPromptSeen = {}
    end
end

track(RunService.RenderStepped:Connect(function()
    pcall(function()
        pruneEsp()
        if cfg.espPlayers or cfg.espNpcs or cfg.espPrompts then
            refreshEsp()
        end
    end)
end))

-- ============================================================
-- UI
-- ============================================================

local guiParent
do
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then
        guiParent = hui
    else
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        guiParent = (ok2 and cg) or lp:WaitForChild("PlayerGui")
    end
end

for _, c in ipairs(guiParent:GetChildren()) do
    if c.Name == "fischlua" then pcall(function() c:Destroy() end) end
end

local screen = create("ScreenGui", {
    Name = "fischlua",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(screen) end
    if protectgui then protectgui(screen) end
end)

local PANEL_W, PANEL_H = 620, 400

local panel = create("Frame", {
    Name = "panel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(PANEL_W, PANEL_H),
    BackgroundTransparency = 1,
    Visible = true,
}, screen)

local fitScale = create("UIScale", { Scale = 1 }, panel)

local shadow = create("Frame", {
    Position = UDim2.fromOffset(0, 9),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.62,
    BorderSizePixel = 0,
    ZIndex = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 22) }, shadow)

local shadowSoft = create("Frame", {
    Position = UDim2.fromOffset(0, 20),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.8,
    BorderSizePixel = 0,
    ZIndex = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 24) }, shadowSoft)

local body = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 1,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)
create("UIStroke", {
    Color = Color3.fromRGB(255, 255, 255),
    Transparency = 0.9,
    Thickness = 1,
}, body)

local sheen = create("Frame", {
    Size = UDim2.new(1, 0, 0, 120),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.96,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, sheen)
create("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.9),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Rotation = 90,
}, sheen)

local orbA = create("Frame", {
    Position = UDim2.fromOffset(-40, -60),
    Size = UDim2.fromOffset(220, 220),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbA)

local orbB = create("Frame", {
    Position = UDim2.new(1, -180, 1, -160),
    Size = UDim2.fromOffset(240, 240),
    BackgroundColor3 = COL.violet,
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    ZIndex = 2,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orbB)

-- header
local header = create("Frame", {
    Position = UDim2.fromOffset(0, 0),
    Size = UDim2.new(1, 0, 0, 56),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local logo = create("Frame", {
    Position = UDim2.fromOffset(18, 14),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.85,
    BorderSizePixel = 0,
    ZIndex = 4,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 8) }, logo)
create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet) }, logo)

create("TextLabel", {
    Position = UDim2.fromOffset(56, 11),
    Size = UDim2.fromOffset(240, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "fisch · cargo",
    ZIndex = 4,
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(56, 29),
    Size = UDim2.fromOffset(320, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "landscape build · stealth governor on",
    ZIndex = 4,
}, header)

-- drag grip (thumb target, doesn't steal taps)
local grip = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 6),
    Size = UDim2.fromOffset(56, 5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.72,
    BorderSizePixel = 0,
    ZIndex = 11,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, grip)

local statusDot = create("Frame", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -72, 0.5, 0),
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = COL.ok,
    BorderSizePixel = 0,
    ZIndex = 4,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, statusDot)

local closeBtn = create("TextButton", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.5, 0),
    Size = UDim2.fromOffset(36, 36),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.94,
    BorderSizePixel = 0,
    Text = "✕",
    Font = Enum.Font.GothamMedium,
    TextSize = 14,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    ZIndex = 5,
}, header)
create("UICorner", { CornerRadius = UDim.new(0, 10) }, closeBtn)
closeBtn.Activated:Connect(function() panel.Visible = false end)

-- tab rail (vertical on wide, horizontal strip on narrow)
local rail = create("Frame", {
    Position = UDim2.fromOffset(14, 66),
    Size = UDim2.new(0, 132, 1, -80),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local railLayout = create("UIListLayout", {
    Padding = UDim.new(0, 6),
    FillDirection = Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, rail)

local contentHolder = create("Frame", {
    Position = UDim2.fromOffset(156, 66),
    Size = UDim2.new(1, -170, 1, -80),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local scroll = create("ScrollingFrame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 8,
    ScrollBarImageColor3 = COL.cyan,
    ScrollBarImageTransparency = 0.3,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, contentHolder)
pcall(function() scroll.ElasticBehavior = Enum.ElasticBehavior.Never end)
pcall(function() scroll.ScrollingDirection = Enum.ScrollingDirection.Y end)

local content = create("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    BackgroundTransparency = 1,
    AutomaticSize = Enum.AutomaticSize.Y,
    ZIndex = 3,
}, scroll)

create("UIListLayout", {
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, content)

local footer = create("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 156, 1, -14),
    Size = UDim2.new(1, -170, 0, 18),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

local statusLabel = create("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "bench warm · idle",
}, footer)

-- ============================================================
-- UI PRIMITIVES
-- ============================================================

local orderCounter = 0
local function nextOrder()
    orderCounter = orderCounter + 1
    return orderCounter
end

local function addSection(parent, title)
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(title),
        LayoutOrder = nextOrder(),
    }, parent)

    create("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, parent)
end

local function makeSwitch(parent, initial, onChange)
    local holder = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.fromOffset(46, 24),
        BackgroundColor3 = initial and COL.cyan or COL.off,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, holder)

    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 5,
    }, holder)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

    local hit = create("TextButton", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(1, 16, 1, 16),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 6,
    }, holder)

    local state = initial
    hit.Activated:Connect(function()
        state = not state
        tween(holder, { BackgroundColor3 = state and COL.cyan or COL.off }, 0.14)
        tween(knob, {
            Position = state and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
        }, 0.14)
        onChange(state)
        queueSave()
    end)
    return holder
end

local function rowShell(parent, height, order)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, height or 50),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.92,
        BorderSizePixel = 0,
        LayoutOrder = order or nextOrder(),
        ZIndex = 3,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.92,
        Thickness = 1,
    }, row)
    return row
end

local function makeToggleRow(parent, title, desc, key)
    local row = rowShell(parent, 52)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -88, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 27),
        Size = UDim2.new(1, -88, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)

    makeSwitch(row, cfg[key], function(v)
        cfg[key] = v
        if key == "autoFish" then
            statusLabel.Text = v and "fishing · line cast" or "bench warm · idle"
        end
    end)
    return row
end

local function makeSliderRow(parent, title, desc, key, min, max, isFloat, onChange)
    local row = rowShell(parent, 68)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -110, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    local valLabel = create("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 8),
        Size = UDim2.fromOffset(80, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(cfg[key]),
        ZIndex = 4,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 26),
        Size = UDim2.new(1, -28, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)

    local trackBar = create("Frame", {
        Position = UDim2.fromOffset(14, 48),
        Size = UDim2.new(1, -28, 0, 8),
        BackgroundColor3 = COL.off,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, row)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

    local initialRel = (cfg[key] - min) / (max - min)

    local fill = create("Frame", {
        Size = UDim2.new(initialRel, 0, 1, 0),
        BackgroundColor3 = COL.cyan,
        BorderSizePixel = 0,
        ZIndex = 5,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)

    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(initialRel, 0, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = COL.text,
        BorderSizePixel = 0,
        ZIndex = 7,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
    create("UIStroke", { Color = COL.cyan, Transparency = 0.25, Thickness = 2 }, knob)

    local hit = create("TextButton", {
        Position = UDim2.fromOffset(0, 34),
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 8,
    }, row)

    local dragging = false

    local function apply(x)
        local rel = math.clamp((x - trackBar.AbsolutePosition.X) / math.max(1, trackBar.AbsoluteSize.X), 0, 1)
        local raw = min + (max - min) * rel
        local v = isFloat and math.floor(raw * 100) / 100 or math.floor(raw + 0.5)
        cfg[key] = v
        valLabel.Text = isFloat and string.format("%.2f", v) or tostring(v)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        knob.Position = UDim2.new(rel, 0, 0.5, 0)
        if onChange then onChange(v) end
        queueSave()
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            apply(input.Position.X)
        end
    end)

    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            apply(input.Position.X)
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    return row
end

local function makeActionRow(parent, title, desc, onPress)
    local row = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.92,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = nextOrder(),
        ZIndex = 3,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.92,
        Thickness = 1,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -28, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        ZIndex = 4,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 27),
        Size = UDim2.new(1, -28, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = desc or "",
        ZIndex = 4,
    }, row)

    row.Activated:Connect(function()
        onPress()
        queueSave()
    end)
    return row
end

-- ============================================================
-- TABS
-- ============================================================

local tabButtons = {}
local tabOrder = {}
local pages = {}

local function clearContent()
    for _, c in ipairs(content:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    orderCounter = 0
end

local function selectTabVisual(activeName)
    for name, btn in pairs(tabButtons) do
        local active = (name == activeName)
        tween(btn, { BackgroundTransparency = active and 0.86 or 0.94 }, 0.14)
        local accent = btn:FindFirstChild("accent")
        if accent then
            tween(accent, { BackgroundTransparency = active and 0 or 1 }, 0.14)
        end
        local lbl = btn:FindFirstChildOfClass("TextLabel")
        if lbl then
            tween(lbl, { TextColor3 = active and COL.text or COL.sub }, 0.14)
        end
    end
end

local function showTab(name)
    if not pages[name] then name = tabOrder[1] end
    clearContent()
    cfg.tab = name
    queueSave()
    selectTabVisual(name)
    pages[name]()
end

local function makeTabButton(name, label)
    table.insert(tabOrder, name)

    local btn = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = #tabOrder,
        ZIndex = 3,
    }, rail)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, btn)
    create("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Transparency = 0.94,
        Thickness = 1,
    }, btn)

    local accent = create("Frame", {
        Name = "accent",
        Position = UDim2.fromOffset(0, 11),
        Size = UDim2.fromOffset(3, 20),
        BackgroundColor3 = COL.cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, btn)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, accent)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -20, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = label,
        ZIndex = 4,
    }, btn)

    btn.Activated:Connect(function() showTab(name) end)
    tabButtons[name] = btn
    return btn
end

-- ============================================================
-- PAGE BUILDERS
-- ============================================================

pages.Fishing = function()
    addSection(content, "automation")
    makeToggleRow(content, "Auto Fish", "cast · handle · reel · reset", "autoFish")
    makeToggleRow(content, "Auto Sell", "sell all on a timer", "autoSell")
    makeToggleRow(content, "Auto Claim", "sweep every claimable reward", "autoClaim")
    makeToggleRow(content, "Auto Appraise", "appraise fish in bulk", "autoAppraise")
    makeToggleRow(content, "Auto Enchant", "select and confirm enchant", "autoEnchant")
    makeToggleRow(content, "Skin Crates", "open and spin free crates", "skinCrates")
    makeToggleRow(content, "North EXP", "north kill + shard claim", "northExp")

    addSection(content, "timing")
    makeSliderRow(content, "Fish Delay", "pause between cast and reel", "fishDelay", 0.05, 2, true)
    makeSliderRow(content, "Sell Interval", "seconds between sell sweeps", "sellInterval", 3, 60)
    makeSliderRow(content, "Claim Interval", "seconds between claim sweeps", "claimInterval", 5, 120)
end

pages.Stealth = function()
    addSection(content, "bypass layer")
    makeToggleRow(content, "Stealth Governor", "jitter + rate limit + backoff", "stealth")
    makeSliderRow(content, "Jitter", "max random delay before each call", "jitter", 0, 0.8, true)
    makeSliderRow(content, "Rate Limit", "max remote calls per second", "rateLimit", 1, 60)

    addSection(content, "actions")
    makeActionRow(content, "Run Full Claim Sweep", "fire every claim remote once", function()
        doClaim()
        statusLabel.Text = "claim sweep fired"
    end)
    makeActionRow(content, "Run Sell Now", "sell all inventory", function()
        doSell()
        statusLabel.Text = "sell fired"
    end)
    makeActionRow(content, "Panic Unload", "kill loops + destroy gui", function()
        if type(_G.__fischlua_cleanup) == "function" then
            pcall(_G.__fischlua_cleanup)
        end
    end)
end

pages.ESP = function()
    addSection(content, "targets")
    makeToggleRow(content, "Players", "highlight other players", "espPlayers")
    makeToggleRow(content, "NPCs", "highlight world npcs", "espNpcs")
    makeToggleRow(content, "Prompts", "highlight proximity prompts", "espPrompts")

    addSection(content, "style")
    makeToggleRow(content, "Distance", "show studs under each label", "espDist")
end

pages.Movement = function()
    addSection(content, "locomotion")
    makeToggleRow(content, "Noclip", "phase through world geometry", "noclip")
    makeToggleRow(content, "Infinite Jump", "jump mid-air", "infiniteJump")
    makeToggleRow(content, "Anti AFK", "keep the session alive", "antiAfk")
    makeSliderRow(content, "Walk Speed", "humanoid walkspeed", "walkSpeed", 8, 300)
end

pages.Teleport = function()
    addSection(content, "travel")
    makeActionRow(content, "Teleport to Spawn", "ask server for spawn position", function()
        if TP.spawn then
            local ok, pos = pcall(function() return TP.spawn:InvokeServer() end)
            if ok and typeof(pos) == "Vector3" then
                teleportLocal(pos)
                statusLabel.Text = "teleported to spawn"
            end
        end
    end)
    makeActionRow(content, "Deep Sea", "request deep teleport", function()
        if TP.deep then
            callRemote("tp.deep", TP.deep, 3, function() TP.deep:InvokeServer() end)
        end
    end)
    makeActionRow(content, "Marianas Veil", "request veiled teleport", function()
        if TP.veil then
            callRemote("tp.veil", TP.veil, 3, function() TP.veil:InvokeServer() end)
        end
    end)
    makeActionRow(content, "Mystic Mirror", "mirror teleport", function()
        if TP.mirror then
            callRemote("tp.mirror", TP.mirror, 3, function() TP.mirror:InvokeServer() end)
        end
    end)
end

pages.Config = function()
    addSection(content, "persistence")
    makeActionRow(content, "Save Config", "write fischlua_config.json", function()
        saveConfig()
        statusLabel.Text = "config saved"
    end)
    makeActionRow(content, "Reload Config", "re-read from disk", function()
        loadConfig()
        showTab(cfg.tab or "Fishing")
        statusLabel.Text = "config reloaded"
    end)
    makeActionRow(content, "Reset Config", "restore defaults", function()
        cfg.autoFish = false
        cfg.autoSell = false
        cfg.autoClaim = false
        cfg.autoAppraise = false
        cfg.autoEnchant = false
        cfg.skinCrates = false
        cfg.northExp = false
        cfg.espPlayers = false
        cfg.espNpcs = false
        cfg.espPrompts = false
        cfg.espDist = true
        cfg.noclip = false
        cfg.infiniteJump = false
        cfg.antiAfk = true
        cfg.walkSpeed = 16
        cfg.stealth = true
        cfg.jitter = 0.18
        cfg.rateLimit = 18
        saveConfig()
        showTab("Fishing")
        statusLabel.Text = "config reset"
    end)
end

for _, name in ipairs({ "Fishing", "Stealth", "ESP", "Movement", "Teleport", "Config" }) do
    makeTabButton(name, name)
end

-- ============================================================
-- LAYOUT (vertical rail wide / horizontal strip narrow)
-- ============================================================

local narrowMode = nil

local function applyLayout()
    local vp = viewport()
    local narrow = vp.X < 760
    if narrow == narrowMode then return end
    narrowMode = narrow

    if narrow then
        rail.Position = UDim2.fromOffset(12, 60)
        rail.Size = UDim2.new(1, -24, 0, 40)
        railLayout.FillDirection = Enum.FillDirection.Horizontal
        railLayout.Padding = UDim.new(0, 4)

        contentHolder.Position = UDim2.fromOffset(12, 108)
        contentHolder.Size = UDim2.new(1, -24, 1, -126)

        footer.Position = UDim2.new(0, 12, 1, -12)
        footer.Size = UDim2.new(1, -24, 0, 18)

        local n = #tabOrder
        for _, btn in pairs(tabButtons) do
            btn.Size = UDim2.new(1 / n, -4, 1, 0)
            local lbl = btn:FindFirstChildOfClass("TextLabel")
            if lbl then
                lbl.Position = UDim2.fromOffset(8, 0)
                lbl.Size = UDim2.new(1, -12, 1, 0)
                lbl.TextSize = 9
                lbl.TextXAlignment = Enum.TextXAlignment.Center
            end
            local accent = btn:FindFirstChild("accent")
            if accent then accent.Visible = false end
        end
    else
        rail.Position = UDim2.fromOffset(14, 66)
        rail.Size = UDim2.new(0, 132, 1, -80)
        railLayout.FillDirection = Enum.FillDirection.Vertical
        railLayout.Padding = UDim.new(0, 6)

        contentHolder.Position = UDim2.fromOffset(156, 66)
        contentHolder.Size = UDim2.new(1, -170, 1, -80)

        footer.Position = UDim2.new(0, 156, 1, -14)
        footer.Size = UDim2.new(1, -170, 0, 18)

        for _, btn in pairs(tabButtons) do
            btn.Size = UDim2.new(1, 0, 0, 42)
            local lbl = btn:FindFirstChildOfClass("TextLabel")
            if lbl then
                lbl.Position = UDim2.fromOffset(14, 0)
                lbl.Size = UDim2.new(1, -20, 1, 0)
                lbl.TextSize = 11
                lbl.TextXAlignment = Enum.TextXAlignment.Left
            end
            local accent = btn:FindFirstChild("accent")
            if accent then accent.Visible = true end
        end
    end
end

showTab(cfg.tab or "Fishing")
applyLayout()

-- ============================================================
-- DRAG (header)
-- ============================================================

local dragging, dragStart, dragOrigin

local dragBtn = create("TextButton", {
    Size = UDim2.new(1, -60, 0, 56),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 10,
}, header)

track(dragBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragOrigin = panel.Position
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y
        )
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

-- ============================================================
-- FLOATING LAUNCHER
-- ============================================================

local float = create("TextButton", {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -40, 1, -56),
    Size = UDim2.fromOffset(64, 64),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    Text = "🐟",
    Font = Enum.Font.GothamBold,
    TextSize = 26,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    ZIndex = 20,
}, screen)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, float)
create("UIStroke", { Color = COL.cyan, Transparency = 0.55, Thickness = 2 }, float)

local floatDragging, floatStart, floatOrigin, floatMoved, floatHoldStart

track(float.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        floatDragging = true
        floatStart = input.Position
        floatOrigin = float.Position
        floatMoved = false
        floatHoldStart = os.clock()
    end
end))

track(float.Activated:Connect(function()
    if floatMoved then return end
    if floatHoldStart and os.clock() - floatHoldStart > 0.8 then
        if type(_G.__fischlua_cleanup) == "function" then
            pcall(_G.__fischlua_cleanup)
        end
        return
    end
    panel.Visible = not panel.Visible
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not floatDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - floatStart
        if delta.Magnitude > 6 then floatMoved = true end
        float.Position = UDim2.new(
            floatOrigin.X.Scale, floatOrigin.X.Offset + delta.X,
            floatOrigin.Y.Scale, floatOrigin.Y.Offset + delta.Y
        )
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        floatDragging = false
    end
end))

-- ============================================================
-- FIT
-- ============================================================

local function fit()
    local vp = viewport()
    local narrow = vp.X < 760
    local w = narrow and (PANEL_W - 60) or PANEL_W
    local h = narrow and (PANEL_H - 10) or PANEL_H
    local scale = math.min((vp.X - 16) / w, (vp.Y - 16) / h)
    -- mobile keeps text legible; desktop can shrink further
    local floor = isTouchDevice() and 0.76 or 0.58
    fitScale.Scale = math.clamp(scale, floor, 1)
end

fit()
applyLayout()

do
    local cam = Workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            applyLayout()
            fit()
        end))
    end
end

-- ============================================================
-- KEYBINDS
-- ============================================================

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        panel.Visible = not panel.Visible
    elseif input.KeyCode == Enum.KeyCode.End then
        if type(_G.__fischlua_cleanup) == "function" then
            pcall(_G.__fischlua_cleanup)
        end
    end
end))

-- ============================================================
-- CLEANUP
-- ============================================================

_G.__fischlua_cleanup = function()
    running = false
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}
    threads = {}
    pcall(clearEsp)
    pcall(function() if espFolder then espFolder:Destroy() end end)
    pcall(function() if screen then screen:Destroy() end end)
end

statusLabel.Text = isTouchDevice() and "bench warm · mobile" or "bench warm · ready"
print("[fisch] loaded · RSHIFT panel · END panic · launcher long-press panic")
