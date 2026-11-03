--[[
    mobtest.lua — mobile fire-path capture

    android changes everything. there is no mouse. `mouse1click` does not
    exist, and VirtualInputManager:SendMouseButtonEvent is gated on most
    android executors — which is exactly why all four buttons went red.

    so we stop trying to fake a press and start recording the real one.

    you tap your fire button once with your finger. the script sits on the
    client→server wire and copies down exactly what the game sent. then it
    replays that exact packet, byte for byte, and watches the dummy's HP.

    if the replay hits, we have the answer and it works forever.

    buttons:
      ARM       start recording (auto-arms on open)
      REPLAY    resend the last captured packet
      REPLAY×5  five in a row, for testing fire rate
      DISTINCT  every remote captured so far, with arg shapes
      TOOL      equipped tool, children, ammo location, humanoid
      CLEAR     wipe the capture list

    read the log:
      cyan   "CAPTURED"  a remote fired. name + args listed.
      green  "HIT"       replay dealt damage. this is the path.
      amber  "no damage" replay sent, missed. aim problem now.
      red    "nothing"   replay blocked. server validates something else.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
if not lp then
    return
end

if type(_G.__mobtest_cleanup) == "function" then
    pcall(_G.__mobtest_cleanup)
end

local connections = {}

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
    if child.Name == "mobtest" then
        pcall(function()
            child:Destroy()
        end)
    end
end

local screen = Instance.new("ScreenGui")
screen.Name = "mobtest"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9997
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = guiParent

-- panel

local panel = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(340, 560),
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
    BackgroundTransparency = 0.06,
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

local header = create("Frame", {
    Size = UDim2.new(1, 0, 0, 50),
    BackgroundTransparency = 1,
    Active = true,
}, body)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 8),
    Size = UDim2.fromOffset(230, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "mobtest.lua",
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 26),
    Size = UDim2.fromOffset(250, 15),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "record the real fire · replay it exactly",
}, header)

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
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)

-- drag

local dragging = false
local dragStart
local dragOrigin

track(header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragOrigin = panel.Position
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not dragging then
        return
    end
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

-- log

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 50),
    Size = UDim2.new(1, 0, 1, -232),
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

-- capture store

local captureList = {}
local captureCount = 0
local lastCapture = nil
local ignoringOwnReplay = false
local MAX_CAPTURES = 40

local function describeArg(value)
    local kind = typeof(value)
    if kind == "Vector3" then
        return ("Vector3(%.1f, %.1f, %.1f)"):format(value.X, value.Y, value.Z)
    elseif kind == "CFrame" then
        local p = value.Position
        return ("CFrame(%.1f, %.1f, %.1f)"):format(p.X, p.Y, p.Z)
    elseif kind == "Instance" then
        return value:GetFullName()
    elseif kind == "table" then
        local parts = {}
        local n = 0
        for k, v in pairs(value) do
            n = n + 1
            if n > 6 then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. describeArg(v))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif kind == "string" then
        if #value > 32 then
            return ("%q…"):format(string.sub(value, 1, 29))
        end
        return ("%q"):format(value)
    end
    return tostring(value)
end

local function describeArgs(args)
    if #args == 0 then
        return "()"
    end
    local parts = {}
    for i = 1, #args do
        table.insert(parts, describeArg(args[i]))
    end
    return "(" .. table.concat(parts, ", ") .. ")"
end

-- namecall hook — this is the whole trick

local hookReady = false
local hookError = nil

local function installHook()
    if hookReady then
        return true
    end

    if type(hookmetamethod) ~= "function" then
        hookError = "executor has no hookmetamethod"
        return false
    end

    local ok, err = pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local args = { ... }

            if not ignoringOwnReplay then
                local method
                local okMethod, methodValue = pcall(getnamecallmethod)
                if okMethod then
                    method = methodValue
                end

                if method == "FireServer" or method == "InvokeServer" then
                    if self and typeof(self) == "Instance" then
                        captureCount = captureCount + 1
                        local record = {
                            index = captureCount,
                            remote = self,
                            name = self:GetFullName(),
                            method = method,
                            args = args,
                            desc = describeArgs(args),
                        }
                        table.insert(captureList, record)
                        if #captureList > MAX_CAPTURES then
                            table.remove(captureList, 1)
                        end
                        lastCapture = record

                        task.spawn(function()
                            addLine(("CAPTURED %s:%s"):format(record.name, method), COL.cyan)
                            addLine("  " .. record.desc, COL.sub)
                        end)
                    end
                end
            end

            return oldNamecall(self, ...)
        end)
    end)

    if ok then
        hookReady = true
        return true
    end

    hookError = tostring(err)
    return false
end

-- tool.Activated spy — if your gun listens to the tool instead of a remote,
-- this fires when your finger presses the button, and we learn it for free

local activatedHits = 0

local function spyTool(tool)
    if not tool or not tool:IsA("Tool") then
        return
    end
    if tool:GetAttribute("__mobtest_spy") then
        return
    end
    tool:SetAttribute("__mobtest_spy", true)
    track(tool.Activated:Connect(function()
        activatedHits = activatedHits + 1
        addLine(("TOOL ACTIVE  %s  (#%d)"):format(tool.Name, activatedHits), COL.amber)
        addLine("  your gun DOES listen to Tool.Activated", COL.amber)
    end))
end

local function spyAllTools()
    local char = lp.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") then
                spyTool(child)
            end
        end
    end
    local backpack = lp:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") then
                spyTool(child)
            end
        end
    end
end

-- test engine

local function snapshotHealth()
    local _, hum = nearestTarget()
    return hum and hum.Health or nil
end

local function watchForHit(beforeHP, beforeAmmo, timeout)
    local deadline = os.clock() + (timeout or 1.0)
    local hitDamage = 0
    while os.clock() < deadline do
        task.wait(0.04)
        local hum = select(2, nearestTarget())
        if hum and beforeHP and hum.Health < beforeHP then
            hitDamage = beforeHP - hum.Health
            break
        end
    end
    local afterAmmo = readAmmo()
    return hitDamage, afterAmmo
end

local function replayOne()
    if not lastCapture then
        addLine("nothing captured yet — tap your fire button first", COL.amber)
        return false, 0
    end

    local target = nearestTarget()
    if not target then
        addLine("no target on screen — stand in front of a dummy", COL.amber)
        return false, 0
    end

    local beforeHP = snapshotHealth()
    local beforeAmmo = readAmmo()

    addLine(("REPLAY → %s:%s"):format(lastCapture.name, lastCapture.method), COL.violet)
    addLine("  " .. lastCapture.desc, COL.sub)

    ignoringOwnReplay = true
    local ok, err = pcall(function()
        if lastCapture.method == "InvokeServer" then
            lastCapture.remote:InvokeServer(unpack(lastCapture.args))
        else
            lastCapture.remote:FireServer(unpack(lastCapture.args))
        end
    end)
    ignoringOwnReplay = false

    if not ok then
        addLine("replay error: " .. tostring(err), COL.danger)
        return false, 0
    end

    local damage, afterAmmo = watchForHit(beforeHP, beforeAmmo, 1.0)
    local ammoMoved = beforeAmmo ~= nil and afterAmmo ~= nil and beforeAmmo ~= afterAmmo

    if damage > 0 then
        addLine(("HIT — %d damage"):format(damage), COL.green)
        return true, damage
    elseif ammoMoved then
        addLine(("fired, ammo %s → %s, but no damage"):format(
            tostring(beforeAmmo), tostring(afterAmmo)), COL.amber)
        addLine("  firing works. it is an aim problem now.", COL.amber)
        return true, 0
    else
        addLine("nothing. no damage, no ammo change", COL.danger)
        return false, 0
    end
end

local function replayMany(count)
    for i = 1, count do
        local ok, damage = replayOne()
        addLine(("  shot %d/%d  %s"):format(i, count,
            ok and ("hit " .. damage) or "no"), ok and COL.green or COL.dim)
        task.wait(0.15)
    end
end

-- reports

local function reportDistinct()
    addRule("captured remotes")

    local seen = {}
    local unique = 0
    for _, record in ipairs(captureList) do
        if not seen[record.name] then
            seen[record.name] = true
            unique = unique + 1
            addLine(("%d. %s"):format(unique, record.name), COL.cyan)
            addLine("   " .. record.method .. " " .. record.desc, COL.sub)
        end
    end

    if unique == 0 then
        addLine("nothing captured. tap your fire button once.", COL.amber)
    else
        addLine(("%d distinct remote(s), %d total call(s)"):format(unique, #captureList), COL.dim)
    end
end

local function reportTool()
    addRule("tool")
    local tool = equippedTool()
    if not tool then
        addLine("no tool equipped", COL.amber)
    else
        addLine("equipped: " .. tool.Name, COL.text)
        local remotes = 0
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent")
                or obj:IsA("RemoteFunction") then
                remotes = remotes + 1
                addLine("  remote: " .. obj:GetFullName(), COL.cyan)
            end
        end
        if remotes == 0 then
            addLine("  no remotes inside the tool", COL.dim)
        end
        local ammo, where = readAmmo()
        if ammo then
            addLine(("ammo: %s  (%s)"):format(tostring(ammo), where), COL.green)
        else
            addLine("ammo value not found inside the tool", COL.amber)
        end
    end

    addRule("target")
    local target, hum = nearestTarget()
    if target then
        addLine(("%s  hp %d"):format(target.Name, math.floor(hum.Health)), COL.green)
    else
        addLine("nothing on screen", COL.amber)
    end

    addRule("platform")
    addLine(("touch: %s"):format(
        UserInputService.TouchEnabled and "yes" or "no"), COL.sub)
    addLine(("keyboard: %s"):format(
        UserInputService.KeyboardEnabled and "yes" or "no"), COL.sub)
    addLine(("mouse1click: %s"):format(
        type(mouse1click) == "function" and "yes" or "NO"), COL.sub)
    addLine(("namecall hook: %s"):format(
        hookReady and "yes" or (hookError or "no")), COL.sub)
end

-- buttons

local function makeButton(parent, text, accent, order)
    local btn = create("TextButton", {
        Size = UDim2.new(0.5, -5, 0, 40),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.84,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = COL.text,
        AutoButtonColor = false,
        Active = true,
        LayoutOrder = order,
    }, parent)
    create("UICorner", { CornerRadius = UDim.new(0, 12) }, btn)
    create("UIStroke", { Color = accent, Transparency = 0.55, Thickness = 1 }, btn)
    return btn
end

local buttonArea = create("Frame", {
    Position = UDim2.new(0, 12, 1, -178),
    Size = UDim2.new(1, -24, 0, 132),
    BackgroundTransparency = 1,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 6),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonArea)

local replayButton = makeButton(buttonArea, "REPLAY", COL.green, 1)
local replayManyButton = makeButton(buttonArea, "REPLAY ×5", COL.violet, 2)
local distinctButton = makeButton(buttonArea, "DISTINCT", COL.cyan, 3)
local toolButton = makeButton(buttonArea, "TOOL", COL.amber, 4)
local clearButton = makeButton(buttonArea, "CLEAR", COL.danger, 5)
local resetButton = makeButton(buttonArea, "RE-ARM", COL.sub, 6)

replayButton.Activated:Connect(function()
    replayOne()
end)

replayManyButton.Activated:Connect(function()
    replayMany(5)
end)

distinctButton.Activated:Connect(function()
    reportDistinct()
end)

toolButton.Activated:Connect(function()
    reportTool()
end)

clearButton.Activated:Connect(function()
    table.clear(captureList)
    lastCapture = nil
    captureCount = 0
    addLine("captures cleared", COL.dim)
end)

resetButton.Activated:Connect(function()
    if hookReady then
        addLine("already armed. tap your fire button.", COL.dim)
        return
    end
    if installHook() then
        addLine("armed. tap your fire button.", COL.green)
    else
        addLine("hook failed: " .. tostring(hookError), COL.danger)
    end
end)

-- status

local statusText = create("TextLabel", {
    Position = UDim2.new(0, 12, 1, -34),
    Size = UDim2.new(1, -24, 0, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextColor3 = COL.green,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "ARMED — tap your fire button once",
}, body)

-- boot

local function boot()
    addRule("android fire capture")
    addLine("1. stand in front of a dummy", COL.text)
    addLine("2. tap your in-game fire button ONCE", COL.text)
    addLine("3. press REPLAY", COL.text)

    if installHook() then
        addLine("hook armed. waiting for a real shot.", COL.green)
    else
        addLine("HOOK FAILED: " .. tostring(hookError), COL.danger)
        addLine("your executor cannot hook __namecall.", COL.danger)
        addLine("tell ollie. we need a different path.", COL.danger)
    end

    spyAllTools()
    reportTool()
end

boot()

track(lp.CharacterAdded:Connect(function()
    task.wait(1.5)
    spyAllTools()
    addLine("respawned — re-armed, taps still recording", COL.dim)
end))

track(lp.ChildAdded:Connect(function(child)
    if child:IsA("Backpack") or child:IsA("Tool") then
        task.wait(0.2)
        spyAllTools()
    end
end))

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 20) / 340, (vp.Y - 20) / 560), 0.6, 1)
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

_G.__mobtest_cleanup = cleanup
