--[[
    firetest.lua — find the actual fire path

    i've been guessing at how your gun fires and every guess has been wrong.
    this stops guessing. it fires one shot four different ways and reports
    which one actually moved the target's health.

    run it in the TRAINING GROUNDS, stand in front of a dummy, then tap the
    four buttons in order. the one that drops HP is the path gun.lua needs.

    buttons:
      ACTIVATE  tool:Activate()
      CLICK     mouse1click() if the executor has it
      VIM       VirtualInputManager click at screen centre
      REMOTE    every RemoteEvent near you, fired with 4 arg shapes

    the panel also dumps:
      · your equipped tool and every child inside it
      · where the ammo number lives, if it can find it
      · the nearest humanoid and its current health
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

if type(_G.__firetest_cleanup) == "function" then
    pcall(_G.__firetest_cleanup)
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

local COL = {
    bg = Color3.fromRGB(14, 16, 24),
    text = Color3.fromRGB(236, 240, 250),
    sub = Color3.fromRGB(148, 157, 180),
    dim = Color3.fromRGB(110, 118, 142),
    cyan = Color3.fromRGB(111, 231, 255),
    violet = Color3.fromRGB(167, 139, 250),
    green = Color3.fromRGB(124, 240, 178),
    amber = Color3.fromRGB(255, 196, 108),
    danger = Color3.fromRGB(255, 108, 122),
}

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
    if child.Name == "firetest" then
        pcall(function()
            child:Destroy()
        end)
    end
end

screen = Instance.new("ScreenGui")
screen.Name = "firetest"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9996
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = guiParent

-- panel

local panel = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(360, 520),
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
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, shadow)

local body = create("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 20) }, body)

local bodyStroke = create("UIStroke", {
    Color = Color3.new(1, 1, 1),
    Transparency = 0.84,
    Thickness = 1,
}, body)
create("UIGradient", {
    Color = ColorSequence.new(COL.cyan, COL.violet),
    Transparency = NumberSequence.new(0.55, 0.9),
    Rotation = 35,
}, bodyStroke)

-- header

local header = create("TextButton", {
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
}, body)

local dragZone = create("Frame", {
    Size = UDim2.new(1, -56, 1, 0),
    BackgroundTransparency = 1,
    Active = true,
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 9),
    Size = UDim2.fromOffset(220, 17),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "firetest.lua",
}, dragZone)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 26),
    Size = UDim2.fromOffset(240, 13),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "which path actually fires?",
}, dragZone)

local closeButton = create("TextButton", {
    Size = UDim2.fromOffset(32, 32),
    Position = UDim2.new(1, -10, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 19,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)

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

-- log

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 48),
    Size = UDim2.new(1, 0, 1, -166),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = COL.sub,
    ScrollBarImageTransparency = 0.5,
}, body)

create("UIPadding", {
    PaddingLeft = UDim.new(0, 12),
    PaddingRight = UDim.new(0, 12),
    PaddingTop = UDim.new(0, 2),
    PaddingBottom = UDim.new(0, 8),
}, logScroll)

create("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, logScroll)

local orderCount = 0
local lineCount = 0

local function addLine(text, color)
    orderCount = orderCount + 1
    lineCount = lineCount + 1

    local label = create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = color or COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = tostring(text),
        LayoutOrder = orderCount,
    }, logScroll)
    label.AutomaticSize = Enum.AutomaticSize.Y

    if lineCount > 600 then
        for _, child in ipairs(logScroll:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
                lineCount = lineCount - 1
                break
            end
        end
    end

    task.defer(function()
        if logScroll and logScroll.Parent then
            logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
        end
    end)
end

local function addRule(text)
    orderCount = orderCount + 1
    lineCount = lineCount + 1
    create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "── " .. string.upper(text) .. " ──",
        LayoutOrder = orderCount,
    }, logScroll)
end

-- helpers

local AMMO_WORDS = { "ammo", "clip", "mag", "bullet", "round", "count" }
local FIRE_WORDS = { "fire", "shoot", "click", "attack", "hit", "trigger" }

local function hasWord(name, words)
    local lower = string.lower(name)
    for _, word in ipairs(words) do
        if string.find(lower, word, 1, true) then
            return true
        end
    end
    return false
end

local function equippedTool()
    local char = lp.Character
    return char and char:FindFirstChildOfClass("Tool") or nil
end

local function readAmmo()
    local tool = equippedTool()
    if not tool then
        return nil
    end
    for _, obj in ipairs(tool:GetDescendants()) do
        if obj:IsA("IntValue") or obj:IsA("NumberValue") then
            if hasWord(obj.Name, AMMO_WORDS) then
                return obj.Value, obj:GetFullName()
            end
        end
    end
    for name, value in pairs(tool:GetAttributes()) do
        if type(value) == "number" and hasWord(name, AMMO_WORDS) then
            return value, tool:GetFullName() .. " [attr " .. name .. "]"
        end
    end
    return nil
end

local function nearestTarget()
    local cam = workspace.CurrentCamera
    if not cam then
        return nil, nil
    end
    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local best, bestHum, bestDist = nil, nil, math.huge

    local function consider(model)
        if not model or model == lp.Character or not model:IsA("Model") then
            return
        end
        local hum = model:FindFirstChildOfClass("Humanoid")
        local head = model:FindFirstChild("Head")
        if not hum or not head or hum.Health <= 0 then
            return
        end
        local pos, onScreen = cam:WorldToViewportPoint(head.Position)
        if not onScreen or pos.Z <= 0 then
            return
        end
        local dist = (Vector2.new(pos.X, pos.Y) - center).Magnitude
        if dist < bestDist then
            best, bestHum, bestDist = model, hum, dist
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        consider(plr.Character)
    end
    for _, obj in ipairs(workspace:GetChildren()) do
        consider(obj)
    end

    return best, bestHum
end

-- remote discovery, including inside tools

local function collectRemotes()
    local found = {}
    local seen = {}

    local function push(obj)
        if obj and not seen[obj]
            and (obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent")) then
            seen[obj] = true
            table.insert(found, obj)
        end
    end

    local roots = {}
    local tool = equippedTool()
    if tool then
        table.insert(roots, tool)
    end
    local char = lp.Character
    if char then
        table.insert(roots, char)
    end

    for _, root in ipairs(roots) do
        local ok, list = pcall(function()
            return root:GetDescendants()
        end)
        if ok and list then
            for _, obj in ipairs(list) do
                push(obj)
            end
        end
    end

    local ok, list = pcall(function()
        return ReplicatedStorage:GetDescendants()
    end)
    if ok and list then
        for _, obj in ipairs(list) do
            if hasWord(obj.Name, FIRE_WORDS) then
                push(obj)
            end
        end
    end

    return found
end

-- test engine

local lastResult = nil

local function snapshot()
    local _, hum = nearestTarget()
    return {
        health = hum and hum.Health or nil,
        ammo = readAmmo(),
    }
end

local function waitForChange(before, timeout)
    local deadline = os.clock() + (timeout or 1.0)
    while os.clock() < deadline do
        task.wait(0.05)
        local _, hum = nearestTarget()
        if hum and before.health and hum.Health < before.health then
            return before.health - hum.Health, readAmmo()
        end
    end
    return 0, readAmmo()
end

local function runTest(name, action)
    addRule(name)

    local target = nearestTarget()
    if not target then
        addLine("no target on screen — stand in front of a dummy", COL.amber)
        return
    end
    addLine(("target: %s  hp %d"):format(target.Name, target.Humanoid.Health
        and math.floor(target.Humanoid.Health) or -1), COL.dim)

    local before = snapshot()
    if before.ammo then
        addLine(("ammo before: %s"):format(tostring(before.ammo)), COL.dim)
    end

    local ok, err = pcall(action)
    if not ok then
        addLine("error: " .. tostring(err), COL.danger)
        return
    end

    local damage, ammoAfter = waitForChange(before, 1.0)
    local ammoMoved = (before.ammo ~= nil and ammoAfter ~= nil and before.ammo ~= ammoAfter)

    if damage > 0 then
        addLine(("HIT — %d damage"):format(damage), COL.green)
        addLine("this is the path. tell ollie this button worked.", COL.green)
        lastResult = name
    elseif ammoMoved then
        addLine(("fired (ammo %s → %s) but no damage"):format(
            tostring(before.ammo), tostring(ammoAfter)), COL.amber)
        addLine("shot went out but missed — aim is the problem, not firing", COL.amber)
    else
        addLine("nothing. no damage, no ammo change", COL.danger)
    end
end

-- actions

local function actActivate()
    local tool = equippedTool()
    if not tool then
        error("no tool equipped")
    end
    tool:Activate()
end

local function actClick()
    if type(mouse1click) ~= "function" then
        error("executor has no mouse1click")
    end
    mouse1click()
end

local function actVim()
    if type(VirtualInputManager) == "nil" then
        error("no VirtualInputManager")
    end
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local x = math.floor(vp.X * 0.5)
    local y = math.floor(vp.Y * 0.5)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
    task.wait(0.04)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
end

local function actRemote()
    local remotes = collectRemotes()
    if #remotes == 0 then
        error("no remotes found near you")
    end

    local cam = workspace.CurrentCamera
    local camCFrame = cam and cam.CFrame or CFrame.new()
    local aim = camCFrame.Position + camCFrame.LookVector * 200

    local variants = {
        {},
        { aim },
        { camCFrame },
        { CFrame.lookAt(camCFrame.Position, aim) },
    }

    addLine(("firing %d remotes"):format(#remotes), COL.dim)

    for _, remote in ipairs(remotes) do
        for index, args in ipairs(variants) do
            pcall(function()
                remote:FireServer(unpack(args))
            end)
            addLine(("  → %s shape %d"):format(remote.Name, index), COL.sub)
            task.wait(0.12)
        end
    end
end

-- buttons

local function makeButton(parent, text, accent, order)
    local btn = create("TextButton", {
        Size = UDim2.new(0.5, -5, 0, 34),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.84,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = order,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 10) }, btn)
    create("UIStroke", { Color = accent, Transparency = 0.55, Thickness = 1 }, btn)
    return btn
end

local row1 = create("Frame", {
    Position = UDim2.new(0, 12, 1, -112),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
}, body)
create("UIListLayout", {
    Padding = UDim.new(0, 10),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, row1)

local row2 = create("Frame", {
    Position = UDim2.new(0, 12, 1, -74),
    Size = UDim2.new(1, -24, 0, 34),
    BackgroundTransparency = 1,
}, body)
create("UIListLayout", {
    Padding = UDim.new(0, 10),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, row2)

local activateButton = makeButton(row1, "ACTIVATE", COL.cyan, 1)
local clickButton = makeButton(row1, "CLICK", COL.violet, 2)
local vimButton = makeButton(row2, "VIM", COL.amber, 1)
local remoteButton = makeButton(row2, "REMOTE", COL.danger, 2)

activateButton.Activated:Connect(function()
    runTest("activate", actActivate)
end)

clickButton.Activated:Connect(function()
    runTest("click", actClick)
end)

vimButton.Activated:Connect(function()
    runTest("vim", actVim)
end)

remoteButton.Activated:Connect(function()
    runTest("remote", actRemote)
end)

-- status

local statusText = create("TextLabel", {
    Position = UDim2.new(0, 12, 1, -32),
    Size = UDim2.new(1, -24, 0, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextColor3 = COL.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "tap a button — whichever drops HP is the real path",
}, body)

-- boot report

local function report()
    addRule("inventory")

    local tool = equippedTool()
    if not tool then
        addLine("no tool equipped — equip your gun", COL.amber)
    else
        addLine(("tool: %s"):format(tool.Name), COL.text)
        local remoteCount = 0
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent") then
                remoteCount = remoteCount + 1
                addLine("  remote: " .. obj:GetFullName(), COL.cyan)
            end
        end
        if remoteCount == 0 then
            addLine("  no remotes inside the tool", COL.dim)
        end
        local ammo, where = readAmmo()
        if ammo then
            addLine(("  ammo: %s  (%s)"):format(tostring(ammo), where), COL.green)
        else
            addLine("  ammo value not found inside the tool", COL.amber)
        end
    end

    addRule("targets")
    local target, hum = nearestTarget()
    if target then
        addLine(("%s  hp %d"):format(target.Name, math.floor(hum.Health)), COL.green)
    else
        addLine("nothing on screen. walk up to a dummy.", COL.amber)
    end

    addRule("executor")
    addLine(("mouse1click:  %s"):format(type(mouse1click) == "function" and "yes" or "NO"), COL.sub)
    addLine(("VirtualInputManager: %s"):format(type(VirtualInputManager) ~= "nil" and "yes" or "NO"), COL.sub)
    addLine(("hookfunction: %s"):format(type(hookfunction) == "function" and "yes" or "NO"), COL.sub)

    addRule("how to read this")
    addLine("green HIT = that path fires. use it.", COL.green)
    addLine("amber = fired but missed. aim problem.", COL.amber)
    addLine("red = nothing happened at all.", COL.danger)
end

report()
track(lp.CharacterAdded:Connect(function()
    task.wait(1.5)
    report()
end))

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 20) / 360, (vp.Y - 20) / 520), 0.55, 1)
end

fit()
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
    end
end

closeButton.Activated:Connect(function()
    panel.Visible = false
end)

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

_G.__firetest_cleanup = cleanup
