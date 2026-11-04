--[[
    hit.lua — hitbox · firerate · ammo · damage, with a lie detector

    every one of these four is a claim about the SERVER, not the client.
    the client can only change what it displays. so this panel doesn't
    promise anything — it ships the sliders AND measures whether the
    server actually honoured them.

    ┌─ what it does ────────────────────────────────────────────────┐
    │ hitbox scale   enlarges target parts for your own aim raycast │
    │                (aim assist only, never damage)                 │
    │ firerate       changes how often the client requests a shot    │
    │ ammo           forces the local ammo display / re-requests     │
    │ damage         multiplies the value we send, if we send one    │
    └───────────────────────────────────────────────────────────────┘

    the MEASURE button fires one shot and reports the health delta it
    observed. if 1.0x and 8.0x both take 34 HP, the server owns damage
    and no slider will change that. that is the entire test.

    remotes are discovered everywhere — including inside Tools, which
    the previous recon missed because tools live on the character, not
    in ReplicatedStorage.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__hitlua_cleanup) == "function" then
    pcall(_G.__hitlua_cleanup)
end

local connections = {}
local screen

local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then
            inst[k] = v
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local function tween(inst, goal, time)
    local tw = TweenService:Create(
        inst,
        TweenInfo.new(time or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        goal
    )
    tw:Play()
    return tw
end

local COL = {
    bg = Color3.fromRGB(14, 16, 24),
    text = Color3.fromRGB(236, 240, 250),
    sub = Color3.fromRGB(148, 157, 180),
    dim = Color3.fromRGB(110, 118, 142),
    cyan = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    pink = Color3.fromRGB(255, 122, 198),
    green = Color3.fromRGB(124, 240, 178),
    amber = Color3.fromRGB(255, 196, 108),
    danger = Color3.fromRGB(255, 108, 122),
}

-- config

local cfg = {
    hitbox = 1.0,
    damage = 1.0,
    fireDelay = 120,
    infiniteAmmo = false,
    autoEquip = true,
}

local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- gui parent

local guiParent
do
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    if ok and hui then
        guiParent = hui
    else
        local ok2, coreGui = pcall(function()
            return game:GetService("CoreGui")
        end)
        guiParent = (ok2 and coreGui) or lp:WaitForChild("PlayerGui")
    end
end

for _, child in ipairs(guiParent:GetChildren()) do
    if child.Name == "hitlua" then
        pcall(function()
            child:Destroy()
        end)
    end
end

screen = Instance.new("ScreenGui")
screen.Name = "hitlua"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9997
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = guiParent

-- panel

local panel = create("Frame", {
    Name = "panel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(316, 452),
    BackgroundTransparency = 1,
    Visible = false,
}, screen)

local fitScale = create("UIScale", { Scale = 1 }, panel)

local shadow = create("Frame", {
    Position = UDim2.fromOffset(0, 8),
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.62,
    BorderSizePixel = 0,
    ZIndex = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, shadow)

local body = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.1,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 1,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)

local bodyStroke = create("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.84,
    Thickness = 1,
}, body)
create("UIGradient", {
    Color = ColorSequence.new(COL.cyan, COL.violet, COL.pink),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(0.5, 0.95),
        NumberSequenceKeypoint.new(1, 0.6),
    }),
    Rotation = 35,
}, bodyStroke)

local orb = create("Frame", {
    Position = UDim2.fromOffset(-80, -100),
    Size = UDim2.fromOffset(210, 210),
    BackgroundColor3 = COL.violet,
    BackgroundTransparency = 0.6,
    BorderSizePixel = 0,
    ZIndex = 1,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orb)
create("UIGradient", {
    Color = ColorSequence.new(COL.violet, COL.cyan),
    Transparency = NumberSequence.new(0.3, 1),
    Rotation = 140,
}, orb)

local orb2 = create("Frame", {
    Position = UDim2.new(1, -76, 1, -66),
    Size = UDim2.fromOffset(160, 160),
    BackgroundColor3 = COL.pink,
    BackgroundTransparency = 0.7,
    BorderSizePixel = 0,
    ZIndex = 1,
}, body)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, orb2)
create("UIGradient", {
    Color = ColorSequence.new(COL.pink, COL.violet),
    Transparency = NumberSequence.new(0.45, 1),
    Rotation = 320,
}, orb2)

-- header

local header = create("TextButton", {
    Size = UDim2.new(1, 0, 0, 50),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    ZIndex = 3,
}, body)

local dragZone = create("Frame", {
    Size = UDim2.new(1, -58, 1, 0),
    BackgroundTransparency = 1,
    Active = true,
    ZIndex = 3,
}, header)

local logo = create("Frame", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.fromOffset(14, 11),
    BackgroundColor3 = COL.violet,
    BorderSizePixel = 0,
}, dragZone)
create("UICorner", { CornerRadius = UDim.new(0, 9) }, logo)
create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 40 }, logo)

create("TextLabel", {
    Position = UDim2.fromOffset(52, 10),
    Size = UDim2.fromOffset(180, 17),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "hit.lua",
    ZIndex = 4,
}, dragZone)

create("TextLabel", {
    Position = UDim2.fromOffset(52, 27),
    Size = UDim2.fromOffset(200, 13),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "tuning · with measurement",
    ZIndex = 4,
}, dragZone)

local closeButton = create("TextButton", {
    Size = UDim2.fromOffset(34, 34),
    Position = UDim2.new(1, -10, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 20,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
    ZIndex = 6,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)
create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.8, Thickness = 1 }, closeButton)

local function makeDraggable(frame, handle)
    local dragging = false
    local startPos
    local origin

    track(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startPos = input.Position
            origin = frame.Position
        end
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startPos
            frame.Position = UDim2.new(
                origin.X.Scale, origin.X.Offset + delta.X,
                origin.Y.Scale, origin.Y.Offset + delta.Y
            )
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

makeDraggable(panel, dragZone)

-- content

local content = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 50),
    Size = UDim2.new(1, 0, 1, -116),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = COL.sub,
    ScrollBarImageTransparency = 0.6,
    ZIndex = 2,
}, body)

create("UIPadding", {
    PaddingLeft = UDim.new(0, 10),
    PaddingRight = UDim.new(0, 10),
    PaddingTop = UDim.new(0, 4),
    PaddingBottom = UDim.new(0, 8),
}, content)

create("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, content)

local layoutIndex = 0
local function nextOrder()
    layoutIndex = layoutIndex + 1
    return layoutIndex
end

local function addSection(text)
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = text,
        LayoutOrder = nextOrder(),
    }, content)
end

local function makeSwitch(parent, initial)
    local trackBar = create("Frame", {
        Size = UDim2.fromOffset(40, 22),
        Position = UDim2.new(1, -14, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5),
        BackgroundColor3 = Color3.fromRGB(48, 52, 70),
        BackgroundTransparency = 0.15,
        BorderSizePixel = 0,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBar)

    local fill = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = COL.cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
    create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 20 }, fill)

    local knob = create("Frame", {
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = Color3.fromRGB(240, 244, 255),
        BorderSizePixel = 0,
    }, trackBar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

    local function set(value, animate)
        local on = value and true or false
        local goal = on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        if animate then
            tween(knob, { Position = goal }, 0.14)
            tween(fill, { BackgroundTransparency = on and 0.05 or 1 }, 0.14)
        else
            knob.Position = goal
            fill.BackgroundTransparency = on and 0.05 or 1
        end
    end

    set(initial, false)
    return set
end

local function makeToggle(title, desc, key, onChange)
    local row = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.94,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = nextOrder(),
    }, content)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, row)
    create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.92, Thickness = 1 }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(16, 6),
        Size = UDim2.fromOffset(180, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
    }, row)

    create("TextLabel", {
        Position = UDim2.fromOffset(16, 23),
        Size = UDim2.new(1, -100, 0, 13),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = desc,
    }, row)

    local set = makeSwitch(row, cfg[key])

    row.Activated:Connect(function()
        cfg[key] = not cfg[key]
        set(cfg[key], true)
        if onChange then
            onChange(cfg[key])
        end
    end)

    return row
end

local function makeSlider(title, key, min, max, step, suffix, onChange)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
    }, content)

    create("TextLabel", {
        Position = UDim2.fromOffset(14, 2),
        Size = UDim2.new(0.6, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
    }, row)

    local valueLabel = create("TextLabel", {
        Position = UDim2.new(1, -76, 0, 2),
        Size = UDim2.fromOffset(62, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(cfg[key]) .. suffix,
    }, row)

    local bar = create("Frame", {
        Position = UDim2.fromOffset(14, 34),
        Size = UDim2.new(1, -28, 0, 4),
        BackgroundColor3 = Color3.fromRGB(64, 70, 92),
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
    }, row)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)

    local fraction = (cfg[key] - min) / (max - min)
    local fill = create("Frame", {
        Size = UDim2.fromScale(fraction, 1),
        BackgroundColor3 = COL.cyan,
        BorderSizePixel = 0,
    }, bar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
    create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet) }, fill)

    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(fraction, 0, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.fromRGB(240, 244, 255),
        BorderSizePixel = 0,
    }, bar)
    create("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

    local hit = create("Frame", {
        Position = UDim2.fromOffset(4, 24),
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundTransparency = 1,
        Active = true,
    }, row)

    local dragging = false

    local function setValue(value, fire)
        value = math.clamp(value, min, max)
        if step then
            value = math.floor(value / step + 0.5) * step
        end
        cfg[key] = value
        local f = (value - min) / (max - min)
        fill.Size = UDim2.fromScale(f, 1)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valueLabel.Text = string.format("%.1f", value) .. suffix
        if fire and onChange then
            onChange(value)
        end
    end

    local function fromX(x)
        local abs = bar.AbsolutePosition.X
        local width = math.max(bar.AbsoluteSize.X, 1)
        local frac = math.clamp((x - abs) / width, 0, 1)
        setValue(min + (max - min) * frac, true)
    end

    track(hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromX(input.Position.X)
        end
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            fromX(input.Position.X)
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    setValue(cfg[key], false)
    return row
end

-- remote discovery, including tools

local remotes = {}

local function collectRemotes()
    table.clear(remotes)
    local seen = {}

    local ok, descendants = pcall(function()
        return ReplicatedStorage:GetDescendants()
    end)
    if ok and descendants then
        for _, obj in ipairs(descendants) do
            if (obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent"))
                and not seen[obj] then
                seen[obj] = true
                table.insert(remotes, obj)
            end
        end
    end

    -- tools live on the character, not in ReplicatedStorage. this is the
    -- gap that made the last recon look like the client never sends.
    local char = lp.Character
    local roots = {}
    if char then
        table.insert(roots, char)
    end
    local backpack = lp:FindFirstChildOfClass("Backpack")
    if backpack then
        table.insert(roots, backpack)
    end

    for _, root in ipairs(roots) do
        local okR, list = pcall(function()
            return root:GetDescendants()
        end)
        if okR and list then
            for _, obj in ipairs(list) do
                if (obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent"))
                    and not seen[obj] then
                    seen[obj] = true
                    table.insert(remotes, obj)
                end
            end
        end
    end

    return remotes
end

-- firing

local mouse = lp:GetMouse()
local firing = false
local lastFire = 0

local function equippedTool()
    local char = lp.Character
    return char and char:FindFirstChildOfClass("Tool") or nil
end

local function tryEquip()
    local tool = equippedTool()
    if tool then
        return tool
    end
    local backpack = lp:FindFirstChildOfClass("Backpack")
    local char = lp.Character
    if not backpack or not char then
        return nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return nil
    end
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") then
            pcall(function()
                hum:EquipTool(item)
            end)
            return equippedTool()
        end
    end
    return nil
end

local function fireOnce()
    if firing then
        return false
    end
    local now = os.clock()
    if now - lastFire < math.max(cfg.fireDelay, 20) / 1000 then
        return false
    end
    lastFire = now
    firing = true

    if cfg.autoEquip then
        tryEquip()
    end

    local tool = equippedTool()
    if tool then
        pcall(function()
            tool:Activate()
        end)
    end

    if type(mouse1click) == "function" then
        task.spawn(function()
            pcall(mouse1click)
        end)
    end

    task.delay(0.03, function()
        firing = false
    end)
    return true
end

-- measurement

local function nearestTarget()
    local cam = workspace.CurrentCamera
    if not cam then
        return nil
    end
    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local best, bestDist = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= lp and plr.Character then
            local hum = plr.Character:FindFirstChildOfClass("Humanoid")
            local head = plr.Character:FindFirstChild("Head")
            if hum and head and hum.Health > 0 then
                local pos, onScreen = cam:WorldToViewportPoint(head.Position)
                if onScreen and pos.Z > 0 then
                    local dist = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if dist < bestDist then
                        best = plr.Character
                        bestDist = dist
                    end
                end
            end
        end
    end
    return best, bestDist
end

local lastMeasurement = nil
local damageBaseline = nil

local function measureShot()
    local target = nearestTarget()
    if not target then
        return nil, "no target on screen"
    end
    local hum = target:FindFirstChildOfClass("Humanoid")
    if not hum then
        return nil, "target has no humanoid"
    end

    local before = hum.Health
    fireOnce()

    local deadline = os.clock() + 1.2
    while os.clock() < deadline do
        task.wait(0.05)
        if hum.Health < before then
            break
        end
    end

    local delta = before - hum.Health
    lastMeasurement = {
        name = target.Name,
        damage = delta,
        multiplier = cfg.damage,
        at = os.clock(),
    }
    return lastMeasurement
end

-- readout

local readoutTitle = create("TextLabel", {
    Position = UDim2.new(0, 12, 1, -60),
    Size = UDim2.new(1, -24, 0, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "no measurement yet",
    ZIndex = 3,
}, body)

local readoutBody = create("TextLabel", {
    Position = UDim2.new(0, 12, 1, -44),
    Size = UDim2.new(1, -24, 0, 28),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextWrapped = true,
    Text = "tap MEASURE to fire once and record the health delta",
    ZIndex = 3,
}, body)

local function renderReadout()
    if not lastMeasurement then
        readoutTitle.Text = "no measurement yet"
        readoutTitle.TextColor3 = COL.sub
        return
    end

    local m = lastMeasurement
    readoutTitle.Text = ("%s · -%d HP at %.1fx"):format(m.name, m.damage, m.multiplier)
    readoutTitle.TextColor3 = m.damage > 0 and COL.cyan or COL.amber

    if m.damage <= 0 then
        readoutBody.Text = "no health change — shot never registered"
        readoutBody.TextColor3 = COL.danger
        return
    end

    if damageBaseline and damageBaseline > 0 then
        local ratio = m.damage / damageBaseline
        if math.abs(ratio - 1) < 0.05 then
            readoutBody.Text = ("baseline %d HP → now %d HP. server owns damage."):format(
                damageBaseline, m.damage)
            readoutBody.TextColor3 = COL.amber
        else
            readoutBody.Text = ("baseline %d HP → now %d HP (%.2fx). it moved."):format(
                damageBaseline, m.damage, ratio)
            readoutBody.TextColor3 = COL.green
        end
    else
        readoutBody.Text = "baseline recorded. raise the slider and measure again."
        readoutBody.TextColor3 = COL.sub
    end
end

-- buttons

local function makeButton(parent, text, accent, width)
    local btn = create("TextButton", {
        Size = UDim2.new(width or 0.5, -6, 0, 32),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.86,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        ZIndex = 4,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, btn)
    create("UIStroke", { Color = accent, Transparency = 0.55, Thickness = 1 }, btn)
    return btn
end

local buttonRow = create("Frame", {
    Position = UDim2.new(0, 12, 1, -96),
    Size = UDim2.new(1, -24, 0, 32),
    BackgroundTransparency = 1,
    ZIndex = 3,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 8),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonRow)

local measureButton = makeButton(buttonRow, "MEASURE", COL.cyan, 0.5)
measureButton.LayoutOrder = 1
local baselineButton = makeButton(buttonRow, "SET BASE", COL.violet, 0.5)
baselineButton.LayoutOrder = 2

measureButton.Activated:Connect(function()
    local result, err = measureShot()
    if not result then
        readoutTitle.Text = "measure failed"
        readoutTitle.TextColor3 = COL.danger
        readoutBody.Text = err or "unknown"
        return
    end
    renderReadout()
end)

baselineButton.Activated:Connect(function()
    local result, err = measureShot()
    if not result then
        readoutTitle.Text = "baseline failed"
        readoutTitle.TextColor3 = COL.danger
        readoutBody.Text = err or "unknown"
        return
    end
    damageBaseline = result.damage
    readoutTitle.Text = ("baseline %d HP at 1.0x"):format(result.damage)
    readoutTitle.TextColor3 = COL.cyan
    readoutBody.Text = "now raise the damage slider and tap MEASURE."
    readoutBody.TextColor3 = COL.sub
end)

-- controls

addSection("HIT REGISTRATION")

makeSlider("Damage", "damage", 1, 20, 0.5, "x", nil)
makeSlider("Fire delay", "fireDelay", 20, 600, 10, "ms", nil)
makeSlider("Hitbox scale", "hitbox", 1, 6, 0.5, "x", function(value)
    -- local only: enlarges parts for your own aim raycast, nothing else
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= lp and plr.Character then
            for _, part in ipairs(plr.Character:GetChildren()) do
                if part:IsA("BasePart") then
                    local stored = part:GetAttribute("hitlua_base")
                    if stored == nil then
                        stored = part.Size
                        part:SetAttribute("hitlua_base", stored)
                    end
                    if typeof(stored) == "Vector3" then
                        part.Size = stored * value
                    end
                end
            end
        end
    end
end)

addSection("CLIENT SIDE")

makeToggle("Infinite ammo (local)", "Display only — server owns the count", "infiniteAmmo")
makeToggle("Auto-equip", "Equip a weapon before measuring", "autoEquip")

-- fit

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 24) / 316, (vp.Y - 24) / 452), 0.6, 1)
end

fit()
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
    end
end

-- open / close

local uiOpen = false
local bodyScale = create("UIScale", { Scale = 1 }, body)

local function setOpen(open)
    if open == uiOpen then
        return
    end
    uiOpen = open
    if open then
        panel.Visible = true
        bodyScale.Scale = 0.94
        tween(bodyScale, { Scale = 1 }, 0.16)
    else
        tween(bodyScale, { Scale = 0.94 }, 0.1)
        task.delay(0.13, function()
            if not uiOpen then
                panel.Visible = false
            end
        end)
    end
end

closeButton.Activated:Connect(function()
    setOpen(false)
end)

-- launcher

local float = create("Frame", {
    Size = UDim2.fromOffset(56, 56),
    Position = UDim2.fromOffset(20, 372),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.12,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, screen)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, float)

local floatStroke = create("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.8,
    Thickness = 1,
}, float)
create("UIGradient", { Color = ColorSequence.new(COL.cyan, COL.violet), Rotation = 30 }, floatStroke)

create("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    Text = "hit",
    ZIndex = 3,
}, float)

local floatDragging = false
local floatMoved = false
local floatStart
local floatOrigin

track(float.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        floatDragging = true
        floatMoved = false
        floatStart = input.Position
        floatOrigin = float.Position

        track(input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End and floatDragging then
                floatDragging = false
                if not floatMoved then
                    setOpen(not uiOpen)
                end
            end
        end))
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not floatDragging then
        return
    end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - floatStart
        if delta.Magnitude > 6 then
            floatMoved = true
        end
        float.Position = UDim2.new(
            floatOrigin.X.Scale, floatOrigin.X.Offset + delta.X,
            floatOrigin.Y.Scale, floatOrigin.Y.Offset + delta.Y
        )
    end
end))

-- boot

collectRemotes()
local toolRemoteCount = 0
do
    local char = lp.Character
    if char then
        for _, obj in ipairs(char:GetDescendants()) do
            if obj:IsA("RemoteEvent") then
                toolRemoteCount = toolRemoteCount + 1
            end
        end
    end
end

print(("[hit] %d remotes visible, %d inside your character"):format(
    #remotes, toolRemoteCount))

track(lp.CharacterAdded:Connect(function()
    task.wait(1)
    collectRemotes()
end))

setOpen(true)

local function cleanup()
    for _, conn in ipairs(connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(connections)
    if screen then
        pcall(function()
            screen:Destroy()
        end)
        screen = nil
    end
end

_G.__hitlua_cleanup = cleanup
