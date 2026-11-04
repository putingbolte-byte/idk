--[[
    deadshift.lua — cheat menu for the Deadshift-style survival/versus game
    place 138666076608290

    every remote path in here came out of the recon2 report, not guesswork:

      ReplicatedStorage.DeadshiftPrototype.Action          RemoteEvent   conn=4
      ReplicatedStorage.DeadshiftPrototype.SelectClass     RemoteFunction
      ReplicatedStorage.DeadshiftPrototype.SelectSecondary RemoteFunction
      ReplicatedStorage.DeadshiftPrototype.GrenadeAim      RemoteEvent
      ReplicatedStorage.DeadshiftPrototype.Control         RemoteEvent
      ReplicatedStorage.DeadshiftPrototype.SurvivorVoice   RemoteEvent
      ReplicatedStorage.DeadshiftPrototype.BugReportSubmit RemoteFunction
      ReplicatedStorage.InteractionFeedback                RemoteEvent
      ReplicatedStorage.ReviveHoldInput                    RemoteEvent
      ReplicatedStorage.SurvivorLadder                     RemoteEvent
      ReplicatedStorage.JockeyRideInput                    RemoteEvent
      ReplicatedStorage.VersusKillFeed                     RemoteEvent   conn=1
      ReplicatedStorage.SurvivorDamageDirection            RemoteEvent   conn=1
      ReplicatedStorage.SoloChance                         RemoteEvent   conn=1
      ReplicatedStorage.Announcement                       RemoteEvent   conn=1
      ReplicatedStorage.NpcSay                             RemoteEvent   conn=1
      ReplicatedStorage.LocalSfx                           RemoteEvent   conn=1
      ReplicatedStorage.ChapterAction / ChapterStatus / ChapterCutscene
      ReplicatedStorage.ClassesStandOpen
      ReplicatedStorage.LoadGate
      ReplicatedStorage.PlayerSettings
      ReplicatedStorage.MenuLobbies (RF) / MenuLobbyUpdate
      ReplicatedStorage.SurvivalLeaderboard (RF)
      ReplicatedStorage.UseFreeRevive (RF)
      ReplicatedStorage.CommunityRewardClaim (RF)
      ReplicatedStorage.VersusRemotes.*  (Hunter/Special input, move, notify)
      ReplicatedStorage.AdminPanelRemotes.*
      ReplicatedStorage.GS_AdminPanelV2.*

    six things in here do not touch the server at all:

      1. ESP            — pure client, Highlight + billboards
      2. infected ESP   — L4D2 cast detection: players in a special class,
                          npc models in workspace. coloured per class.
      3. aim assist     — camera lock with wall check + team check, bound
                          after the game's camera script
      4. visuals        — fullbright, no fog, FOV
      5. movement       — speed, jump, fly, noclip, teleport
      6. spoof          — fires a remote's OWN OnClientEvent handlers locally
                          with whatever args you type. fake kill feed, fake
                          announcement, fake damage markers, fake cutscene.
                          the server never sees it, so it is free.

    auto fire is not a remote spam. it presses the game's own DSFire button,
    which is the exact same handler a thumb tap runs — no payload guessing.

    the logger is the one that pays for itself: it records every real
    FireServer/InvokeServer with the typeof of each argument, so you can read
    the actual shape off a live call instead of guessing at it.

    mobile: every control is an Activated handler. drag strip, collapse,
    close, and a tab rail that scrolls sideways.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__deadshift_cleanup) == "function" then
    pcall(_G.__deadshift_cleanup)
end

local unpack = table.unpack or unpack

local CONFIG = {
    version = "1.0",
    place = "138666076608290",
}

----------------------------------------------------------------------------
-- executor globals, grabbed by identifier so a missing one is just nil
----------------------------------------------------------------------------

local EXEC = {
    hookmetamethod = hookmetamethod,
    getnamecallmethod = getnamecallmethod,
    getconnections = getconnections,
    setclipboard = setclipboard,
    writefile = writefile,
    loadstring = loadstring,
    getgenv = getgenv,
    getrawmetatable = getrawmetatable,
    setreadonly = setreadonly,
    isreadonly = isreadonly,
}

local function have(name)
    return type(EXEC[name]) == "function"
end

local function try(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if ok then
        return value
    end
    return nil
end

-- os.clock() is CPU time, not wall time. every deadline built on it is a lie
-- once the code starts yielding, which is how a hung RemoteFunction locks the
-- whole menu. real clock only.
local function wallNow()
    local ok, millis = pcall(function()
        return DateTime.now().UnixTimestampMillis
    end)
    if ok and type(millis) == "number" then
        return millis / 1000
    end
    local okTick, value = pcall(function()
        return tick()
    end)
    if okTick and type(value) == "number" then
        return value
    end
    return os.time()
end

----------------------------------------------------------------------------
-- palette + widget toolkit
----------------------------------------------------------------------------

local COL = {
    bg = Color3.fromRGB(10, 11, 15),
    panel = Color3.fromRGB(17, 19, 26),
    text = Color3.fromRGB(236, 240, 250),
    sub = Color3.fromRGB(148, 157, 180),
    dim = Color3.fromRGB(98, 106, 130),
    cyan = Color3.fromRGB(104, 228, 255),
    blue = Color3.fromRGB(122, 166, 255),
    violet = Color3.fromRGB(176, 148, 255),
    green = Color3.fromRGB(122, 240, 172),
    amber = Color3.fromRGB(255, 198, 110),
    red = Color3.fromRGB(255, 108, 124),
    blood = Color3.fromRGB(196, 48, 62),
}

local conns = {}
local function keep(conn)
    conns[#conns + 1] = conn
    return conn
end

local function new(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props or {}) do
        if key ~= "Parent" then
            pcall(function()
                inst[key] = value
            end)
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

----------------------------------------------------------------------------
-- gui root
----------------------------------------------------------------------------

local guiParent = nil
do
    local ok, playerGui = pcall(function()
        return lp:WaitForChild("PlayerGui", 5)
    end)
    if ok and playerGui then
        guiParent = playerGui
    else
        local okCore, core = pcall(function()
            return game:GetService("CoreGui")
        end)
        guiParent = (okCore and core) or nil
    end
end

if not guiParent then
    return
end

for _, child in ipairs(guiParent:GetChildren()) do
    if child.Name == "deadshift" then
        pcall(function()
            child:Destroy()
        end)
    end
end

local screen = new("ScreenGui", {
    Name = "deadshift",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 9995,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

local panel = new("Frame", {
    Position = UDim2.fromOffset(8, 8),
    Size = UDim2.fromOffset(380, 620),
    BackgroundTransparency = 1,
    Active = true,
}, screen)

local scale = new("UIScale", { Scale = 1 }, panel)

new("Frame", {
    Position = UDim2.fromOffset(0, 10),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.55,
    BorderSizePixel = 0,
}, panel)

local shell = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.02,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, panel)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, shell)

local shellStroke = new("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.85,
    Thickness = 1,
}, shell)
new("UIGradient", {
    Color = ColorSequence.new(COL.blood, COL.violet),
    Transparency = NumberSequence.new(0.5, 0.9),
    Rotation = 30,
}, shellStroke)

----------------------------------------------------------------------------
-- header
----------------------------------------------------------------------------

local PAD = 10
local HEADER_H = 46

local header = new("Frame", {
    Size = UDim2.new(1, 0, 0, HEADER_H),
    BackgroundTransparency = 1,
    Active = true,
}, shell)

new("TextLabel", {
    Position = UDim2.fromOffset(14, 7),
    Size = UDim2.new(1, -110, 0, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "deadshift  " .. CONFIG.version,
}, header)

local statusLabel = new("TextLabel", {
    Position = UDim2.fromOffset(14, 25),
    Size = UDim2.new(1, -110, 0, 14),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = COL.green,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "ready",
}, header)

local function setStatus(text, color)
    statusLabel.Text = tostring(text)
    statusLabel.TextColor3 = color or COL.green
end

local collapseButton = new("TextButton", {
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -80, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "–",
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
    ZIndex = 6,
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, collapseButton)

local closeButton = new("TextButton", {
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -44, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 18,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
    ZIndex = 6,
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, closeButton)

-- drag strip stops short of the buttons; a full-width one eats their taps
local dragZone = new("Frame", {
    Size = UDim2.new(1, -126, 1, 0),
    BackgroundTransparency = 1,
    Active = true,
    ZIndex = 0,
}, header)

do
    local dragging = false
    local startPos = Vector2.zero
    local startFrame = UDim2.new(0, 8, 0, 8)

    keep(dragZone.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startPos = input.Position
            startFrame = panel.Position
        end
    end))

    keep(UIS.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startPos
            panel.Position = UDim2.new(
                startFrame.X.Scale, startFrame.X.Offset + delta.X,
                startFrame.Y.Scale, startFrame.Y.Offset + delta.Y
            )
        end
    end))

    keep(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

----------------------------------------------------------------------------
-- tab rail
----------------------------------------------------------------------------

local TABS = { "esp", "zomb", "combat", "vis", "move", "spoof", "log", "srv" }
local TAB_W = 62

local rail = new("ScrollingFrame", {
    Position = UDim2.fromOffset(0, HEADER_H),
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollingDirection = Enum.ScrollingDirection.X,
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = COL.dim,
    ScrollBarImageTransparency = 0.6,
}, shell)

new("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Center,
}, rail)

new("UIPadding", {
    PaddingLeft = UDim.new(0, PAD),
    PaddingRight = UDim.new(0, PAD),
}, rail)

local pages = {}
local tabButtons = {}

local function makeTab(name, order)
    local button = new("TextButton", {
        Size = UDim2.fromOffset(TAB_W, 26),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        Text = name,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.sub,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = order,
    }, rail)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
    tabButtons[name] = button
    return button
end

local pageHost = new("Frame", {
    Position = UDim2.fromOffset(0, HEADER_H + 36),
    Size = UDim2.new(1, 0, 1, -(HEADER_H + 36) - 4),
    BackgroundTransparency = 1,
}, shell)

local function makePage(name)
    local page = new("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COL.sub,
        ScrollBarImageTransparency = 0.55,
        Visible = false,
    }, pageHost)
    new("UIPadding", {
        PaddingLeft = UDim.new(0, PAD),
        PaddingRight = UDim.new(0, PAD),
        PaddingTop = UDim.new(0, 2),
        PaddingBottom = UDim.new(0, 10),
    }, page)
    new("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)
    pages[name] = { frame = page, order = 0 }
    return page
end

local activeTab = nil

local function showTab(name)
    activeTab = name
    for tab, page in pairs(pages) do
        page.frame.Visible = (tab == name)
    end
    for tab, button in pairs(tabButtons) do
        if tab == name then
            button.TextColor3 = COL.text
            button.BackgroundTransparency = 0.86
        else
            button.TextColor3 = COL.sub
            button.BackgroundTransparency = 0.94
        end
    end
end

----------------------------------------------------------------------------
-- widgets
----------------------------------------------------------------------------

local function nextOrder(page)
    page.order = page.order + 1
    return page.order
end

local function sectionRule(title)
    return function(name)
        local page = pages[name]
        new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextColor3 = COL.cyan,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "── " .. string.upper(tostring(title)) .. " ──",
            LayoutOrder = nextOrder(page),
        }, page.frame)
    end
end

local function row(title, height)
    return function(name)
        local page = pages[name]
        local frame = new("Frame", {
            Size = UDim2.new(1, 0, 0, height or 30),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = 0.95,
            BorderSizePixel = 0,
            LayoutOrder = nextOrder(page),
        }, page.frame)
        new("UICorner", { CornerRadius = UDim.new(0, 8) }, frame)

        new("TextLabel", {
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(1, -100, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = COL.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = title,
        }, frame)

        return frame
    end
end

local function toggle(pageName, title, default, onChanged)
    local frame = row(title, 30)(pageName)
    local state = { value = default and true or false }

    local button = new("TextButton", {
        Position = UDim2.new(1, -10, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.fromOffset(52, 22),
        BackgroundColor3 = state.value and COL.green or COL.dim,
        BackgroundTransparency = 0.78,
        BorderSizePixel = 0,
        Text = state.value and "ON" or "OFF",
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = state.value and COL.green or COL.sub,
        AutoButtonColor = false,
        Active = true,
    }, frame)
    new("UICorner", { CornerRadius = UDim.new(0, 7) }, button)
    local stroke = new("UIStroke", {
        Color = state.value and COL.green or COL.dim,
        Transparency = 0.5,
        Thickness = 1,
    }, button)

    local function paint()
        button.Text = state.value and "ON" or "OFF"
        button.TextColor3 = state.value and COL.green or COL.sub
        button.BackgroundColor3 = state.value and COL.green or COL.dim
        stroke.Color = state.value and COL.green or COL.dim
    end

    button.Activated:Connect(function()
        state.value = not state.value
        paint()
        if onChanged then
            pcall(onChanged, state.value)
        end
    end)

    state.set = function(value)
        state.value = value and true or false
        paint()
    end

    return state
end

local function slider(pageName, title, min, max, default, step, onChanged)
    local frame = row(title, 46)(pageName)
    local value = default

    local readout = new("TextLabel", {
        Position = UDim2.new(1, -62, 0, 6),
        Size = UDim2.fromOffset(52, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(default),
    }, frame)

    local track = new("TextButton", {
        Position = UDim2.fromOffset(10, 26),
        Size = UDim2.new(1, -20, 0, 10),
        BackgroundColor3 = COL.dim,
        BackgroundTransparency = 0.6,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Active = true,
    }, frame)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, track)

    local fill = new("Frame", {
        Size = UDim2.fromScale((default - min) / (max - min), 1),
        BackgroundColor3 = COL.cyan,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
    }, track)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, fill)

    local function commit(fraction)
        fraction = math.clamp(fraction, 0, 1)
        local raw = min + (max - min) * fraction
        if step and step > 0 then
            raw = math.floor(raw / step + 0.5) * step
        end
        raw = math.clamp(raw, min, max)
        value = raw
        fill.Size = UDim2.fromScale((raw - min) / (max - min), 1)
        readout.Text = (step and step < 1)
            and string.format("%.2f", raw)
            or tostring(math.floor(raw + 0.5))
        if onChanged then
            pcall(onChanged, raw)
        end
    end

    local dragging = false

    local function fromInput(input)
        local abs = track.AbsolutePosition
        local width = track.AbsoluteSize.X
        if width <= 0 then
            return
        end
        commit((input.Position.X - abs.X) / width)
    end

    keep(track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromInput(input)
        end
    end))

    keep(UIS.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            fromInput(input)
        end
    end))

    keep(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    return {
        get = function()
            return value
        end,
    }
end

local function action(pageName, text, accent, callback, height)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, height or 30),
        BackgroundColor3 = accent or COL.blue,
        BackgroundTransparency = 0.84,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = nextOrder(pages[pageName]),
    }, pages[pageName].frame)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
    new("UIStroke", {
        Color = accent or COL.blue,
        Transparency = 0.6,
        Thickness = 1,
    }, button)

    button.Activated:Connect(function()
        local ok, err = pcall(callback)
        if not ok then
            setStatus(tostring(err), COL.red)
        end
    end)

    return button
end

local function input(pageName, placeholder, default)
    local frame = row("", 30)(pageName)
    local box = new("TextBox", {
        Position = UDim2.fromOffset(8, 0),
        Size = UDim2.new(1, -16, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = COL.text,
        PlaceholderText = placeholder,
        PlaceholderColor3 = COL.dim,
        Text = default or "",
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
    }, frame)
    return box
end

local function note(pageName, text, color)
    local label = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = color or COL.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = text,
        LayoutOrder = nextOrder(pages[pageName]),
    }, pages[pageName].frame)
    pcall(function()
        label.AutomaticSize = Enum.AutomaticSize.Y
    end)
    return label
end

----------------------------------------------------------------------------
-- remote registry
----------------------------------------------------------------------------

local RS = game:GetService("ReplicatedStorage")

local function resolve(path)
    local node = game
    for part in string.gmatch(path, "[^%.]+") do
        if node == game then
            local okService, service = pcall(function()
                return game:GetService(part)
            end)
            if okService and service then
                node = service
            else
                return nil
            end
        else
            local ok, child = pcall(function()
                return node:FindFirstChild(part)
            end)
            if not ok or not child then
                return nil
            end
            node = child
        end
    end
    return node
end

-- every path here is straight off the recon report. resolve() is lazy, so a
-- missing one costs a nil, never an error.
local PATHS = {
    action          = "ReplicatedStorage.DeadshiftPrototype.Action",
    selectClass     = "ReplicatedStorage.DeadshiftPrototype.SelectClass",
    selectSecondary = "ReplicatedStorage.DeadshiftPrototype.SelectSecondary",
    grenadeAim      = "ReplicatedStorage.DeadshiftPrototype.GrenadeAim",
    control         = "ReplicatedStorage.DeadshiftPrototype.Control",
    survivorVoice   = "ReplicatedStorage.DeadshiftPrototype.SurvivorVoice",
    bugReport       = "ReplicatedStorage.DeadshiftPrototype.BugReportSubmit",
    commerce        = "ReplicatedStorage.DeadshiftPrototype.CommerceRequest",

    interaction     = "ReplicatedStorage.InteractionFeedback",
    reviveHold      = "ReplicatedStorage.ReviveHoldInput",
    ladder          = "ReplicatedStorage.SurvivorLadder",
    jockey          = "ReplicatedStorage.JockeyRideInput",
    killFeed        = "ReplicatedStorage.VersusKillFeed",
    damageDir       = "ReplicatedStorage.SurvivorDamageDirection",
    soloChance      = "ReplicatedStorage.SoloChance",
    announcement    = "ReplicatedStorage.Announcement",
    npcSay          = "ReplicatedStorage.NpcSay",
    localSfx        = "ReplicatedStorage.LocalSfx",
    chapterAction   = "ReplicatedStorage.ChapterAction",
    chapterStatus   = "ReplicatedStorage.ChapterStatus",
    chapterCutscene = "ReplicatedStorage.ChapterCutscene",
    classesStand    = "ReplicatedStorage.ClassesStandOpen",
    loadGate        = "ReplicatedStorage.LoadGate",
    playerSettings  = "ReplicatedStorage.PlayerSettings",
    menuLobbyUpdate = "ReplicatedStorage.MenuLobbyUpdate",
    spectatorRetry  = "ReplicatedStorage.SpectatorRetry",

    menuLobbies     = "ReplicatedStorage.MenuLobbies",
    leaderboard     = "ReplicatedStorage.SurvivalLeaderboard",
    freeRevive      = "ReplicatedStorage.UseFreeRevive",
    rewardClaim     = "ReplicatedStorage.CommunityRewardClaim",

    versusTest      = "ReplicatedStorage.VersusRemotes.VersusTest",
    versusSpawn     = "ReplicatedStorage.VersusRemotes.VersusSpawn",
    versusVote      = "ReplicatedStorage.VersusRemotes.VersusVote",
    versusLeave     = "ReplicatedStorage.VersusRemotes.VersusLeave",
    versusGhostWarp = "ReplicatedStorage.VersusRemotes.VersusGhostWarp",

    adminGrant      = "ReplicatedStorage.AdminPanelRemotes.AdminGrant",
    adminUnban      = "ReplicatedStorage.AdminPanelRemotes.AdminUnban",
    adminTroll      = "ReplicatedStorage.AdminPanelRemotes.AdminTroll",
    adminFreecam    = "ReplicatedStorage.AdminPanelRemotes.AdminFreecam",
    adminLookup     = "ReplicatedStorage.AdminPanelRemotes.AdminLookup",
    adminAnnounce   = "ReplicatedStorage.AdminPanelRemotes.AdminAnnounce",
}

local cache = {}

local function remote(key)
    if cache[key] then
        return cache[key]
    end
    local path = PATHS[key]
    if not path then
        return nil
    end
    local inst = resolve(path)
    if inst then
        cache[key] = inst
    end
    return inst
end

local function refresh()
    for key in pairs(cache) do
        cache[key] = nil
    end
    local found, missing = 0, 0
    for key in pairs(PATHS) do
        if remote(key) then
            found = found + 1
        else
            missing = missing + 1
        end
    end
    setStatus(("remotes %d/%d"):format(found, found + missing),
        missing == 0 and COL.green or COL.amber)
    return found, missing
end

local function send(key, ...)
    local inst = remote(key)
    if not inst then
        setStatus("missing remote: " .. key, COL.amber)
        return false
    end

    -- capture the varargs, the pcall closure is not vararg itself
    local args = { ... }
    local argc = select("#", ...)

    local ok, err = pcall(function()
        if inst.ClassName == "RemoteEvent" or inst.ClassName == "UnreliableRemoteEvent" then
            inst:FireServer(unpack(args, 1, argc))
        elseif inst.ClassName == "RemoteFunction" then
            return inst:InvokeServer(unpack(args, 1, argc))
        end
    end)
    if not ok then
        setStatus(key .. " failed: " .. tostring(err), COL.red)
    end
    return ok
end

----------------------------------------------------------------------------
-- character helpers
----------------------------------------------------------------------------

local function character()
    local char = lp.Character
    if char and char.Parent then
        return char
    end
    return nil
end

local function humanoid()
    local char = character()
    if not char then
        return nil
    end
    return char:FindFirstChildOfClass("Humanoid")
end

local function root()
    local char = character()
    if not char then
        return nil
    end
    return char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso")
end

----------------------------------------------------------------------------
-- ESP
----------------------------------------------------------------------------

local espState = {
    enabled = false,
    names = true,
    health = true,
    distance = true,
    tracers = false,
    maxDistance = 2000,
    entries = {},
}

local function clearEsp()
    for player, data in pairs(espState.entries) do
        if data.highlight then
            pcall(function()
                data.highlight:Destroy()
            end)
        end
        if data.billboard then
            pcall(function()
                data.billboard:Destroy()
            end)
        end
        if data.tracer then
            pcall(function()
                data.tracer:Destroy()
            end)
        end
        espState.entries[player] = nil
    end
end

local ESP_HIGHLIGHT = "ds_esp"

local function buildEsp(player)
    if player == lp then
        return nil
    end
    local char = player.Character
    if not char then
        return nil
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = ESP_HIGHLIGHT
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = COL.blood
    highlight.FillTransparency = 0.65
    highlight.OutlineColor = COL.red
    highlight.OutlineTransparency = 0

    local billboard = Instance.new("BillboardGui")
    billboard.Name = ESP_HIGHLIGHT
    billboard.Size = UDim2.fromOffset(120, 34)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 5000

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, 0, 0, 14)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 12
    nameLabel.TextColor3 = COL.text
    nameLabel.TextStrokeTransparency = 0.4
    nameLabel.Text = player.Name
    nameLabel.Parent = billboard

    local infoLabel = Instance.new("TextLabel")
    infoLabel.Position = UDim2.fromOffset(0, 14)
    infoLabel.Size = UDim2.new(1, 0, 0, 12)
    infoLabel.BackgroundTransparency = 1
    infoLabel.Font = Enum.Font.Code
    infoLabel.TextSize = 10
    infoLabel.TextColor3 = COL.sub
    infoLabel.TextStrokeTransparency = 0.4
    infoLabel.Text = ""
    infoLabel.Parent = billboard

    local tracer = nil
    if espState.tracers then
        tracer = Instance.new("Frame")
        tracer.Name = "ds_tracer"
        tracer.BackgroundColor3 = COL.blood
        tracer.BackgroundTransparency = 0.35
        tracer.BorderSizePixel = 0
        tracer.ZIndex = 2
    end

    pcall(function()
        highlight.Parent = char
        billboard.Parent = char
        if tracer then
            tracer.Parent = screen
        end
    end)

    return {
        highlight = highlight,
        billboard = billboard,
        nameLabel = nameLabel,
        infoLabel = infoLabel,
        tracer = tracer,
    }
end

local function syncEsp()
    if not espState.enabled then
        clearEsp()
        return
    end

    local seen = {}
    local myRoot = root()
    local myPos = myRoot and myRoot.Position or nil

    for _, player in ipairs(Players:GetPlayers()) do
        seen[player] = true
        local data = espState.entries[player]
        local char = player.Character

        if char and char.Parent then
            if not data then
                data = buildEsp(player)
                espState.entries[player] = data
            elseif data.highlight and data.highlight.Parent ~= char then
                pcall(function()
                    data.highlight.Parent = char
                    data.billboard.Parent = char
                end)
            end

            -- the max-distance slider only ever moved the billboard before, so
            -- the highlight still painted people across the whole map.
            if data and data.highlight then
                local theirRoot = char:FindFirstChild("HumanoidRootPart")
                local inRange = true
                if myPos and theirRoot then
                    inRange = (theirRoot.Position - myPos).Magnitude <= espState.maxDistance
                end
                pcall(function()
                    data.highlight.Enabled = inRange
                    data.billboard.Enabled = inRange
                end)
            end
        elseif data then
            if data.highlight then
                pcall(function()
                    data.highlight:Destroy()
                end)
            end
            if data.billboard then
                pcall(function()
                    data.billboard:Destroy()
                end)
            end
            if data.tracer then
                pcall(function()
                    data.tracer:Destroy()
                end)
            end
            espState.entries[player] = nil
        end
    end

    for player, data in pairs(espState.entries) do
        if not seen[player] then
            if data.highlight then
                pcall(function()
                    data.highlight:Destroy()
                end)
            end
            if data.billboard then
                pcall(function()
                    data.billboard:Destroy()
                end)
            end
            if data.tracer then
                pcall(function()
                    data.tracer:Destroy()
                end)
            end
            espState.entries[player] = nil
        end
    end
end

----------------------------------------------------------------------------
-- visuals (client-only, fully reversible)
----------------------------------------------------------------------------

local visualDefaults = nil
local atmosphereStore = {}

local function saveVisuals()
    if visualDefaults then
        return
    end
    visualDefaults = {
        brightness = Lighting.Brightness,
        clockTime = Lighting.ClockTime,
        ambient = Lighting.Ambient,
        outdoorAmbient = Lighting.OutdoorAmbient,
        globalShadows = Lighting.GlobalShadows,
        fogStart = Lighting.FogStart,
        fogEnd = Lighting.FogEnd,
        fogColor = Lighting.FogColor,
        exposure = Lighting.ExposureCompensation,
        environmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
        environmentSpecularScale = Lighting.EnvironmentSpecularScale,
    }
end

local function setFullbright(on)
    saveVisuals()
    if on then
        pcall(function()
            Lighting.Brightness = 3
            Lighting.ClockTime = 13.5
            Lighting.Ambient = Color3.fromRGB(190, 195, 210)
            Lighting.OutdoorAmbient = Color3.fromRGB(190, 195, 210)
            Lighting.GlobalShadows = false
            Lighting.EnvironmentDiffuseScale = 1
            Lighting.EnvironmentSpecularScale = 1
        end)
        for _, atmo in ipairs(Lighting:GetChildren()) do
            if atmo:IsA("Atmosphere") and not atmosphereStore[atmo] then
                atmosphereStore[atmo] = atmo.Density
                pcall(function()
                    atmo.Density = 0
                    atmo.Haze = 0
                end)
            end
        end
    else
        if visualDefaults then
            pcall(function()
                Lighting.Brightness = visualDefaults.brightness
                Lighting.ClockTime = visualDefaults.clockTime
                Lighting.Ambient = visualDefaults.ambient
                Lighting.OutdoorAmbient = visualDefaults.outdoorAmbient
                Lighting.GlobalShadows = visualDefaults.globalShadows
                Lighting.EnvironmentDiffuseScale = visualDefaults.environmentDiffuseScale
                Lighting.EnvironmentSpecularScale = visualDefaults.environmentSpecularScale
            end)
        end
        for atmo, density in pairs(atmosphereStore) do
            if atmo and atmo.Parent then
                pcall(function()
                    atmo.Density = density
                end)
            end
        end
        atmosphereStore = {}
    end
end

local function setNoFog(on)
    saveVisuals()
    pcall(function()
        if on then
            Lighting.FogStart = 1000000
            Lighting.FogEnd = 1000000
        elseif visualDefaults then
            Lighting.FogStart = visualDefaults.fogStart
            Lighting.FogEnd = visualDefaults.fogEnd
            Lighting.FogColor = visualDefaults.fogColor
        end
    end)
end

local function setExposure(value)
    pcall(function()
        Lighting.ExposureCompensation = value
    end)
end

local function setFov(value)
    local camera = workspace.CurrentCamera
    if camera then
        pcall(function()
            camera.FieldOfView = value
        end)
    end
end

----------------------------------------------------------------------------
-- movement
----------------------------------------------------------------------------

local move = {
    speed = 16,
    jump = 50,
    fly = false,
    flySpeed = 60,
    noclip = false,
    infiniteJump = false,
}

local function applySpeed()
    local hum = humanoid()
    if hum then
        pcall(function()
            hum.WalkSpeed = move.speed
        end)
    end
end

local function applyJump()
    local hum = humanoid()
    if hum then
        pcall(function()
            hum.UseJumpPower = true
            hum.JumpPower = move.jump
        end)
    end
end

-- fly: scripted orbit around the camera. platform stand keeps the humanoid
-- from fighting the CFrame writes.
local flyConn = nil
local function setFly(on)
    move.fly = on
    if flyConn then
        pcall(function()
            flyConn:Disconnect()
        end)
        flyConn = nil
    end

    local hum = humanoid()
    if hum then
        pcall(function()
            hum.PlatformStand = on
        end)
    end

    if not on then
        return
    end

    flyConn = RunService.RenderStepped:Connect(function()
        local part = root()
        local cam = workspace.CurrentCamera
        local hum2 = humanoid()
        if not part or not cam or not hum2 then
            return
        end

        local direction = Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then
            direction = direction + cam.CFrame.LookVector
        end
        if UIS:IsKeyDown(Enum.KeyCode.S) then
            direction = direction - cam.CFrame.LookVector
        end
        if UIS:IsKeyDown(Enum.KeyCode.D) then
            direction = direction + cam.CFrame.RightVector
        end
        if UIS:IsKeyDown(Enum.KeyCode.A) then
            direction = direction - cam.CFrame.RightVector
        end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then
            direction = direction + Vector3.new(0, 1, 0)
        end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
            direction = direction - Vector3.new(0, 1, 0)
        end

        if direction.Magnitude > 0 then
            part.CFrame = part.CFrame + direction.Unit * move.flySpeed * (1 / 60)
        end
        hum2.PlatformStand = true
    end)
end

-- noclip needs to remember what it broke. without a snapshot, toggling off
-- leaves every part un-collidable and you fall through the map forever.
local collisionSnapshot = {}

local function setNoclip(on)
    move.noclip = on

    if on then
        return
    end

    local char = character()
    local parts = {}
    if char then
        parts = char:GetDescendants()
    end
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") then
            local original = collisionSnapshot[part]
            pcall(function()
                part.CanCollide = (original == nil) and true or original
            end)
        end
    end
    collisionSnapshot = {}
end

local function teleportTo(player)
    local myRoot = root()
    local theirChar = player.Character
    if not myRoot or not theirChar then
        setStatus("teleport: no character", COL.amber)
        return
    end
    local theirRoot = theirChar:FindFirstChild("HumanoidRootPart")
    if not theirRoot then
        setStatus("teleport: target has no root", COL.amber)
        return
    end
    pcall(function()
        myRoot.CFrame = theirRoot.CFrame + Vector3.new(0, 1, 0)
    end)
    setStatus("teleported to " .. player.Name, COL.green)
end

local function spectate(player)
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    pcall(function()
        camera.CameraSubject = player.Character
            and player.Character:FindFirstChildOfClass("Humanoid")
            or nil
        camera.CameraType = Enum.CameraType.Follow
    end)
    setStatus("spectating " .. player.Name, COL.green)
end

----------------------------------------------------------------------------
-- spoof: fire a remote's own client handlers, locally
----------------------------------------------------------------------------

-- the server never sees this. RemoteEvent.OnClientEvent handlers are just
-- lua closures sitting in the client; getconnections hands them over and we
-- call them with whatever we like.
local function clientHandlerCount(inst)
    if not have("getconnections") then
        return 0
    end
    local signal = nil
    pcall(function()
        if inst.ClassName == "RemoteEvent" or inst.ClassName == "UnreliableRemoteEvent" then
            signal = inst.OnClientEvent
        elseif inst.ClassName == "BindableEvent" then
            signal = inst.Event
        end
    end)
    if not signal then
        return 0
    end
    local list = try(EXEC.getconnections, signal)
    if type(list) ~= "table" then
        return 0
    end
    return #list
end

local function spoof(inst, args)
    if not inst then
        return 0, "no remote"
    end
    if not have("getconnections") then
        return 0, "getconnections unavailable"
    end

    local signal = nil
    pcall(function()
        if inst.ClassName == "RemoteEvent" or inst.ClassName == "UnreliableRemoteEvent" then
            signal = inst.OnClientEvent
        elseif inst.ClassName == "BindableEvent" then
            signal = inst.Event
        end
    end)

    if not signal then
        return 0, "not a client event"
    end

    local list = try(EXEC.getconnections, signal)
    if type(list) ~= "table" then
        return 0, "getconnections returned nothing"
    end

    local fired = 0
    for _, conn in ipairs(list) do
        -- executors disagree on the call shape. delta wants conn.Fire(args),
        -- some hand out a plain function. try both before giving up.
        local ok = pcall(function()
            conn.Fire(unpack(args))
        end)
        if not ok and type(conn) == "function" then
            ok = pcall(conn, unpack(args))
        end
        if not ok then
            ok = pcall(function()
                conn.Fire(conn, unpack(args))
            end)
        end
        if ok then
            fired = fired + 1
        end
    end

    return fired, nil
end

-- args come in as a lua expression so anything is expressible:
--   "hello"            one string
--   "a", 5, Vector3.new(0,1,0)
local function parseArgs(text)
    if not text or text == "" then
        return {}
    end
    if not have("loadstring") then
        return nil, "loadstring unavailable"
    end
    local chunk = EXEC.loadstring("return " .. text)
    if not chunk then
        return nil, "could not parse args"
    end

    -- table.pack keeps every return value, so `1, "finale"` becomes two args
    -- instead of silently dropping the second one
    local packed = table.pack(pcall(chunk))
    if not packed[1] then
        return nil, tostring(packed[2])
    end

    local args = {}
    for index = 2, packed.n do
        args[#args + 1] = packed[index]
    end

    if #args == 1 and type(args[1]) == "table" then
        return args[1]
    end
    return args
end

----------------------------------------------------------------------------
-- logger
----------------------------------------------------------------------------

local log = {
    active = false,
    records = {},
    max = 60,
    wrapper = nil,
    original = nil,
}

local function describe(value, depth)
    depth = depth or 0
    local kind = typeof(value)
    if kind == "Instance" then
        local ok, name = pcall(function()
            return value:GetFullName()
        end)
        return (ok and name) or "<instance>"
    elseif kind == "table" then
        if depth > 1 then
            return "{...}"
        end
        local parts = {}
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            if count > 5 then
                parts[#parts + 1] = "..."
                break
            end
            parts[#parts + 1] = tostring(key) .. "=" .. describe(item, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif kind == "string" then
        if #value > 40 then
            return string.format("%q...", string.sub(value, 1, 37))
        end
        return string.format("%q", value)
    end
    return tostring(value)
end

local function logLine(record)
    return ("%s:%s(%s)"):format(
        record.name,
        record.method,
        table.concat(record.args, ", ")
    )
end

local function startLog()
    if log.active then
        return true
    end

    -- re-arming after a stop: the hook is still on the metatable, so flipping
    -- the flag is enough. re-hooking here would stack wrappers and log twice.
    if log.wrapper and log.original then
        log.active = true
        return true
    end

    if not have("hookmetamethod") or not have("getnamecallmethod") then
        setStatus("no hookmetamethod — logger off", COL.amber)
        return false
    end

    local methodFn = EXEC.getnamecallmethod

    local wrapper = function(self, ...)
        -- the hook stays installed after stopLog (removal is executor-specific),
        -- so the flag is the actual switch. without this check, "logger off"
        -- kept recording every remote call forever.
        if not log.active then
            return log.original(self, ...)
        end

        local method = methodFn()
        if method == "FireServer" or method == "InvokeServer" then
            local okType, kind = pcall(typeof, self)
            if okType and kind == "Instance" then
                local okName, shortName = pcall(function()
                    return self.Name
                end)
                if okName then
                    local args = {}
                    local count = 0
                    for index = 1, select("#", ...) do
                        count = count + 1
                        if count > 6 then
                            args[#args + 1] = "..."
                            break
                        end
                        args[#args + 1] = describe((select(index, ...)))
                    end

                    table.insert(log.records, 1, {
                        name = shortName,
                        path = (function()
                            local ok, full = pcall(function()
                                return self:GetFullName()
                            end)
                            return (ok and full) or shortName
                        end)(),
                        method = method,
                        args = args,
                    })
                    while #log.records > log.max do
                        table.remove(log.records)
                    end
                end
            end
        end
        return log.original(self, ...)
    end

    local ok, original = pcall(EXEC.hookmetamethod, game, "__namecall", wrapper)
    if not ok or type(original) ~= "function" then
        setStatus("logger hook failed", COL.red)
        return false
    end

    log.wrapper = wrapper
    log.original = original
    log.active = true
    return true
end

local function stopLog()
    log.active = false

    -- the flag is the real switch; the metatable restore is a courtesy. only
    -- clear the handle when the restore actually landed, otherwise re-arming
    -- would think the hook is gone and silently log nothing.
    local restored = false
    if log.wrapper and have("getrawmetatable") and have("setreadonly") then
        pcall(function()
            local mt = EXEC.getrawmetatable(game)
            if mt and rawget(mt, "__namecall") == log.wrapper then
                EXEC.setreadonly(mt, false)
                rawset(mt, "__namecall", log.original)
                EXEC.setreadonly(mt, true)
                restored = true
            end
        end)
    end

    if restored then
        log.wrapper = nil
        log.original = nil
    end
end

----------------------------------------------------------------------------
-- infected detection
--
-- deadshift's own internals name the L4D2 cast — the recon report lists
-- BoomerApprovedData, ChargerApprovedData, HunterApprovedData, JockeyApprovedData,
-- SmokerApprovedData and TankV2ApprovedData as top-level ReplicatedStorage
-- folders, plus a "Zombie Survival Animation Pack (R15)". so the infected are
-- the usual six. in versus they are PLAYERS wearing those classes, in survival
-- they are npc models in workspace. both get handled.
----------------------------------------------------------------------------

local INFECTED_WORDS = {
    "boomer", "charger", "hunter", "jockey", "smoker", "tank",
    "spitter", "witch", "zombie", "infected", "special", "horde", "common",
}

local function looksInfected(text)
    local lowered = string.lower(tostring(text or ""))
    for _, word in ipairs(INFECTED_WORDS) do
        if string.find(lowered, word, 1, true) then
            return true
        end
    end
    return false
end

local function playerInfected(player)
    if not player then
        return false
    end

    local okTeam, team = pcall(function()
        return player.Team
    end)
    if okTeam and team and looksInfected(team.Name) then
        return true
    end

    local char = player.Character
    if not char then
        return false
    end
    if looksInfected(char.Name) then
        return true
    end
    for _, child in ipairs(char:GetChildren()) do
        if looksInfected(child.Name) then
            return true
        end
    end
    return false
end

local function isPlayerCharacter(model)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character == model then
            return player
        end
    end
    return nil
end

-- workspace descendant walk is the only reliable way to find npc infected —
-- the report shows them as plain workspace models, not under a known folder.
-- throttled hard, because a full walk on a 6k-part map is not cheap on mobile.
local npcCache = {}
local npcCacheAt = 0

local function scanNpcInfected()
    local clock = wallNow()
    if clock - npcCacheAt < 2.5 then
        return npcCache
    end
    npcCacheAt = clock

    local list = {}
    local ok, descendants = pcall(function()
        return workspace:GetDescendants()
    end)
    if not ok or type(descendants) ~= "table" then
        return npcCache
    end

    for _, inst in ipairs(descendants) do
        if inst:IsA("Humanoid") then
            local model = inst.Parent
            if model and model:IsA("Model")
                and not isPlayerCharacter(model)
                and inst.Health > 0 then
                list[#list + 1] = model
            end
        end
    end

    npcCache = list
    return list
end

----------------------------------------------------------------------------
-- infected esp
----------------------------------------------------------------------------

local zombEsp = {
    enabled = false,
    npcOnly = false,
    showHealth = true,
    showDistance = true,
    maxDistance = 900,
    entries = {},
}

local function clearZombEsp()
    for key, data in pairs(zombEsp.entries) do
        for _, inst in ipairs({ data.highlight, data.billboard }) do
            if inst then
                pcall(function()
                    inst:Destroy()
                end)
            end
        end
        zombEsp.entries[key] = nil
    end
end

local function makeMarker(model, label, color)
    local highlight = Instance.new("Highlight")
    highlight.Name = "ds_zomb"
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = color
    highlight.FillTransparency = 0.6
    highlight.OutlineColor = color
    highlight.OutlineTransparency = 0.1

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ds_zomb"
    billboard.Size = UDim2.fromOffset(130, 32)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 5000

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, 0, 0, 14)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 12
    nameLabel.TextColor3 = color
    nameLabel.TextStrokeTransparency = 0.35
    nameLabel.Text = label
    nameLabel.Parent = billboard

    local infoLabel = Instance.new("TextLabel")
    infoLabel.Position = UDim2.fromOffset(0, 14)
    infoLabel.Size = UDim2.new(1, 0, 0, 12)
    infoLabel.BackgroundTransparency = 1
    infoLabel.Font = Enum.Font.Code
    infoLabel.TextSize = 10
    infoLabel.TextColor3 = COL.sub
    infoLabel.TextStrokeTransparency = 0.35
    infoLabel.Text = ""
    infoLabel.Parent = billboard

    pcall(function()
        highlight.Parent = model
        billboard.Parent = model
    end)

    return {
        highlight = highlight,
        billboard = billboard,
        infoLabel = infoLabel,
    }
end

local function classColor(name)
    local lowered = string.lower(tostring(name or ""))
    if string.find(lowered, "tank", 1, true) then
        return Color3.fromRGB(255, 96, 96)
    elseif string.find(lowered, "witch", 1, true) then
        return Color3.fromRGB(255, 150, 220)
    elseif string.find(lowered, "hunter", 1, true) then
        return Color3.fromRGB(150, 210, 255)
    elseif string.find(lowered, "smoker", 1, true) then
        return Color3.fromRGB(170, 255, 180)
    elseif string.find(lowered, "boomer", 1, true) then
        return Color3.fromRGB(200, 255, 120)
    elseif string.find(lowered, "charger", 1, true) then
        return Color3.fromRGB(255, 190, 110)
    elseif string.find(lowered, "jockey", 1, true) then
        return Color3.fromRGB(230, 180, 255)
    elseif string.find(lowered, "spitter", 1, true) then
        return Color3.fromRGB(140, 255, 130)
    end
    return Color3.fromRGB(190, 255, 120)
end

local function syncZombEsp()
    if not zombEsp.enabled then
        clearZombEsp()
        return
    end

    local myRoot = root()
    local myPos = myRoot and myRoot.Position or nil
    local seen = {}

    local function consider(key, model, label, color)
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then
            return
        end

        local okPart, pivot = pcall(function()
            return model:GetPivot().Position
        end)
        local pos = okPart and pivot or nil

        local distance = 0
        if myPos and pos then
            distance = (pos - myPos).Magnitude
        end
        if distance > zombEsp.maxDistance then
            return
        end

        seen[key] = true
        local data = zombEsp.entries[key]
        if not data then
            data = makeMarker(model, label, color)
            zombEsp.entries[key] = data
        elseif data.highlight and data.highlight.Parent ~= model then
            pcall(function()
                data.highlight.Parent = model
                data.billboard.Parent = model
            end)
        end

        if data and data.infoLabel then
            local bits = {}
            if zombEsp.showHealth then
                bits[#bits + 1] = ("%d hp"):format(math.floor(humanoid.Health))
            end
            if zombEsp.showDistance then
                bits[#bits + 1] = ("%d studs"):format(math.floor(distance))
            end
            data.infoLabel.Text = table.concat(bits, "  ")
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and zombEsp.npcOnly ~= true then
            local char = player.Character
            if char and playerInfected(player) then
                local teamName = "infected"
                pcall(function()
                    if player.Team then
                        teamName = player.Team.Name
                    end
                end)
                consider("p:" .. player.Name, char, player.Name .. "  [" .. teamName .. "]",
                    classColor(teamName .. " " .. char.Name))
            end
        end
    end

    for _, model in ipairs(scanNpcInfected()) do
        consider("n:" .. model:GetFullName(), model, model.Name, classColor(model.Name))
    end

    for key, data in pairs(zombEsp.entries) do
        if not seen[key] then
            for _, inst in ipairs({ data.highlight, data.billboard }) do
                if inst then
                    pcall(function()
                        inst:Destroy()
                    end)
                end
            end
            zombEsp.entries[key] = nil
        end
    end
end

----------------------------------------------------------------------------
-- combat: aim assist + the game's own fire button
--
-- the game already paints its mobile controls into PlayerGui, which means the
-- fire path is a normal TextButton handler we can poke. that is worth more than
-- guessing at DeadshiftPrototype.Action's payload — it fires exactly what the
-- game fires when a thumb hits the button.
----------------------------------------------------------------------------

local function guiButton(name)
    local playerGui = lp:FindFirstChild("PlayerGui")
    if not playerGui then
        return nil
    end
    local ok, found = pcall(function()
        return playerGui:FindFirstChild(name, true)
    end)
    return (ok and found) or nil
end

local function pressButton(button)
    if not button then
        return false
    end

    if have("getconnections") then
        local list = nil
        pcall(function()
            list = EXEC.getconnections(button.Activated)
        end)
        if type(list) == "table" and #list > 0 then
            local pressed = false
            for _, conn in ipairs(list) do
                local ok = pcall(function()
                    conn.Fire()
                end)
                if ok then
                    pressed = true
                end
            end
            if pressed then
                return true
            end
        end
    end

    local ok = pcall(function()
        button.MouseButton1Click:Fire()
    end)
    return ok
end

local aim = {
    enabled = false,
    fov = 260,
    smooth = 0.25,
    wallCheck = true,
    teamCheck = true,
    infectedOnly = true,
    autoFire = false,
    fireDelay = 0.1,
    maxRange = 800,
}

local lastFire = 0
local aimTargetName = nil

local function collectTargets()
    local list = {}
    local fallbacks = {}
    local myTeam = nil
    local anyInfectedPlayer = false
    pcall(function()
        myTeam = lp.Team
    end)

    local function sameTeam(player)
        if not myTeam then
            return false
        end
        local theirTeam = nil
        pcall(function()
            theirTeam = player.Team
        end)
        return theirTeam == myTeam
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp then
            local char = player.Character
            if char then
                local humanoid = char:FindFirstChildOfClass("Humanoid")
                local part = char:FindFirstChild("HumanoidRootPart")
                    or char:FindFirstChild("Head")
                if humanoid and part and humanoid.Health > 0 then
                    local infected = playerInfected(player)
                    if infected then
                        anyInfectedPlayer = true
                    end

                    local entry = {
                        part = part,
                        label = player.Name,
                        infected = infected,
                        model = char,
                    }

                    if aim.teamCheck and sameTeam(player) then
                        -- never
                    elseif aim.infectedOnly and not infected then
                        table.insert(fallbacks, entry)
                    else
                        table.insert(list, entry)
                    end
                end
            end
        end
    end

    -- class detection can miss (team not named "infected", no special children).
    -- if the server shows no infected players at all, do not sit there aiming at
    -- nothing — fall back to whoever is not on your team.
    if aim.infectedOnly and not anyInfectedPlayer then
        for _, entry in ipairs(fallbacks) do
            table.insert(list, entry)
        end
    end

    for _, model in ipairs(scanNpcInfected()) do
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        local part = model:FindFirstChild("Head")
            or model:FindFirstChild("HumanoidRootPart")
        if humanoid and part and humanoid.Health > 0 then
            list[#list + 1] = {
                part = part,
                label = model.Name,
                infected = true,
                model = model,
            }
        end
    end

    return list
end

local function raycastParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local char = character()
    if char then
        ignore[#ignore + 1] = char
    end
    local camera = workspace.CurrentCamera
    if camera then
        ignore[#ignore + 1] = camera
    end
    params.FilterDescendantsInstances = ignore
    return params
end

local function hasLineOfSight(fromPos, toPart)
    if not aim.wallCheck then
        return true
    end
    local ok, result = pcall(function()
        return workspace:Raycast(fromPos, toPart.Position - fromPos, raycastParams())
    end)
    if not ok then
        return true
    end
    if not result then
        return true
    end
    -- a hit is only a wall if it is not the target's own character
    return result.Instance and result.Instance:IsDescendantOf(toPart.Parent)
end

local function closestTarget(camera, center)
    local best = nil
    local bestScore = math.huge

    for _, target in ipairs(collectTargets()) do
        local ok, point, onScreen = pcall(function()
            return camera:WorldToViewportPoint(target.part.Position)
        end)
        if ok and onScreen and point.Z > 0 then
            local screenPos = Vector2.new(point.X, point.Y)
            local distance = (screenPos - center).Magnitude
            if distance <= aim.fov then
                local angle = (target.part.Position - camera.CFrame.Position).Magnitude
                if angle <= aim.maxRange and distance < bestScore then
                    if hasLineOfSight(camera.CFrame.Position, target.part) then
                        bestScore = distance
                        best = target
                    end
                end
            end
        end
    end

    return best, bestScore
end

local function aimStep()
    if not aim.enabled then
        aimTargetName = nil
        return
    end

    local camera = workspace.CurrentCamera
    if not camera then
        return
    end

    local viewport = camera.ViewportSize
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local target, score = closestTarget(camera, center)

    if not target then
        aimTargetName = nil
        return
    end

    aimTargetName = target.label

    local goal = CFrame.lookAt(camera.CFrame.Position, target.part.Position)
    camera.CFrame = camera.CFrame:Lerp(goal, math.clamp(aim.smooth, 0.02, 1))

    if aim.autoFire then
        local clock = wallNow()
        if clock - lastFire >= aim.fireDelay then
            local ok = pressButton(guiButton("DSFire"))
            if ok then
                lastFire = clock
            end
        end
    end
end

----------------------------------------------------------------------------
-- render loop
----------------------------------------------------------------------------

local lastEsp = 0
local lastZombEsp = 0
local lastNoclip = 0

task.spawn(function()
    while screen and screen.Parent do
        local now = wallNow()

        if espState.enabled and now - lastEsp > 0.25 then
            lastEsp = now
            pcall(syncEsp)
        end

        if now - lastZombEsp > 0.3 then
            lastZombEsp = now
            if zombEsp.enabled then
                pcall(syncZombEsp)
            end
        end

        if move.noclip and now - lastNoclip > 0.1 then
            lastNoclip = now
            local char = character()
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        -- snapshot once, so setNoclip(false) can put it back
                        if collisionSnapshot[part] == nil then
                            collisionSnapshot[part] = part.CanCollide
                        end
                        pcall(function()
                            part.CanCollide = false
                        end)
                    end
                end
            end
        end

        RunService.RenderStepped:Wait()
    end
end)

-- camera writes have to land AFTER the game's own camera script, or it stomps
-- them on the same frame. Camera priority + 1 is the correct slot.
local AIM_BIND = "deadshift_aim"
pcall(function()
    RunService:UnbindFromRenderStep(AIM_BIND)
end)
pcall(function()
    RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, function()
        pcall(aimStep)
    end)
end)

keep(UIS.JumpRequest:Connect(function()
    if not move.infiniteJump then
        return
    end
    local hum = humanoid()
    if hum then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end)
    end
end))

keep(lp.CharacterAdded:Connect(function()
    task.wait(1)
    pcall(applySpeed)
    pcall(applyJump)
    if move.fly then
        setFly(true)
    end
end))

----------------------------------------------------------------------------
-- build the pages
----------------------------------------------------------------------------

makePage("esp")
makePage("zomb")
makePage("combat")
makePage("vis")
makePage("move")
makePage("spoof")
makePage("log")
makePage("srv")

for index, name in ipairs(TABS) do
    local button = makeTab(name, index)
    button.Activated:Connect(function()
        showTab(name)
    end)
end

----------------------------------------------------------------------------
-- ESP page
----------------------------------------------------------------------------

sectionRule("players")(("esp"))

toggle("esp", "player esp", false, function(on)
    espState.enabled = on
    if not on then
        clearEsp()
    else
        syncEsp()
    end
    setStatus(on and "esp on" or "esp off", on and COL.green or COL.sub)
end)

slider("esp", "max distance", 100, 5000, espState.maxDistance, 50, function(value)
    espState.maxDistance = value
    for _, data in pairs(espState.entries) do
        if data.billboard then
            pcall(function()
                data.billboard.MaxDistance = value
            end)
        end
    end
end)

toggle("esp", "tracers", false, function(on)
    espState.tracers = on
    if espState.enabled then
        clearEsp()
        syncEsp()
    end
end)

action("esp", "refresh", COL.blue, function()
    if espState.enabled then
        clearEsp()
        syncEsp()
    end
    setStatus(("esp: %d tracked"):format((function()
        local count = 0
        for _ in pairs(espState.entries) do
            count = count + 1
        end
        return count
    end)()), COL.green)
end)

sectionRule("teleport")(("esp"))

-- the roster changes every round. buttons are rebuilt into their own container
-- on join/leave instead of being frozen at inject time, which is what made half
-- the lobby unreachable after the first round started.
local teleportHost = new("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = nextOrder(pages.esp),
}, pages.esp.frame)
new("UIListLayout", {
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, teleportHost)

local function rebuildTeleportButtons()
    for _, child in ipairs(teleportHost:GetChildren()) do
        if child:IsA("TextButton") then
            pcall(function()
                child:Destroy()
            end)
        end
    end

    local index = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp then
            index = index + 1
            local target = player
            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 26),
                BackgroundColor3 = COL.violet,
                BackgroundTransparency = 0.84,
                BorderSizePixel = 0,
                Text = "→ " .. player.Name,
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                TextColor3 = COL.text,
                AutoButtonColor = false,
                Active = true,
                LayoutOrder = index,
            }, teleportHost)
            new("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
            new("UIStroke", {
                Color = COL.violet,
                Transparency = 0.6,
                Thickness = 1,
            }, button)

            button.Activated:Connect(function()
                local ok, err = pcall(teleportTo, target)
                if not ok then
                    setStatus(tostring(err), COL.red)
                end
            end)
        end
    end
end

rebuildTeleportButtons()

keep(Players.PlayerAdded:Connect(function()
    task.wait(0.5)
    pcall(rebuildTeleportButtons)
end))

keep(Players.PlayerRemoving:Connect(function()
    task.wait(0.2)
    pcall(rebuildTeleportButtons)
end))

action("esp", "spectate nearest", COL.blue, function()
    local myRoot = root()
    if not myRoot then
        return
    end
    local best = nil
    local bestDistance = math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and player.Character then
            local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
            if theirRoot then
                local distance = (theirRoot.Position - myRoot.Position).Magnitude
                if distance < bestDistance then
                    bestDistance = distance
                    best = player
                end
            end
        end
    end
    if best then
        spectate(best)
    else
        setStatus("nobody to spectate", COL.amber)
    end
end)

----------------------------------------------------------------------------
-- zomb page
----------------------------------------------------------------------------

sectionRule("infected")(("zomb"))

note("zomb",
    "highlights every infected the client can see: players wearing a special " ..
    "class, and npc models in workspace with a live humanoid. coloured by class " ..
    "— tank red, hunter blue, smoker green, witch pink.",
    COL.sub)

toggle("zomb", "infected esp", false, function(on)
    zombEsp.enabled = on
    if not on then
        clearZombEsp()
        setStatus("infected esp off", COL.sub)
    else
        syncZombEsp()
        local count = 0
        for _ in pairs(zombEsp.entries) do
            count = count + 1
        end
        setStatus(("infected esp on — %d visible"):format(count), COL.green)
    end
end)

toggle("zomb", "skip players (npc only)", false, function(on)
    zombEsp.npcOnly = on
    if zombEsp.enabled then
        clearZombEsp()
        syncZombEsp()
    end
end)

toggle("zomb", "show health", true, function(on)
    zombEsp.showHealth = on
end)

toggle("zomb", "show distance", true, function(on)
    zombEsp.showDistance = on
end)

slider("zomb", "max distance", 100, 3000, 900, 50, function(value)
    zombEsp.maxDistance = value
end)

action("zomb", "count infected", COL.cyan, function()
    local players = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and playerInfected(player) then
            players = players + 1
        end
    end
    local npcs = #scanNpcInfected()
    setStatus(("infected: %d players, %d npcs"):format(players, npcs), COL.cyan)
end)

action("zomb", "list names", COL.violet, function()
    local names = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and playerInfected(player) then
            names[#names + 1] = "P:" .. player.Name
        end
    end
    local npcCount = 0
    for _, model in ipairs(scanNpcInfected()) do
        npcCount = npcCount + 1
        if npcCount <= 8 then
            names[#names + 1] = "N:" .. model.Name
        end
    end
    if #names == 0 then
        setStatus("nothing infected in range — try during a round", COL.amber)
    else
        if have("setclipboard") then
            pcall(EXEC.setclipboard, table.concat(names, ", "))
        end
        setStatus(table.concat(names, ", "), COL.violet)
    end
end)

----------------------------------------------------------------------------
-- combat page
----------------------------------------------------------------------------

sectionRule("aim")(("combat"))

note("combat",
    "moves your camera onto the closest valid target inside the fov circle, " ..
    "after the game's camera script runs. wall check raycasts before locking. " ..
    "auto fire presses the game's own DSFire button, so it is the exact same " ..
    "call your thumb makes.",
    COL.sub)

toggle("combat", "aim assist", false, function(on)
    aim.enabled = on
    setStatus(on and "aim on" or "aim off", on and COL.green or COL.sub)
end)

slider("combat", "fov", 40, 900, 260, 10, function(value)
    aim.fov = value
end)

slider("combat", "smoothness", 0.05, 1, 0.25, 0.05, function(value)
    aim.smooth = value
end)

slider("combat", "max range", 100, 3000, 800, 50, function(value)
    aim.maxRange = value
end)

toggle("combat", "wall check", true, function(on)
    aim.wallCheck = on
end)

toggle("combat", "team check", true, function(on)
    aim.teamCheck = on
end)

toggle("combat", "infected only", true, function(on)
    aim.infectedOnly = on
end)

sectionRule("fire")(("combat"))

toggle("combat", "auto fire", false, function(on)
    aim.autoFire = on
    setStatus(on and "auto fire on" or "auto fire off", on and COL.green or COL.sub)
end)

slider("combat", "fire delay", 0.02, 0.5, 0.1, 0.01, function(value)
    aim.fireDelay = value
end)

action("combat", "single shot", COL.blue, function()
    local pressed = pressButton(guiButton("DSFire"))
    setStatus(pressed and "fired" or "DSFire not found", pressed and COL.green or COL.amber)
end)

action("combat", "reload now", COL.blue, function()
    local pressed = pressButton(guiButton("DSReload"))
    setStatus(pressed and "reloaded" or "DSReload not found",
        pressed and COL.green or COL.amber)
end)

action("combat", "shove", COL.violet, function()
    local pressed = pressButton(guiButton("DSShove"))
    setStatus(pressed and "shoved" or "DSShove not found",
        pressed and COL.green or COL.amber)
end)

action("combat", "aim down sights", COL.violet, function()
    local pressed = pressButton(guiButton("DSAim"))
    setStatus(pressed and "ads toggled" or "DSAim not found",
        pressed and COL.green or COL.amber)
end)

action("combat", "who am i locked on", COL.cyan, function()
    if aimTargetName then
        setStatus("locked: " .. aimTargetName, COL.green)
    else
        setStatus("no target", COL.sub)
    end
end)

action("combat", "rescan buttons", COL.sub, function()
    local names = { "DSFire", "DSReload", "DSShove", "DSAim", "DSCrouch", "JumpButton" }
    local found = {}
    for _, name in ipairs(names) do
        if guiButton(name) then
            found[#found + 1] = name
        end
    end
    setStatus(#found > 0 and ("found: " .. table.concat(found, " ")) or "no combat buttons",
        #found > 0 and COL.green or COL.amber)
end)

----------------------------------------------------------------------------
-- visuals page
----------------------------------------------------------------------------

sectionRule("lighting")(("vis"))

toggle("vis", "fullbright", false, function(on)
    setFullbright(on)
    setStatus(on and "fullbright on" or "lighting restored", COL.green)
end)

toggle("vis", "no fog", false, function(on)
    setNoFog(on)
    setStatus(on and "fog cleared" or "fog restored", COL.green)
end)

slider("vis", "exposure", -3, 3, 0, 0.1, function(value)
    setExposure(value)
end)

slider("vis", "field of view", 40, 120, 70, 1, function(value)
    setFov(value)
end)

action("vis", "apply fov", COL.cyan, function()
    setFov(70)
    setStatus("fov 70", COL.cyan)
end)

sectionRule("scene")(("vis"))

action("vis", "remove atmosphere", COL.violet, function()
    local count = 0
    for _, inst in ipairs(Lighting:GetChildren()) do
        if inst:IsA("Atmosphere") then
            pcall(function()
                inst.Density = 0
                count = count + 1
            end)
        end
    end
    setStatus(("atmosphere muted: %d"):format(count), COL.violet)
end)

action("vis", "remove blur", COL.violet, function()
    local count = 0
    for _, inst in ipairs(Lighting:GetChildren()) do
        if inst:IsA("BlurEffect") then
            pcall(function()
                inst:Destroy()
                count = count + 1
            end)
        end
    end
    setStatus(("blur removed: %d"):format(count), COL.violet)
end)

action("vis", "remove color correction", COL.violet, function()
    local count = 0
    for _, inst in ipairs(Lighting:GetChildren()) do
        if inst:IsA("ColorCorrectionEffect") or inst:IsA("BloomEffect") then
            pcall(function()
                inst.Enabled = false
                count = count + 1
            end)
        end
    end
    setStatus(("effects off: %d"):format(count), COL.violet)
end)

----------------------------------------------------------------------------
-- movement page
----------------------------------------------------------------------------

sectionRule("speed")(("move"))

slider("move", "walk speed", 8, 200, 16, 1, function(value)
    move.speed = value
    applySpeed()
end)

slider("move", "jump power", 50, 400, 50, 5, function(value)
    move.jump = value
    applyJump()
end)

toggle("move", "infinite jump", false, function(on)
    move.infiniteJump = on
    setStatus(on and "infinite jump on" or "infinite jump off",
        on and COL.green or COL.sub)
end)

sectionRule("flight")(("move"))

toggle("move", "fly", false, function(on)
    setFly(on)
    setStatus(on and "fly on — wasd + space" or "fly off", on and COL.green or COL.sub)
end)

slider("move", "fly speed", 10, 300, 60, 5, function(value)
    move.flySpeed = value
end)

toggle("move", "noclip", false, function(on)
    setNoclip(on)
    setStatus(on and "noclip on" or "noclip off", on and COL.green or COL.sub)
end)

sectionRule("state")(("move"))

action("move", "reapply character", COL.blue, function()
    applySpeed()
    applyJump()
    setStatus("speed + jump reapplied", COL.blue)
end)

action("move", "reset camera", COL.violet, function()
    local camera = workspace.CurrentCamera
    local char = character()
    if camera and char then
        pcall(function()
            camera.CameraSubject = char:FindFirstChildOfClass("Humanoid")
            camera.CameraType = Enum.CameraType.Custom
        end)
    end
    setStatus("camera reset", COL.violet)
end)

----------------------------------------------------------------------------
-- spoof page
----------------------------------------------------------------------------

sectionRule("client-side only")(("spoof"))

note("spoof",
    "fires a remote's OWN OnClientEvent handlers with the args below. " ..
    "the server never sees it — fake kill feed, fake announcements, fake " ..
    "damage markers, free. needs getconnections.",
    COL.sub)

local SPOOF_TARGETS = {
    { label = "kill feed", key = "killFeed", default = '"ollie", "server", "Hunter"' },
    { label = "announcement", key = "announcement", default = '"ollie was here"' },
    { label = "npc say", key = "npcSay", default = '"he is behind you"' },
    { label = "damage marker", key = "damageDir", default = "Vector3.new(1, 0, 0)" },
    { label = "cutscene", key = "chapterCutscene", default = '"finale"' },
    { label = "chapter status", key = "chapterStatus", default = "1, \"finale\"" },
    { label = "interaction", key = "interaction", default = '"picked up"' },
    { label = "local sfx", key = "localSfx", default = '"rbxassetid://9118823101"' },
    { label = "solo chance", key = "soloChance", default = "true" },
    { label = "classes stand", key = "classesStand", default = "true" },
    { label = "load gate", key = "loadGate", default = "false" },
}

local spoofArgs = input("spoof", "args, lua expression", '"ollie was here"')
spoofArgs.Size = UDim2.new(1, -16, 0, 30)

for _, target in ipairs(SPOOF_TARGETS) do
    local fake = target
    action("spoof", "spoof " .. fake.label, COL.violet, function()
        local inst = remote(fake.key)
        if not inst then
            setStatus("missing: " .. fake.key, COL.amber)
            return
        end
        local args, err = parseArgs(spoofArgs.Text ~= "" and spoofArgs.Text or fake.default)
        if not args then
            setStatus(err or "bad args", COL.red)
            return
        end
        local fired, reason = spoof(inst, args)
        if fired > 0 then
            setStatus(("fired %d handler(s) on %s"):format(fired, fake.key), COL.green)
        else
            setStatus(("no handlers on %s: %s"):format(fake.key, tostring(reason)), COL.amber)
        end
    end, 28)
end

action("spoof", "set default args", COL.sub, function()
    spoofArgs.Text = '"ollie was here"'
    setStatus("args reset", COL.sub)
end, 26)

sectionRule("chaos")(("spoof"))

-- fires the local handlers repeatedly. pure theatre — nothing leaves the client.
local function spam(key, count)
    local inst = remote(key)
    if not inst then
        setStatus("missing: " .. key, COL.amber)
        return
    end
    local args, err = parseArgs(spoofArgs.Text ~= "" and spoofArgs.Text or "")
    if not args then
        setStatus(err or "bad args", COL.red)
        return
    end

    local total = 0
    task.spawn(function()
        for _ = 1, count do
            local fired = spoof(inst, args)
            total = total + fired
            task.wait(0.15)
        end
        setStatus(("spammed %s x%d (%d handler calls)"):format(key, count, total), COL.violet)
    end)
    setStatus(("spamming %s..."):format(key), COL.violet)
end

action("spoof", "spam killfeed x12", COL.blood, function()
    spam("killFeed", 12)
end, 28)

action("spoof", "spam announcement x12", COL.blood, function()
    spam("announcement", 12)
end, 28)

action("spoof", "spam damage markers x20", COL.blood, function()
    spam("damageDir", 20)
end, 28)

action("spoof", "spam npc voice x16", COL.blood, function()
    spam("npcSay", 16)
end, 28)

sectionRule("handler survey")(("spoof"))

action("spoof", "survey client handlers", COL.cyan, function()
    local report = {}
    for _, target in ipairs(SPOOF_TARGETS) do
        local inst = remote(target.key)
        if inst then
            local count = clientHandlerCount(inst)
            report[#report + 1] = ("%s=%d"):format(target.key, count)
        end
    end
    setStatus(table.concat(report, "  "), COL.cyan)
end)

----------------------------------------------------------------------------
-- logger page
----------------------------------------------------------------------------

sectionRule("capture")(("log"))

note("log",
    "arms a __namecall hook that records every FireServer and InvokeServer " ..
    "with the typeof of each argument. play for a bit, then read the shapes " ..
    "off the list. tap a line to copy it.",
    COL.sub)

local logToggle
logToggle = toggle("log", "arm logger", false, function(on)
    if on then
        local started = startLog()
        if not started then
            -- no hookmetamethod in this executor; don't leave the switch lying
            if logToggle then
                logToggle.set(false)
            end
            return
        end
    else
        stopLog()
    end
    setStatus(on and "logger armed" or "logger off", on and COL.green or COL.sub)
end)

local logList = new("Frame", {
    -- the page already scrolls; a fixed-height inner frame just clipped rows.
    -- let it grow with its children instead.
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = nextOrder(pages.log),
}, pages.log.frame)
new("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, logList)

local logLabels = {}

local function renderLog()
    for _, label in ipairs(logLabels) do
        pcall(function()
            label:Destroy()
        end)
    end
    logLabels = {}

    for index, record in ipairs(log.records) do
        local label = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 14),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 10,
            TextColor3 = COL.sub,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = logLine(record),
            AutoButtonColor = false,
            Active = true,
            LayoutOrder = index,
        }, logList)

        label.Activated:Connect(function()
            if have("setclipboard") then
                pcall(EXEC.setclipboard, logLine(record))
                setStatus("copied", COL.green)
            end
        end)

        logLabels[#logLabels + 1] = label
    end
end

action("log", "refresh list", COL.blue, function()
    renderLog()
    setStatus(("%d calls recorded"):format(#log.records), COL.blue)
end)

action("log", "copy all", COL.green, function()
    local lines = {}
    for _, record in ipairs(log.records) do
        lines[#lines + 1] = ("%s  %s"):format(record.path, logLine(record))
    end
    if have("setclipboard") then
        pcall(EXEC.setclipboard, table.concat(lines, "\n"))
        setStatus(("copied %d calls"):format(#lines), COL.green)
    else
        setStatus("no setclipboard", COL.amber)
    end
end)

action("log", "clear", COL.red, function()
    log.records = {}
    renderLog()
    setStatus("log cleared", COL.red)
end)

----------------------------------------------------------------------------
-- server page
----------------------------------------------------------------------------

sectionRule("remotes")(("srv"))

action("srv", "refresh remote table", COL.cyan, function()
    local found, missing = refresh()
    if found == 0 then
        setStatus("no remotes resolved — wrong place?", COL.red)
    elseif missing > 0 then
        setStatus(("resolved %d, missing %d"):format(found, missing), COL.amber)
    else
        setStatus(("all %d remotes resolved"):format(found), COL.green)
    end
end)

sectionRule("queries")(("srv"))

action("srv", "survival leaderboard", COL.blue, function()
    local inst = remote("leaderboard")
    if not inst then
        setStatus("no leaderboard remote", COL.amber)
        return
    end
    local ok, result = pcall(function()
        return inst:InvokeServer()
    end)
    setStatus(ok and ("leaderboard: " .. describe(result)) or ("failed: " .. tostring(result)),
        ok and COL.green or COL.red)
end)

action("srv", "menu lobbies", COL.blue, function()
    local inst = remote("menuLobbies")
    if not inst then
        setStatus("no lobby remote", COL.amber)
        return
    end
    local ok, result = pcall(function()
        return inst:InvokeServer()
    end)
    setStatus(ok and ("lobbies: " .. describe(result)) or ("failed: " .. tostring(result)),
        ok and COL.green or COL.red)
end)

action("srv", "free revive", COL.green, function()
    send("freeRevive")
    setStatus("free revive fired", COL.green)
end)

action("srv", "claim community reward", COL.green, function()
    send("rewardClaim")
    setStatus("reward claim fired", COL.green)
end)

sectionRule("class")(("srv"))

local classBox = input("srv", "class name", "Rifle")
classBox.Size = UDim2.new(1, -16, 0, 30)

action("srv", "select class", COL.violet, function()
    local inst = remote("selectClass")
    if not inst then
        setStatus("no class remote", COL.amber)
        return
    end
    local ok, err = pcall(function()
        return inst:InvokeServer(classBox.Text)
    end)
    setStatus(ok and ("class -> " .. classBox.Text) or ("failed: " .. tostring(err)),
        ok and COL.green or COL.red)
end)

action("srv", "select secondary", COL.violet, function()
    local inst = remote("selectSecondary")
    if not inst then
        setStatus("no secondary remote", COL.amber)
        return
    end
    local ok, err = pcall(function()
        return inst:InvokeServer(classBox.Text)
    end)
    setStatus(ok and ("secondary -> " .. classBox.Text) or ("failed: " .. tostring(err)),
        ok and COL.green or COL.red)
end)

sectionRule("audio")(("srv"))

local sfxBox = input("srv", "sound id or asset", "rbxassetid://9118823101")
sfxBox.Size = UDim2.new(1, -16, 0, 30)

action("srv", "play local sfx", COL.blue, function()
    send("localSfx", sfxBox.Text)
    setStatus("sfx sent", COL.blue)
end)

action("srv", "npc say", COL.blue, function()
    send("npcSay", sfxBox.Text)
    setStatus("npc say sent", COL.blue)
end)

sectionRule("admin probe")(("srv"))

note("srv",
    "these four are risk 88-96 on the recon report. they will either return " ..
    "a value, return false, or drop the connection. worth one tap each.",
    COL.amber)

action("srv", "AdminGrant (no args)", COL.blood, function()
    local inst = remote("adminGrant")
    if not inst then
        setStatus("no AdminGrant", COL.amber)
        return
    end
    local finished = false
    local result = nil
    task.spawn(function()
        result = (function()
            local ok, value = pcall(function()
                return inst:InvokeServer()
            end)
            return ok and describe(value) or ("error: " .. tostring(value))
        end)()
        finished = true
    end)
    local deadline = wallNow() + 1.5
    while not finished and wallNow() < deadline do
        task.wait(0.05)
    end
    setStatus(finished and ("grant: " .. tostring(result)) or "grant: timeout (silent reject)",
        finished and COL.green or COL.amber)
end)

action("srv", "AdminLookup (self)", COL.blood, function()
    local inst = remote("adminLookup")
    if not inst then
        setStatus("no AdminLookup", COL.amber)
        return
    end
    local finished = false
    local result = nil
    task.spawn(function()
        result = (function()
            local ok, value = pcall(function()
                return inst:InvokeServer(lp.Name)
            end)
            return ok and describe(value) or ("error: " .. tostring(value))
        end)()
        finished = true
    end)
    local deadline = wallNow() + 1.5
    while not finished and wallNow() < deadline do
        task.wait(0.05)
    end
    setStatus(finished and ("lookup: " .. tostring(result)) or "lookup: timeout",
        finished and COL.green or COL.amber)
end)

action("srv", "AdminFreecam toggle", COL.blood, function()
    send("adminFreecam", true)
    setStatus("freecam request sent", COL.blood)
end)

----------------------------------------------------------------------------
-- layout
----------------------------------------------------------------------------

local collapsed = false

local function relayout()
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)

    local width = math.min(380, math.max(260, viewport.X - 16))
    local height = math.min(math.max(viewport.Y - 16, 260), 660)

    if collapsed then
        panel.Size = UDim2.fromOffset(width, HEADER_H)
        rail.Visible = false
        pageHost.Visible = false
    else
        panel.Size = UDim2.fromOffset(width, height)
        rail.Visible = true
        pageHost.Visible = true
    end

    local factor = math.min((viewport.X - 8) / width, (viewport.Y - 8) / height, 1)
    scale.Scale = math.clamp(factor, 0.45, 1)

    local abs = panel.AbsolutePosition
    if abs.X < 0 or abs.Y < 0
        or abs.X + width * scale.Scale > viewport.X
        or abs.Y + height * scale.Scale > viewport.Y then
        panel.Position = UDim2.fromOffset(8, 8)
    end
end

pcall(relayout)

collapseButton.Activated:Connect(function()
    collapsed = not collapsed
    collapseButton.Text = collapsed and "+" or "–"
    pcall(relayout)
end)

closeButton.Activated:Connect(function()
    panel.Visible = false
end)

do
    local camera = workspace.CurrentCamera
    if camera then
        keep(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            pcall(relayout)
        end))
    end
end

----------------------------------------------------------------------------
-- boot
----------------------------------------------------------------------------

showTab("esp")

do
    local found, missing = refresh()
    if found == 0 then
        setStatus("no remotes — wrong place?", COL.red)
    elseif missing > 0 then
        setStatus(("%d/%d remotes ready"):format(found, found + missing), COL.amber)
    else
        setStatus(("%d/%d remotes ready"):format(found, found + missing), COL.green)
    end
end

----------------------------------------------------------------------------
-- teardown
----------------------------------------------------------------------------

local function cleanup()
    pcall(clearEsp)
    pcall(clearZombEsp)
    aim.enabled = false
    aim.autoFire = false
    pcall(function()
        RunService:UnbindFromRenderStep(AIM_BIND)
    end)
    pcall(function()
        setFly(false)
    end)
    pcall(function()
        setFullbright(false)
        setNoFog(false)
    end)
    pcall(stopLog)

    for _, conn in ipairs(conns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    conns = {}

    if screen then
        pcall(function()
            screen:Destroy()
        end)
        screen = nil
    end
end

_G.__deadshift_cleanup = cleanup
