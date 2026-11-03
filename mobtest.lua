--[[
    mobtest.lua — v2

    the v1 problems, fixed:
      · gethui() on many android executors renders behind the game → no buttons
      · nothing was pcall'd → one boot error and the panel went blank
      · no copy button → text could not leave the phone

    v2 parents to PlayerGui first, catches every error on screen, and has a
    COPY button that dumps the log to your clipboard.

    you tap your real fire button once. the hook records the exact remote
    and args. REPLAY sends that same packet back. HP tells us if it landed.
]]

local Players = game:GetService("Players")
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
local logLines = {}

local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then
            pcall(function()
                inst[k] = v
            end)
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

-- gui parent: PlayerGui first. it always renders.

local guiParent
do
    local ok, playerGui = pcall(function()
        return lp:WaitForChild("PlayerGui", 5)
    end)
    if ok and playerGui then
        guiParent = playerGui
    else
        local ok2, coreGui = pcall(function()
            return game:GetService("CoreGui")
        end)
        if ok2 and coreGui then
            guiParent = coreGui
        else
            local ok3, hui = pcall(function()
                return gethui and gethui()
            end)
            guiParent = (ok3 and hui) or nil
        end
    end
end

if not guiParent then
    return
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
pcall(function()
    screen.Parent = guiParent
end)

-- panel

local panel = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(360, 600),
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
    BackgroundTransparency = 0.05,
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
    Size = UDim2.new(1, 0, 0, 46),
    BackgroundTransparency = 1,
    Active = true,
}, body)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 7),
    Size = UDim2.fromOffset(240, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = COL.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "mobtest v2",
}, header)

create("TextLabel", {
    Position = UDim2.fromOffset(16, 25),
    Size = UDim2.fromOffset(260, 14),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "tap your fire button once, then REPLAY",
}, header)

local closeButton = create("TextButton", {
    Size = UDim2.fromOffset(36, 36),
    Position = UDim2.new(1, -10, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.9,
    BorderSizePixel = 0,
    Text = "×",
    Font = Enum.Font.Gotham,
    TextSize = 22,
    TextColor3 = COL.text,
    AutoButtonColor = false,
    Active = true,
}, header)
create("UICorner", { CornerRadius = UDim.new(1, 0) }, closeButton)

-- drag

do
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
end

-- banner: always visible, never scrolls away

local banner = create("Frame", {
    Position = UDim2.fromOffset(12, 48),
    Size = UDim2.new(1, -24, 0, 44),
    BackgroundColor3 = COL.cyan,
    BackgroundTransparency = 0.88,
    BorderSizePixel = 0,
}, body)
create("UICorner", { CornerRadius = UDim.new(0, 12) }, banner)

local bannerStroke = create("UIStroke", {
    Color = COL.cyan,
    Transparency = 0.5,
    Thickness = 1,
}, banner)

local bannerLabel = create("TextLabel", {
    Position = UDim2.fromOffset(12, 4),
    Size = UDim2.new(1, -24, 0, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = COL.cyan,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "BOOTING",
}, banner)

local bannerSub = create("TextLabel", {
    Position = UDim2.fromOffset(12, 24),
    Size = UDim2.new(1, -24, 0, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = COL.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "starting up",
}, banner)

local function setBanner(title, sub, color)
    if bannerLabel then
        bannerLabel.Text = title
        bannerLabel.TextColor3 = color or COL.cyan
    end
    if bannerSub then
        bannerSub.Text = sub or ""
    end
    if bannerStroke then
        bannerStroke.Color = color or COL.cyan
    end
end

-- log

local logScroll = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 96),
    Size = UDim2.new(1, 0, 1, -292),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 4,
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
    text = tostring(text)
    table.insert(logLines, text)
    if #logLines > 400 then
        table.remove(logLines, 1)
    end

    if not logScroll then
        return
    end

    orderCount = orderCount + 1
    lineCount = lineCount + 1

    local label = create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = color or COL.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = text,
        LayoutOrder = orderCount,
    }, logScroll)
    pcall(function()
        label.AutomaticSize = Enum.AutomaticSize.Y
    end)

    if lineCount > 500 then
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
            pcall(function()
                logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
            end)
        end
    end)
end

local function addRule(text)
    orderCount = orderCount + 1
    lineCount = lineCount + 1
    create("TextLabel", {
        Size = UDim2.new(1, -6, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COL.cyan,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "── " .. string.upper(tostring(text)) .. " ──",
        LayoutOrder = orderCount,
    }, logScroll)
end

-- helpers

local AMMO_WORDS = { "ammo", "clip", "mag", "bullet", "round", "count" }

local function hasWord(name, words)
    local lower = string.lower(tostring(name))
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
    local ok, value = pcall(function()
        for _, obj in ipairs(tool:GetDescendants()) do
            if obj:IsA("IntValue") or obj:IsA("NumberValue") then
                if hasWord(obj.Name, AMMO_WORDS) then
                    return obj.Value, obj:GetFullName()
                end
            end
        end
        for name, attr in pairs(tool:GetAttributes()) do
            if type(attr) == "number" and hasWord(name, AMMO_WORDS) then
                return attr, tool:GetFullName() .. " [attr " .. name .. "]"
            end
        end
        return nil
    end)
    if ok then
        return value
    end
    return nil
end

local function nearestTarget()
    local cam = workspace.CurrentCamera
    if not cam then
        return nil, nil
    end
    local vp = cam.ViewportSize or Vector2.new(1280, 720)
    local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local best, bestHum, bestDist = nil, nil, math.huge

    local function consider(model)
        if not model or model == lp.Character then
            return
        end
        if not model:IsA("Model") then
            return
        end
        local hum = model:FindFirstChildOfClass("Humanoid")
        local head = model:FindFirstChild("Head")
        if not hum or not head then
            return
        end
        if hum.Health <= 0 then
            return
        end
        local ok, pos, onScreen = pcall(function()
            return cam:WorldToViewportPoint(head.Position)
        end)
        if not ok or not onScreen or pos.Z <= 0 then
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
    local okList, list = pcall(function()
        return workspace:GetChildren()
    end)
    if okList and list then
        for _, obj in ipairs(list) do
            consider(obj)
        end
    end

    return best, bestHum
end

-- capture store

local captureList = {}
local captureCount = 0
local lastCapture = nil
local ignoringOwnReplay = false
local MAX_CAPTURES = 40
local hookReady = false
local hookError = nil

local function describeArg(value)
    local kind = typeof(value)
    if kind == "Vector3" then
        return ("V3(%.1f,%.1f,%.1f)"):format(value.X, value.Y, value.Z)
    elseif kind == "CFrame" then
        local p = value.Position
        return ("CF(%.1f,%.1f,%.1f)"):format(p.X, p.Y, p.Z)
    elseif kind == "Instance" then
        local ok, name = pcall(function()
            return value:GetFullName()
        end)
        return ok and name or "<instance>"
    elseif kind == "table" then
        local parts = {}
        local n = 0
        for k, v in pairs(value) do
            n = n + 1
            if n > 5 then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. describeArg(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif kind == "string" then
        if #value > 24 then
            return ("%q…"):format(string.sub(value, 1, 21))
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

-- the hook

local function installHook()
    if hookReady then
        return true
    end

    if type(hookmetamethod) ~= "function" then
        hookError = "no hookmetamethod"
        return false
    end

    local ok, err = pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local args = { ... }

            if not ignoringOwnReplay then
                local okMethod, method = pcall(getnamecallmethod)
                if okMethod and (method == "FireServer" or method == "InvokeServer") then
                    if self and typeof(self) == "Instance" then
                        captureCount = captureCount + 1
                        local record = {
                            index = captureCount,
                            remote = self,
                            name = select(2, pcall(function()
                                return self:GetFullName()
                            end)) or "?",
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
                            addLine(("CAPTURED %s:%s"):format(record.name, record.method), COL.cyan)
                            addLine("  " .. record.desc, COL.sub)
                            setBanner("CAPTURED · " .. tostring(captureCount),
                                record.name .. " " .. record.method, COL.cyan)
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

-- tool.Activated spy

local activatedHits = 0

local function spyTool(tool)
    if not tool or not tool:IsA("Tool") then
        return
    end
    local okFlag, alreadySpied = pcall(function()
        return tool:GetAttribute("__mobtest_spy")
    end)
    if okFlag and alreadySpied then
        return
    end
    pcall(function()
        tool:SetAttribute("__mobtest_spy", true)
    end)
    track(tool.Activated:Connect(function()
        activatedHits = activatedHits + 1
        addLine(("TOOL ACTIVE  %s  (#%d)"):format(tool.Name, activatedHits), COL.amber)
        setBanner("TOOL.ACTIVATED FIRED",
            "your gun does listen to Activated — simpler path exists", COL.amber)
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

-- replay

local function watchForHit(beforeHP, timeout)
    local deadline = os.clock() + (timeout or 1.0)
    while os.clock() < deadline do
        task.wait(0.04)
        local hum = select(2, nearestTarget())
        if hum and beforeHP and hum.Health < beforeHP then
            return beforeHP - hum.Health
        end
    end
    return 0
end

local function replayOne()
    if not lastCapture then
        addLine("nothing captured yet — tap your fire button first", COL.amber)
        setBanner("NOTHING CAPTURED", "tap your fire button once", COL.amber)
        return false
    end

    local target, hum = nearestTarget()
    if not target then
        addLine("no target on screen — stand in front of a dummy", COL.amber)
        setBanner("NO TARGET", "walk up to a dummy", COL.amber)
        return false
    end

    local beforeHP = hum.Health
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
        setBanner("REPLAY ERROR", tostring(err), COL.danger)
        return false
    end

    local damage = watchForHit(beforeHP, 1.0)
    local afterAmmo = readAmmo()
    local ammoMoved = beforeAmmo ~= nil and afterAmmo ~= nil and beforeAmmo ~= afterAmmo

    if damage > 0 then
        addLine(("HIT — %d damage"):format(damage), COL.green)
        setBanner("HIT · " .. tostring(math.floor(damage)) .. " DMG",
            "this path fires. this is the answer.", COL.green)
        return true
    elseif ammoMoved then
        addLine(("fired, ammo %s → %s, no damage"):format(
            tostring(beforeAmmo), tostring(afterAmmo)), COL.amber)
        setBanner("FIRED · MISSED",
            "firing works — aim is the only problem", COL.amber)
        return true
    else
        addLine("nothing. no damage, no ammo change", COL.danger)
        setBanner("BLOCKED", "server rejected the replay", COL.danger)
        return false
    end
end

local function replayMany(count)
    for i = 1, count do
        pcall(replayOne)
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
        addLine("nothing captured yet", COL.amber)
    else
        addLine(("%d distinct, %d total"):format(unique, #captureList), COL.dim)
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
        local ok, list = pcall(function()
            return tool:GetDescendants()
        end)
        if ok and list then
            for _, obj in ipairs(list) do
                if obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent")
                    or obj:IsA("RemoteFunction") then
                    remotes = remotes + 1
                    addLine("  " .. obj:GetFullName(), COL.cyan)
                end
            end
        end
        if remotes == 0 then
            addLine("  no remotes inside the tool", COL.dim)
        end
        local ammo, where = readAmmo()
        if ammo then
            addLine(("ammo: %s  (%s)"):format(tostring(ammo), tostring(where)), COL.green)
        else
            addLine("ammo value not found", COL.amber)
        end
    end

    addRule("platform")
    addLine(("touch %s · keyboard %s"):format(
        UserInputService.TouchEnabled and "on" or "off",
        UserInputService.KeyboardEnabled and "on" or "off"), COL.sub)
    addLine(("mouse1click: %s"):format(
        type(mouse1click) == "function" and "yes" or "no"), COL.sub)
    addLine(("namecall hook: %s"):format(
        hookReady and "yes" or (hookError or "no")), COL.sub)
    addLine(("clipboard: %s"):format(
        type(setclipboard) == "function" and "yes" or "no"), COL.sub)
end

local function copyLog()
    local text = table.concat(logLines, "\n")
    if type(setclipboard) ~= "function" then
        setBanner("NO CLIPBOARD", "screenshot the log instead", COL.danger)
        return
    end
    local ok, err = pcall(function()
        setclipboard(text)
    end)
    if ok then
        setBanner("COPIED", (#text) .. " chars on your clipboard", COL.green)
        addLine("log copied to clipboard", COL.green)
    else
        setBanner("COPY FAILED", tostring(err), COL.danger)
    end
end

-- buttons

local function makeButton(parent, text, accent, order)
    local btn = create("TextButton", {
        Size = UDim2.new(0.5, -5, 0, 44),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.84,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
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
    Position = UDim2.new(0, 12, 1, -194),
    Size = UDim2.new(1, -24, 0, 146),
    BackgroundTransparency = 1,
}, body)

create("UIListLayout", {
    Padding = UDim.new(0, 6),
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonArea)

local replayButton = makeButton(buttonArea, "REPLAY", COL.green, 1)
local replayManyButton = makeButton(buttonArea, "REPLAY ×5", COL.violet, 2)
local copyButton = makeButton(buttonArea, "COPY", COL.cyan, 3)
local distinctButton = makeButton(buttonArea, "DISTINCT", COL.cyan, 4)
local toolButton = makeButton(buttonArea, "TOOL", COL.amber, 5)
local clearButton = makeButton(buttonArea, "CLEAR", COL.danger, 6)

replayButton.Activated:Connect(function()
    pcall(replayOne)
end)

replayManyButton.Activated:Connect(function()
    pcall(replayMany, 5)
end)

copyButton.Activated:Connect(function()
    pcall(copyLog)
end)

distinctButton.Activated:Connect(function()
    pcall(reportDistinct)
end)

toolButton.Activated:Connect(function()
    pcall(reportTool)
end)

clearButton.Activated:Connect(function()
    table.clear(captureList)
    lastCapture = nil
    captureCount = 0
    addLine("captures cleared", COL.dim)
    setBanner("CLEARED", "tap your fire button again", COL.cyan)
end)

-- boot

local function boot()
    addRule("android capture")
    addLine("1. dummy on screen", COL.text)
    addLine("2. tap your fire button ONCE", COL.text)
    addLine("3. press REPLAY", COL.text)

    if installHook() then
        addLine("hook armed", COL.green)
        setBanner("ARMED · 0 CAPTURED", "tap your in-game fire button", COL.cyan)
    else
        addLine("HOOK FAILED: " .. tostring(hookError), COL.danger)
        setBanner("HOOK FAILED", tostring(hookError), COL.danger)
    end

    pcall(spyAllTools)
    pcall(reportTool)
end

local okBoot, bootErr = pcall(boot)
if not okBoot then
    addLine("BOOT ERROR: " .. tostring(bootErr), COL.danger)
    pcall(setBanner, "BOOT ERROR", tostring(bootErr), COL.danger)
end

track(lp.CharacterAdded:Connect(function()
    task.wait(1.5)
    pcall(spyAllTools)
    addLine("respawned — still recording", COL.dim)
end))

track(lp.ChildAdded:Connect(function(child)
    if child:IsA("Backpack") or child:IsA("Tool") then
        task.wait(0.3)
        pcall(spyAllTools)
    end
end))

local function fit()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    fitScale.Scale = math.clamp(math.min((vp.X - 16) / 360, (vp.Y - 16) / 600), 0.55, 1)
end

pcall(fit)
do
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            pcall(fit)
        end))
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
