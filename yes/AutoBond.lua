--Open Sourced by cyberseall 
--Made by cyberseall (if(!bitches) exit(1); or Terry Davis)

_G.queuedRestart = _G.queuedRestart or false
_G.isInRestart = _G.isInRestart or false
_G.failedBonds = _G.failedBonds or {} -- saves the failed Bonds

pcall(function()
    workspace.StreamingEnabled = false
    workspace.SimulationRadius = math.huge
end)

if _G.bondCollectorRunning then
    warn("Bond Collector läuft bereits - doppelte Ausführung verhindert")
    return
end -- This just looks that the Script is not getting runned twice because im to Lazy to fix the Teleport thingy

_G.bondCollectorRunning = true

-- Services
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService  = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local VirtualUser       = game:GetService("VirtualUser")
local TweenService      = game:GetService("TweenService")
local CoreGui           = game:GetService("CoreGui")
local UserInputService  = game:GetService("UserInputService")

updateCanvasSize = nil --Do not locally edit this!!!!!

-- Local Player
local player = Players.LocalPlayer

-- RemoteSetup (global so we can use it in the death handler)
local remotesRoot       = ReplicatedStorage:WaitForChild("Remotes")
local EndDecisionRemote = remotesRoot:WaitForChild("EndDecision")

-- Anti AFK (Might be broken)
player.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- Teleport-Queue (Synapse / Fluxus / etc.)
local queue_on_tp = (syn and syn.queue_on_teleport)
    or queue_on_teleport
    or (fluxus and fluxus.queue_on_teleport)

-- Flag to prevent double execution
local finished = false

-- For timeout/lag handling
local consecutiveFailures = 0
local maxConsecutiveFailures = 5

-- Settings with default values
local settings = {
    uiScale = 1.0,           -- Scale of the UI (0.8-1.5)
    
    -- General Settings
    autoRestart = true,      -- Auto restart after round ends
    enableConsoleOutput = true, -- Enable output to console
    enableSaving = true,     -- Enable saving settings to file
    
    -- Scan Settings
    scanEnabled = true,      -- Perform map scanning
    scanSteps = 70,          -- Number of steps for map scan
    scanDelay = 0.1,         -- Delay between scan steps
    
    -- Anti-Stuck Settings
    jumpOnStuck = true,      -- Jump if stuck in same position
    stuckTimeout = 2,        -- Time before considering character stuck (seconds)
    maxBondTime = 10,        -- Maximum time to spend on a single bond before skipping (seconds)
    skipStuckBonds = true,   -- Skip bonds that take too long
    maxAttemptsPerBond = 2,  -- Maximum attempts per bond before skipping
    globalStuckTimeout = 15, -- Time before considering character globally stuck (seconds)
    
    -- Teleport Settings
    teleportHeight = 2.5,      -- Height above bond to teleport to
    teleportRetryDelay = 0.2, -- Delay between teleport retries
    targetProximity = 8,     -- How close to get to target (lower = more precise)
    
    -- Failed Bonds Settings
    retryFailedBonds = false, -- Retry collecting failed bonds
    useNoClipForRetry = false, -- Use no-clip when retrying failed bonds
    maxFailedRetries = 2,    -- Maximum retries for failed bonds
    failedBondRetryDelay = 0.5, -- Delay between failed bond retries
    
    -- Bond Aura Settings
    enableBondAura = true,   -- Enable automatic collection of nearby bonds
    bondAuraRadius = 14,     -- Radius in studs to detect and collect bonds
    bondAuraInterval = 0.1,  -- How often to check for bonds (in seconds)
    
    -- NoClip Settings
    smartNoClip = false,      -- Aktiviere smartes NoClip (nur mit Boden kollidieren)
    
    -- Debug Settings
    debugMode = false,       -- Enable debug mode with extra logging
}

local function safeActivateObject(item)
    if not item or not item.Parent then
        return false
    end
    
    local success = false
    pcall(function()
        local originalParent = item.Parent
        
        if _G.ActivatePromise then
            _G.ActivatePromise:InvokeServer(item)
        elseif game:GetService("ReplicatedStorage"):FindFirstChild("Shared") and 
               game:GetService("ReplicatedStorage"):FindFirstChild("Shared"):FindFirstChild("Network") and
               require(game:GetService("ReplicatedStorage").Shared.Network:FindFirstChild("RemotePromise")) then
            
            local RemotePromiseMod = require(game:GetService("ReplicatedStorage").Shared.Network.RemotePromise)
            local ActivatePromise = RemotePromiseMod.new("ActivateObject")
            _G.ActivatePromise = ActivatePromise
            ActivatePromise:InvokeServer(item)
        else
            return false
        end
        
        task.wait(0.4)
        
        -- Checks if the bond got collected
        success = (not item or item.Parent ~= originalParent)
    end)
    return success
end

local isNoClipActive = false

local function enableSmartNoClip()
    if isNoClipActive then return end
    isNoClipActive = true
    if not player.Character then return end -- This explains itself lol
    
    local noClipConnection = RunService.Heartbeat:Connect(function()
        if not player.Character then 
            noClipConnection:Disconnect()
            isNoClipActive = false
            return 
        end
        
        for _, part in pairs(player.Character:GetDescendants()) do
            if part:IsA("BasePart") then
                local isBasePart = part.Name == "HumanoidRootPart" or 
                                  part.Name:lower():find("foot") or 
                                  part.Name:lower():find("leg") or
                                  part.Name:lower():find("torso")
                
                if isBasePart then
                    local rayParams = RaycastParams.new()
                    rayParams.FilterType = Enum.RaycastFilterType.Blacklist
                    rayParams.FilterDescendantsInstances = {player.Character}
                    
                    local rayResult = workspace:Raycast(part.Position, Vector3.new(0, -10, 0), rayParams)
                    
                    if rayResult and rayResult.Distance < 5 then
                        part.CanCollide = true
                    else
                        part.CanCollide = false
                    end
                else
                    part.CanCollide = false
                end
            end
        end
    end)
    return noClipConnection
end

local function disableSmartNoClip(connection)
    if not isNoClipActive then return end
    isNoClipActive = false
    
    if connection then
        connection:Disconnect()
    end
    
    if player.Character then
        for _, part in pairs(player.Character:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                part.CanCollide = true
            end
        end
    end
end

local settingsFileName = "bondcollector_settings.json"

local function saveSettings()
    if settings.enableSaving then
        if writefile then
            local success, result = pcall(function()
                local json = game:GetService("HttpService"):JSONEncode(settings)
                writefile(settingsFileName, json)
                return true
            end)
            
            if success and result then
                print("Settings saved successfully to " .. settingsFileName)
                return true
            else
                warn("Failed to save settings: " .. tostring(result))
            end
        else
            warn("writefile function not available in this executor")
        end
    end
    return false
end

local function loadSettings()
    if readfile and isfile then
        if isfile(settingsFileName) then
            local success, result = pcall(function()
                local json = readfile(settingsFileName)
                local loadedSettings = game:GetService("HttpService"):JSONDecode(json)
                
                -- Merge loaded settings with defaults (preserves newer settings added in updates)
                for key, value in pairs(loadedSettings) do
                    if settings[key] ~= nil then -- Only load setting if it exists in our template
                        settings[key] = value
                    end
                end
                
                return true
            end)
            
            if success and result then
                print("Settings loaded successfully from " .. settingsFileName)
                return true
            else
                warn("Failed to load settings: " .. tostring(result))
            end
        else
            print("No settings file found. Using defaults.")
        end
    else
        warn("readfile/isfile functions not available in this executor")
    end
    return false
end

loadSettings()

-- Basic death detection variable shit
local diedConnection = nil

local isMobile = UserInputService.TouchEnabled
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BondCollectorGUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Try to set ScreenGui into CoreGui (better persistence)
local success, err = pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(screenGui)
        screenGui.Parent = CoreGui
    elseif gethui then
        screenGui.Parent = gethui()
    else
        screenGui.Parent = CoreGui
    end
end)

if not success then
    screenGui.Parent = player.PlayerGui
end

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainContainer"
mainFrame.Size = UDim2.new(0, isMobile and 320 or 280, 0, isMobile and 220 or 180)
mainFrame.Position = UDim2.new(0.5, -((isMobile and 320 or 280)/2), 0.5, -((isMobile and 220 or 180)/2))
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 10)
uiCorner.Parent = mainFrame

local shadow = Instance.new("ImageLabel")
shadow.Name = "Shadow"
shadow.Size = UDim2.new(1, 30, 1, 30)
shadow.Position = UDim2.new(0, -15, 0, -15)
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://5554236805"
shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
shadow.ImageTransparency = 0.6
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(23, 23, 277, 277)
shadow.ZIndex = -1
shadow.Parent = mainFrame

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleBarCorner = Instance.new("UICorner")
titleBarCorner.CornerRadius = UDim.new(0, 10)
titleBarCorner.Parent = titleBar

local settingsButton = Instance.new("ImageButton")
settingsButton.Name = "SettingsButton"
settingsButton.Size = UDim2.new(0, 20, 0, 20)
settingsButton.Position = UDim2.new(1, -25, 0.5, -10)
settingsButton.BackgroundTransparency = 1
settingsButton.Image = "rbxassetid://3926307971"
settingsButton.ImageRectOffset = Vector2.new(324, 124)
settingsButton.ImageRectSize = Vector2.new(36, 36)
settingsButton.ImageColor3 = Color3.fromRGB(200, 200, 200)
settingsButton.ZIndex = 3
settingsButton.Parent = titleBar

local titleClipping = Instance.new("Frame")
titleClipping.Name = "TitleClipping"
titleClipping.Size = UDim2.new(1, 0, 0, 15)
titleClipping.Position = UDim2.new(0, 0, 0.5, 0)
titleClipping.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
titleClipping.BorderSizePixel = 0
titleClipping.ZIndex = 0
titleClipping.Parent = titleBar

local titleText = Instance.new("TextLabel")
titleText.Name = "Title"
titleText.Size = UDim2.new(1, -10, 1, 0)
titleText.Position = UDim2.new(0, 10, 0, 0)
titleText.BackgroundTransparency = 1
titleText.TextColor3 = Color3.fromRGB(255, 255, 255)
titleText.TextSize = 16
titleText.Font = Enum.Font.GothamBold
titleText.Text = "Bond Collector - for PAID EXEC"
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.ZIndex = 2
titleText.Parent = titleBar

local statusContainer = Instance.new("Frame")
statusContainer.Name = "StatusContainer"
statusContainer.Size = UDim2.new(1, -20, 1, -40)
statusContainer.Position = UDim2.new(0, 10, 0, 35)
statusContainer.BackgroundTransparency = 1
statusContainer.Parent = mainFrame

local statusLayout = Instance.new("UIListLayout")
statusLayout.Padding = UDim.new(0, 10)
statusLayout.SortOrder = Enum.SortOrder.LayoutOrder
statusLayout.Parent = statusContainer

local currentStatusLabel = Instance.new("TextLabel")
currentStatusLabel.Name = "CurrentStatus"
currentStatusLabel.Size = UDim2.new(1, 0, 0, 20)
currentStatusLabel.BackgroundTransparency = 1
currentStatusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
currentStatusLabel.TextSize = isMobile and 16 or 14
currentStatusLabel.Font = Enum.Font.Gotham
currentStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
currentStatusLabel.Text = "Status: Initializing..."
currentStatusLabel.LayoutOrder = 1
currentStatusLabel.Parent = statusContainer

local progressLabel = Instance.new("TextLabel")
progressLabel.Name = "Progress"
progressLabel.Size = UDim2.new(1, 0, 0, 20)
progressLabel.BackgroundTransparency = 1
progressLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
progressLabel.TextSize = isMobile and 16 or 14
progressLabel.Font = Enum.Font.Gotham
progressLabel.TextXAlignment = Enum.TextXAlignment.Left
progressLabel.Text = "Bonds: 0/0 (0%)"
progressLabel.LayoutOrder = 2
progressLabel.Parent = statusContainer

local progressBarBg = Instance.new("Frame")
progressBarBg.Name = "ProgressBarBg"
progressBarBg.Size = UDim2.new(1, 0, 0, 6)
progressBarBg.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
progressBarBg.BorderSizePixel = 0
progressBarBg.LayoutOrder = 3
progressBarBg.Parent = statusContainer

local progressBarBgCorner = Instance.new("UICorner")
progressBarBgCorner.CornerRadius = UDim.new(0, 3)
progressBarBgCorner.Parent = progressBarBg

local progressBar = Instance.new("Frame")
progressBar.Name = "ProgressBar"
progressBar.Size = UDim2.new(0, 0, 1, 0)
progressBar.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
progressBar.BorderSizePixel = 0
progressBar.Parent = progressBarBg

local progressBarCorner = Instance.new("UICorner")
progressBarCorner.CornerRadius = UDim.new(0, 3)
progressBarCorner.Parent = progressBar

local etaLabel = Instance.new("TextLabel")
etaLabel.Name = "ETA"
etaLabel.Size = UDim2.new(1, 0, 0, 20)
etaLabel.BackgroundTransparency = 1
etaLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
etaLabel.TextSize = isMobile and 14 or 12
etaLabel.Font = Enum.Font.Gotham
etaLabel.TextXAlignment = Enum.TextXAlignment.Left
etaLabel.Text = "Estimated time: Calculating..."
etaLabel.LayoutOrder = 4
etaLabel.Parent = statusContainer

local infoLabel = Instance.new("TextLabel")
infoLabel.Name = "Info"
infoLabel.Size = UDim2.new(1, 0, 0, 20)
infoLabel.BackgroundTransparency = 1
infoLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
infoLabel.TextSize = isMobile and 14 or 12
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Text = "Created by cyberseall"
infoLabel.LayoutOrder = 5
infoLabel.Parent = statusContainer

local function enableDragging(frame)
    local dragToggle, dragInput, dragStart, dragPos, startPos
    
    local function updateInput(input)
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
    
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragToggle = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragToggle = false
                end
            end)
        end
    end)
    
    titleBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragToggle then
            updateInput(input)
        end
    end)
end

enableDragging(mainFrame)

local function safeGetUIProperty(instance, property)
    if not instance then return nil end
    
    local success, result = pcall(function()
        return instance[property]
    end)
    
    if success then
        return result
    else
        return nil
    end
end

local collectedBonds = 0
local totalBonds = 0
local startTime = 0
local lastStatusUpdate = ""
local scriptStarted = false

local function updateStatus(status, collected, total)
    if not scriptStarted and not status:match("Initializing") and not status:match("Ready") then
        return
    end
    
    currentStatus = status
    
    if status == lastStatusUpdate then
        statusStuckCount = statusStuckCount + 1
        if statusStuckCount > 10 and (status:match("resetting") or status:match("stuck")) then
            statusStuckCount = 0
            
            pcall(function()
                if player.Character and player.Character:FindFirstChild("Humanoid") then
                    print("Forcing character reset due to status stuck in: " .. status)
                    player.Character.Humanoid.Health = 0
                    task.wait(1)
                end
            end)
        end
    else
        statusStuckCount = 0
    end

    if not pcall(function()
        if currentStatusLabel then
            currentStatusLabel.Text = "Status: " .. status
        end
        
        lastStatusUpdate = status
        
        if total and total > 0 then
            totalBonds = total
        end
        
        if collected then
            collectedBonds = collected
        end
        
        local percentage = totalBonds > 0 and math.floor((collectedBonds / totalBonds) * 100) or 0
        
        if progressLabel then
            progressLabel.Text = "Bonds: " .. collectedBonds .. "/" .. totalBonds .. " (" .. percentage .. "%)"
        end
        
        local targetSize = totalBonds > 0 and (collectedBonds / totalBonds) or 0
        
        pcall(function()
            if progressBar and TweenService then
                local tween = TweenService:Create(
                    progressBar, 
                    TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    {Size = UDim2.new(targetSize, 0, 1, 0)}
                )
                tween:Play()
            end
        end)
        
        if startTime > 0 and collectedBonds > 0 and collectedBonds < totalBonds then
            local elapsed = tick() - startTime
            local estimatedTotal = elapsed * (totalBonds / collectedBonds)
            local remaining = estimatedTotal - elapsed
            
            local minutes = math.floor(remaining / 60)
            local seconds = math.floor(remaining % 60)
            
            if etaLabel then
                etaLabel.Text = "Estimated time: " .. minutes .. "m " .. seconds .. "s"
            end
        else
            if etaLabel then
                etaLabel.Text = "Estimated time: Calculating..."
            end
        end
    end) then
        warn("Fehler beim Aktualisieren des UI") --Just debugging for UI Errors should be deleted ngl
    end
end

local function setupDeathDetection()
    if diedConnection then 
        diedConnection:Disconnect()
        diedConnection = nil
    end
    
    local lastHealth = 100
    local healthCheckTimer = 0
    local stuckInTPNotWorking = 0
    
    task.spawn(function()
        while not finished do
            if player and player.Character then
                local humanoid = player.Character:FindFirstChild("Humanoid")
                if humanoid then
                    if humanoid.Health <= 0 then
                        updateStatus("Charakter ist gestorben (Gesundheit = 0)", collectedBonds, totalBonds)
                        finished = true
                        
                        if diedConnection then
                            diedConnection:Disconnect()
                            diedConnection = nil
                        end

                        pcall(function()
                            EndDecisionRemote:FireServer(false)
                        end)
                        
                        updateStatus("Death detected in main thread! Preparing to restart...", collectedBonds, totalBonds)
                        
                        task.delay(0.5, function()
                            pcall(function() scriptFinished() end)
                            
                            task.delay(1, function()
                                if settings.autoRestart and queue_on_tp then
                                    local restartCode = [[
                                    _G.hasStartedBefore = true;
                                    loadstring(game:HttpGet("CHANGE THIS YOU RETARED NIGGER"))()
                                    ]]
                                    queue_on_tp(restartCode)
                                    print("Emergency auto-restart after death set up in the main thread")
                                end
                            end)
                        end)
                        break
                    elseif humanoid.Health < 30 then
                        updateStatus("Niedrige Gesundheit erkannt: " .. math.floor(humanoid.Health), collectedBonds, totalBonds)
                        
                        task.wait(0.1)
                    elseif humanoid.Health < lastHealth - 30 then
                        updateStatus("Starker Gesundheitsverlust erkannt: " .. math.floor(lastHealth - humanoid.Health), collectedBonds, totalBonds)
                        
                        task.wait(0.1)
                    else
                        lastHealth = humanoid.Health
                        
                        task.wait(0.2)
                    end
                else
                    updateStatus("Humanoid nicht gefunden, möglicher Tod", collectedBonds, totalBonds)
                    finished = true
                    
                    if diedConnection then
                        diedConnection:Disconnect()
                        diedConnection = nil
                    end
                    
                    pcall(function()
                        EndDecisionRemote:FireServer(false)
                    end)
                    
                    task.wait(0.5)
                    scriptFinished()
                    break
                end
            else
                updateStatus("Charakter nicht gefunden, möglicher Tod", collectedBonds, totalBonds)
                finished = true
                
                if diedConnection then
                    diedConnection:Disconnect()
                    diedConnection = nil
                end
                
                pcall(function()
                    EndDecisionRemote:FireServer(false)
                end)
                
                task.wait(0.5)
                scriptFinished()
                break
            end
            
            if currentStatus and currentStatus:find("TP not working") then
                stuckInTPNotWorking = stuckInTPNotWorking + 1
                
                if stuckInTPNotWorking > 3 then
                    updateStatus("TP not working zu lange - als Tod behandeln", collectedBonds, totalBonds)
                    
                    finished = true
                    
                    if diedConnection then
                        diedConnection:Disconnect()
                        diedConnection = nil
                    end
                    
                    pcall(function()
                        EndDecisionRemote:FireServer(false)
                    end)
                    
                    pcall(function()
                        if player.Character and player.Character:FindFirstChild("Humanoid") then
                            player.Character.Humanoid.Health = 0
                        end
                    end)
                    
                    task.delay(0.5, function()
                        pcall(function() scriptFinished() end)

                        task.delay(1, function()
                            if settings.autoRestart and queue_on_tp then
                                local restartCode = [[
                                _G.hasStartedBefore = true;
                                loadstring(game:HttpGet("CHANGE THIS YOU RETARED NIGGER"))()
                                ]]
                                queue_on_tp(restartCode)
                                print("Notfall-Auto-Restart nach TP not working eingerichtet")
                            end
                        end)
                    end)
                    
                    break
                end
            else
                stuckInTPNotWorking = 0
            end
            
            if player and player:FindFirstChild("PlayerGui") then
                local success, result = pcall(function()
                    local found = false
                    
                    for _, screenGui in ipairs(player.PlayerGui:GetChildren()) do
                        if not screenGui:IsA("ScreenGui") then 
                        else
                            for _, element in ipairs(screenGui:GetDescendants()) do
                                if not (element:IsA("TextLabel") or element:IsA("TextButton")) then 
                                else 
                                    local text = safeGetUIProperty(element, "Text")
                                    if text then
                                        text = text:lower()
                                        
                                        if text:find("selbstbelebung") or text:find("revive") or 
                                           text:find("respawn") or text:find("spawn") or 
                                           text:find("tot") or text:find("died") or 
                                           text:find("dead") or text:find("gestorben") or
                                           text:find("restart") or text:find("neustart") then
                                            
                                            local isVisible = safeGetUIProperty(element, "Visible")
                                            local parentVisible = element.Parent and safeGetUIProperty(element.Parent, "Visible")
                                            
                                            if isVisible and parentVisible then
                                                found = true
                                                updateStatus("Tod-UI erkannt: " .. text, collectedBonds, totalBonds)
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            
                            if found then break end
                        end
                    end
                    
                    return found
                end)
                
                if (success and result) or not success then
                    if not success then
                        warn("Fehler bei UI-Prüfung: " .. tostring(result))
                    end
                    
                    if not _G.isInRestart then
                        _G.isInRestart = true
                        task.wait(0.5)
                        scriptFinished()
                    else
                        print("Neustart bereits im Gange, ignoriere weitere Anfragen")
                    end
                    break
                end
            end
        end
    end)
    
    if player.Character then
        local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            diedConnection = humanoid.Died:Connect(function()
                updateStatus("Character died via event", collectedBonds, totalBonds)
                task.wait(0.5)
                
                pcall(function()
                    if scriptFinished then
                        scriptFinished()
                    end
                end)
            end)
            
            humanoid.HealthChanged:Connect(function(newHealth)
                if newHealth <= 0 then
                    updateStatus("Health dropped to zero", collectedBonds, totalBonds)
                    finished = true
                    
                    if diedConnection then
                        diedConnection:Disconnect()
                        diedConnection = nil
                    end
                    
                    pcall(function()
                        if EndDecisionRemote then
                            EndDecisionRemote:FireServer(false)
                        end
                    end)
                    
                    updateStatus("Death detected! Restarting...", collectedBonds, totalBonds)
                    
                    task.delay(0.5, function()
                        pcall(function() 
                            if scriptFinished then
                                scriptFinished() 
                            end
                        end)
                        
                        task.delay(1, function()
                            if settings.autoRestart and queue_on_tp then
                                local restartCode = [[
                                _G.hasStartedBefore = true;
                                loadstring(game:HttpGet("CHANGE THIS YOU RETARED NIGGER"))()
                                ]]
                                queue_on_tp(restartCode)
                                print("Notfall-Auto-Restart nach Tod eingerichtet")
                            end
                        end)
                    end)
                elseif newHealth < 30 then
                    warn("Achtung: Niedrige Gesundheit! (" .. math.floor(newHealth) .. ")")
                end
            end)
        end
    end
    
    player.CharacterAdded:Connect(function(char)
        local humanoid = char:WaitForChild("Humanoid")
        diedConnection = humanoid.Died:Connect(function()
            updateStatus("New character died", collectedBonds, totalBonds)
            task.wait(0.5)
            scriptFinished()
        end)
        
        humanoid.HealthChanged:Connect(function(newHealth)
            if newHealth <= 0 then
                updateStatus("Health dropped to zero (new character)", collectedBonds, totalBonds)
                finished = true
                
                if diedConnection then
                    diedConnection:Disconnect()
                    diedConnection = nil
                end
                
                pcall(function()
                    EndDecisionRemote:FireServer(false)
                end)
                
                updateStatus("Death detected! Restarting...", collectedBonds, totalBonds)
                
                task.delay(0.5, function()
                    pcall(function() scriptFinished() end)
                    
                    task.delay(1, function()
                        if settings.autoRestart and queue_on_tp then
                            local restartCode = [[
                            _G.hasStartedBefore = true;
                            loadstring(game:HttpGet("CHANGE THIS YOU RETARED NIGGER"))()
                            ]]
                            queue_on_tp(restartCode)
                            print("Notfall-Auto-Restart nach Tod eingerichtet")
                        end
                    end)
                end)
            elseif newHealth < 30 then
                warn("Achtung: Niedrige Gesundheit beim neuen Charakter! (" .. math.floor(newHealth) .. ")")
            end
        end)
    end)
end

local function scriptFinished()
    if finished then return end
    finished = true
    
    task.delay(2, function()
        _G.bondCollectorRunning = false
    end)
    
    if diedConnection then
        diedConnection:Disconnect()
        diedConnection = nil
    end

    pcall(function()
        if EndDecisionRemote then
            EndDecisionRemote:FireServer(false)
        end
    end)

    -- Update status
    updateStatus("Finished! Waiting for next round...", collectedBonds, totalBonds)
    
    pcall(function()
        if progressBar and TweenService then
            local completeTween = TweenService:Create(
                progressBar, 
                TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                {BackgroundColor3 = Color3.fromRGB(75, 181, 67)}
            )
            completeTween:Play()
        end
    end)

    local function checkForRoundEnd()
        local endDetected = false
        
        pcall(function()
            local gameState = workspace:FindFirstChild("GameState") and workspace.GameState.Value or ""
            if gameState == "Intermission" or gameState == "Lobby" or gameState == "End" then
                print("Spielzustand zeigt Rundenende: " .. gameState)
                endDetected = true
            end
        end)
        
        if endDetected then return true end
        
        pcall(function()
            if not player or not player:FindFirstChild("PlayerGui") then
                return
            end
            
            for _, screenGui in ipairs(player.PlayerGui:GetChildren()) do
                if not screenGui:IsA("ScreenGui") then
                else 
                    for _, element in ipairs(screenGui:GetDescendants()) do
                        if not (element:IsA("TextLabel") or element:IsA("TextButton")) then 
                        else 
                            local text = safeGetUIProperty(element, "Text")
                            if text then
                                text = text:lower()
                                
                                if text:find("spiele erneut") or text:find("play again") or 
                                   text:find("wiederbeleben") or text:find("revive") or
                                   text:find("selbstbelebung") or text:find("nächste runde") or 
                                   text:find("next round") then
                                    
                                    local isVisible = safeGetUIProperty(element, "Visible")
                                    local parentVisible = element.Parent and safeGetUIProperty(element.Parent, "Visible")
                                    
                                    if isVisible and parentVisible then
                                        print("Rundenende-UI erkannt: " .. text)
                                        endDetected = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                    
                    if endDetected then break end
                end
            end
        end)
        
        return endDetected
    end
    
    if settings.autoRestart then
        task.spawn(function()
            setupAutoRestart()
            
            if checkForRoundEnd() then
                print("Rundenende erkannt, Neustart vorbereitet")
                return
            end
            
            for i = 1, 30 do
                if checkForRoundEnd() then
                    print("Rundenende erkannt, Neustart vorbereitet")
                    return
                end
                task.wait(1)
            end
            
            print("Kein Rundenende erkannt, trotzdem Neustart vorbereitet")
        end)
    end

    print("=== Script finished – ready for next round ===")
end

local function run()
    setupDeathDetection()
    
    updateStatus("Waiting for character...", 0, 0)
    local char     = player.Character or player.CharacterAdded:Wait()
    local hrp      = char:WaitForChild("HumanoidRootPart")
    local humanoid = char:WaitForChild("Humanoid")
    
    updateStatus("Loading remote services...", 0, 0)
    local networkFolder     = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network")
    local RemotePromiseMod  = require(networkFolder:WaitForChild("RemotePromise"))
    local ActivatePromise   = RemotePromiseMod.new("ActivateObject")
    
    _G.ActivatePromise = ActivatePromise
    
    local bondAuraConnection = nil
    if settings.enableBondAura then
        local function collectNearbyBonds()
            if not player.Character or not player.Character:FindFirstChild("HumanoidRootPart") then
                return
            end
            
            local hrpPos = player.Character.HumanoidRootPart.Position
            local runtime = WorkspaceService:FindFirstChild("RuntimeItems")
            
            if runtime then
                for _, item in ipairs(runtime:GetChildren()) do
                    if item.Name:match("Bond") then
                        local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
                        if part and part.Parent then
                            local distance = (hrpPos - part.Position).Magnitude
                            
                            if distance <= settings.bondAuraRadius then
                                local success = safeActivateObject(item)
                                if success then
                                    collectedBonds = collectedBonds + 1
                                    updateStatus("Bond automatisch mit Aura gesammelt!", collectedBonds, totalBonds)
                                end
                            end
                        end
                    end
                end
            end
        end
        
        bondAuraConnection = RunService.Heartbeat:Connect(function()
            local currentTime = tick()
            if not _G.lastBondAuraTime or (currentTime - _G.lastBondAuraTime) >= settings.bondAuraInterval then
                _G.lastBondAuraTime = currentTime
                collectNearbyBonds()
            end
        end)
        
        print("Bond Aura aktiviert - Radius: " .. settings.bondAuraRadius .. " Studs")
    end
    
    local function cleanupBondAura()
        if bondAuraConnection then
            bondAuraConnection:Disconnect()
            bondAuraConnection = nil
            print("Bond Aura deaktiviert")
        end
    end
    local bondData = {}
    local seenKeys = {}
    local function recordBonds()
        local runtime = WorkspaceService:WaitForChild("RuntimeItems")
        for _, item in ipairs(runtime:GetChildren()) do
            if item.Name:match("Bond") then
                local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
                if part then
                    local key = ("%.1f_%.1f_%.1f"):format(
                        part.Position.X, part.Position.Y, part.Position.Z
                    )
                    if not seenKeys[key] then
                        seenKeys[key] = true
                        table.insert(bondData, { item = item, pos = part.Position, key = key })
                    end
                end
            end
        end
    end

    -- Scan map
    if settings.scanEnabled then
        updateStatus("Scanning map for bonds...", 0, 0)
        local scanTarget = CFrame.new(-424.448975, 26.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)
        for i = 1, settings.scanSteps do
            local progress = math.floor((i / settings.scanSteps) * 100)
            updateStatus("Scanning map: " .. progress .. "%", 0, 0)
            hrp.CFrame = hrp.CFrame:Lerp(scanTarget, i/settings.scanSteps)
            task.wait(0.3)
            recordBonds()
            task.wait(0.1)
        end
        hrp.CFrame = scanTarget
        task.wait(0.3)
        recordBonds()
    else
        updateStatus("Map scanning disabled, collecting known bonds...", 0, 0)
        recordBonds()
    end

    print(("→ %d Bonds found"):format(#bondData))
    updateStatus("Scan completed", 0, #bondData)
    
    if #bondData == 0 then
        warn("No Bonds found – check RuntimeItems")
        updateStatus("No bonds found!", 0, 0)
        return scriptFinished()
    end

    updateStatus("Looking for MaximGun...", 0, #bondData)
    local itemsFolder = WorkspaceService:WaitForChild("RuntimeItems")
    local maximGun    = itemsFolder:FindFirstChild("MaximGun")
    if not maximGun then
        updateStatus("Error: MaximGun not found!", 0, #bondData)
        return scriptFinished()
    end
    
    local vehicleSeat = maximGun:FindFirstChildWhichIsA("VehicleSeat")
    if not vehicleSeat then
        updateStatus("Error: VehicleSeat not found!", 0, #bondData)
        return scriptFinished()
    end

    local function atTarget(pos, tol)
        return (hrp.Position - pos).Magnitude <= (tol or 6)
    end

    startTime = tick()
    
    local lastPosition = Vector3.new(0, 0, 0)
    local stuckTimer = 0
    local stuckCheckEnabled = false
    
    local globalStuckTimer = tick()
    local globalStuckPosition = hrp.Position
    local currentStatus = ""
    local statusStuckCount = 0
    
    local lastPositionHistory = {}
    local stuckPositionChecks = 0
    local lastBondCompletionTime = tick()

    local function isStuckInPattern()
        if #lastPositionHistory < 6 then
            return false
        end
        
        local posSet = {}
        for _, pos in ipairs(lastPositionHistory) do
            local posKey = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z)
            posSet[posKey] = (posSet[posKey] or 0) + 1
            
            if posSet[posKey] >= 3 then
                return true
            end
        end
        
        return false
    end

    local function checkStuckProgress()
        local currentTime = tick()
        if currentTime - lastBondCompletionTime > settings.globalStuckTimeout * 2 then
            local totalMovement = 0
            for i = 2, #lastPositionHistory do
                totalMovement = totalMovement + (lastPositionHistory[i] - lastPositionHistory[i-1]).Magnitude
            end
            
            return totalMovement < 50 or isStuckInPattern()
        end
        return false
    end

    local function tryUnstickCharacter()
        updateStatus("Trying to unstick character with random movements...", collectedBonds, totalBonds)
        
        if humanoid.SeatPart then
            humanoid.Jump = true
            task.wait(0.5)
        end
        
        local obstacles = {}
        local rays = {
            Vector3.new(1, 0, 0),   -- rechts
            Vector3.new(-1, 0, 0),  -- links
            Vector3.new(0, 0, 1),   -- vorne
            Vector3.new(0, 0, -1),  -- hinten
            Vector3.new(0, 1, 0)    -- oben
        }
        
        for _, direction in ipairs(rays) do
            local ray = Ray.new(hrp.Position, direction * 5)
            local hitPart, hitPosition = workspace:FindPartOnRay(ray, player.Character)
            
            if hitPart then
                local distance = (hitPosition - hrp.Position).Magnitude
                if distance < 3 then
                    table.insert(obstacles, {
                        direction = direction,
                        distance = distance
                    })
                end
            end
        end
        
        if #obstacles > 0 then
            table.sort(obstacles, function(a, b)
                return a.distance < b.distance
            end)
            
            local escapeDirection = obstacles[1].direction * -5
            pcall(function()
                hrp.CFrame = CFrame.new(hrp.Position + escapeDirection)
            end)
            
            task.wait(0.3)
            humanoid.Jump = true
            task.wait(0.3)
        else
            
            pcall(function()
                hrp.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 3, 0))
            end)
            
            task.wait(0.3)
            
            for i = 1, 3 do
                local angle = math.random() * math.pi * 2
                local direction = Vector3.new(math.cos(angle), 0.5, math.sin(angle)) * (5 + math.random() * 3)
                
                pcall(function()
                    hrp.CFrame = CFrame.new(hrp.Position + direction)
                end)
                
                if math.random() < 0.3 then
                    humanoid.Jump = true
                end
                
                task.wait(0.4)
            end
        end
        
        lastPositionHistory = {}
        lastBondCompletionTime = tick()
        globalStuckTimer = tick()
        globalStuckPosition = hrp.Position
        stuckPositionChecks = 0
    end

    local function isBondCollectible(bondItem)
        if not bondItem or not bondItem.Parent then
            return false
        end
        
        local primaryPart = bondItem.PrimaryPart or bondItem:FindFirstChildWhichIsA("BasePart")
        if not primaryPart then
            return false
        end
        
        local distance = (hrp.Position - primaryPart.Position).Magnitude
        if distance > 100 then
            return false
        end
        
        return true
    end

    local maxAttemptsPerBond = 3
    
    for idx, entry in ipairs(bondData) do
        globalStuckTimer = tick()
        globalStuckPosition = hrp.Position
        statusStuckCount = 0
        lastPositionHistory = {}
        
        local bondStartTime = tick()
        local bondAttempts = 0
        
        if not player.Character then
            return scriptFinished()
        end
        
        updateStatus("Collecting bond " .. idx, idx - 1, #bondData)
        
        if consecutiveFailures > 0 and idx > 1 and not bondData[idx-1].item.Parent then
            consecutiveFailures = 0
        end
        
        if consecutiveFailures >= maxConsecutiveFailures then
            updateStatus("Too many failures, resetting character position...", idx - 1, #bondData)
            
            if humanoid.SeatPart then
                humanoid.Jump = true
                task.wait(0.5)
            end
            
            task.wait(1)
            consecutiveFailures = 0
        end
        
        lastPosition = hrp.Position
        stuckTimer = tick()
        stuckCheckEnabled = true
        
        local destCFrame = CFrame.new(entry.pos + Vector3.new(0,5,0))
        vehicleSeat:PivotTo(destCFrame)
        RunService.Heartbeat:Wait()

        local t0 = tick()
        while humanoid.SeatPart ~= vehicleSeat and tick() - t0 < 1 do
            vehicleSeat:Sit(humanoid)
            task.wait(0.05)
            
            if settings.jumpOnStuck and stuckCheckEnabled and (hrp.Position - lastPosition).Magnitude < 0.1 then
                if tick() - stuckTimer > settings.stuckTimeout then
                    updateStatus("Character stuck, attempting to jump...", idx - 1, #bondData)
                    humanoid.Jump = true
                    task.wait(0.2)
                    stuckTimer = tick()
                    hrp.CFrame = hrp.CFrame * CFrame.new(0, 0.5, 0)
                    task.wait(0.3)
                    
                    if (tick() - t0) > 5 and settings.skipStuckBonds then
                        updateStatus("Failed to sit on vehicle, trying emergency teleport...", idx - 1, #bondData)
                        
                        pcall(function()
                            hrp.CFrame = CFrame.new(entry.pos + Vector3.new(0, 3, 0))
                        end)
                        
                        break
                    end
                end
            else
                lastPosition = hrp.Position
                stuckTimer = tick()
            end
        end

        stuckCheckEnabled = false

        local t1 = tick()
        local wasNearTarget = false
        repeat 
            RunService.Heartbeat:Wait()
            
            if settings.jumpOnStuck and (tick() - t1) > 0.8 and not wasNearTarget then
                if atTarget(entry.pos, 15) then
                    wasNearTarget = true
                else
                    updateStatus("TP not working, resetting...", idx - 1, #bondData)
                    humanoid.Jump = true
                    task.wait(0.3)
                    
                    bondAttempts = bondAttempts + 1
                    
                    if bondAttempts >= maxAttemptsPerBond and settings.skipStuckBonds then
                        updateStatus("Bond " .. idx .. " skipped (too many attempts)", idx - 1, #bondData)
                        break
                    end
                    
                    for offsetY = 4, 7, 1 do
                        vehicleSeat:PivotTo(CFrame.new(entry.pos + Vector3.new(0, offsetY, 0)))
                        task.wait(0.1)
                        
                        if humanoid.SeatPart ~= vehicleSeat then
                            vehicleSeat:Sit(humanoid)
                            task.wait(0.1)
                        end
                        
                        if (hrp.Position - entry.pos).Magnitude < 15 then
                            break
                        end
                    end
                    
                    t1 = tick()
                end
            end
        until atTarget(entry.pos) or (tick() - t1) > 1.2

        local reachedTarget = atTarget(entry.pos)
        if not reachedTarget and humanoid.SeatPart == vehicleSeat then
            humanoid.Jump = true
            task.wait(0.3)
        end
        
        -- Only attempt to collect if we close enough
        local collectSuccess = false
        if reachedTarget and isBondCollectible(entry.item) then
            collectSuccess = safeActivateObject(entry.item)
        end

        if collectSuccess then
            collectedBonds = collectedBonds + 1
            updateStatus("Bond automatisch mit Aura gesammelt!", collectedBonds, totalBonds)
        end

        if collectSuccess then
            updateStatus("Bond " .. idx .. " collected", idx, #bondData)
            consecutiveFailures = 0
            lastBondCompletionTime = tick()
        else
            local bondTime = tick() - bondStartTime
            if settings.skipStuckBonds and bondTime > settings.maxBondTime then
                updateStatus("Bond " .. idx .. " skipped (timeout: " .. math.floor(bondTime) .. "s)", idx - 1, #bondData)
                consecutiveFailures = consecutiveFailures + 1
                
                if settings.retryFailedBonds and isBondCollectible(entry.item) then
                    table.insert(_G.failedBonds, {
                        item = entry.item,
                        pos = entry.pos,
                        key = entry.key,
                        retryCount = 0,
                        lastRetryTime = tick()
                    })
                    print("Bond " .. idx .. " zur Wiederholungsliste hinzugefügt")
                end
            else
                updateStatus("Bond " .. idx .. " failed", idx - 1, #bondData)
                consecutiveFailures = consecutiveFailures + 1
                
                if settings.retryFailedBonds and isBondCollectible(entry.item) then
                    table.insert(_G.failedBonds, {
                        item = entry.item,
                        pos = entry.pos,
                        key = entry.key,
                        retryCount = 0,
                        lastRetryTime = tick()
                    })
                    print("Bond " .. idx .. " zur Wiederholungsliste hinzugefügt")
                end
            end
        end
        
        if #lastPositionHistory > 10 then
            table.remove(lastPositionHistory, 1)
        end
        table.insert(lastPositionHistory, hrp.Position)
        
        if (hrp.Position - globalStuckPosition).Magnitude < 10 then
            stuckPositionChecks = stuckPositionChecks + 1
            
            -- If wee been in the same area for too long
            if stuckPositionChecks > 5 or checkStuckProgress() then
                updateStatus("Enhanced stuck detection triggered, performing recovery...", idx, #bondData)
                tryUnstickCharacter()
            end
        else
            globalStuckPosition = hrp.Position
            stuckPositionChecks = 0
        end
        
        task.wait(0.5)
    end

    if settings.retryFailedBonds and #_G.failedBonds > 0 then
        updateStatus("Versuche fehlgeschlagene Bonds erneut zu sammeln...", collectedBonds, totalBonds)
        
        local failedBondsCount = #_G.failedBonds
        local retrySuccessCount = 0
        
        local function teleportWithNoClip(pos)
            if settings.useNoClipForRetry then
                local noClipConnection = nil
                
                if settings.smartNoClip then
                    noClipConnection = enableSmartNoClip()
                else
                    pcall(function()
                        for _, part in pairs(player.Character:GetDescendants()) do
                            if part:IsA("BasePart") then
                                part.CanCollide = false
                            end
                        end
                    end)
                end
                
                pcall(function()
                    hrp.CFrame = CFrame.new(pos)
                end)
                
                task.wait(0.3)
                
                if settings.smartNoClip then
                    disableSmartNoClip(noClipConnection)
                else
                    pcall(function()
                        for _, part in pairs(player.Character:GetDescendants()) do
                            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                                part.CanCollide = true
                            end
                        end
                    end)
                end
            else
                local destCFrame = CFrame.new(pos + Vector3.new(0,2,0))
                vehicleSeat:PivotTo(destCFrame)
                RunService.Heartbeat:Wait()
                
                local t0 = tick()
                while humanoid.SeatPart ~= vehicleSeat and tick() - t0 < 1 do
                    vehicleSeat:Sit(humanoid)
                    task.wait(0.05)
                end
                
                task.wait(0.5)
                
                if humanoid.SeatPart == vehicleSeat then
                    humanoid.Jump = true
                    task.wait(0.2)
                end
            end
        end
        
        for i = #_G.failedBonds, 1, -1 do
            local failedBond = _G.failedBonds[i]
            
            if not isBondCollectible(failedBond.item) then
                table.remove(_G.failedBonds, i)
                print("Fehlgeschlagener Bond existiert nicht mehr, entferne von der Liste")
            else
                failedBond.retryCount = failedBond.retryCount + 1
                
                if failedBond.retryCount > settings.maxFailedRetries then
                    updateStatus("Maximale Wiederholungen für Bond überschritten, wird übersprungen", collectedBonds, totalBonds)
                    table.remove(_G.failedBonds, i)
                else
                    updateStatus("Versuche fehlgeschlagenen Bond " .. i .. "/" .. failedBondsCount, collectedBonds, totalBonds)
                    
                    teleportWithNoClip(failedBond.pos)
                    
                    local collectSuccess = safeActivateObject(failedBond.item)
                    if collectSuccess then
                        updateStatus("Fehlgeschlagener Bond erfolgreich gesammelt!", collectedBonds + 1, totalBonds)
                        collectedBonds = collectedBonds + 1
                        retrySuccessCount = retrySuccessCount + 1
                        table.remove(_G.failedBonds, i)
                    else
                        updateStatus("Erneuter Versuch fehlgeschlagen", collectedBonds, totalBonds)
                        failedBond.lastRetryTime = tick()
                    end
                    
                    task.wait(settings.failedBondRetryDelay)
                end
            end
        end
        
        updateStatus("Wiederholungsversuch abgeschlossen. " .. retrySuccessCount .. " von " .. failedBondsCount .. " erfolgreich gesammelt.", collectedBonds, totalBonds)
    end

    updateStatus("All bonds collected!", collectedBonds, totalBonds)
    
    cleanupBondAura()
    
    pcall(function()
        local charHum = player.Character and player.Character:FindFirstChild("Humanoid")
        if charHum then
            charHum:TakeDamage(999999)
        end
    end)

    return scriptFinished()
end

-- run() -- This is commented out to prevent auto-start

_G.hasStartedBefore = _G.hasStartedBefore or false

local startFrame = Instance.new("Frame")
startFrame.Name = "StartFrame"
startFrame.Size = UDim2.new(0, 300, 0, 180)
startFrame.Position = UDim2.new(0.5, -150, 0.5, -90)
startFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
startFrame.BorderSizePixel = 0
startFrame.Parent = screenGui
startFrame.Visible = not _G.hasStartedBefore

local startCorner = Instance.new("UICorner")
startCorner.CornerRadius = UDim.new(0, 10)
startCorner.Parent = startFrame

local startShadow = Instance.new("ImageLabel")
startShadow.Name = "Shadow"
startShadow.Size = UDim2.new(1, 30, 1, 30)
startShadow.Position = UDim2.new(0, -15, 0, -15)
startShadow.BackgroundTransparency = 1
startShadow.Image = "rbxassetid://5554236805"
startShadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
startShadow.ImageTransparency = 0.6
startShadow.ScaleType = Enum.ScaleType.Slice
startShadow.SliceCenter = Rect.new(23, 23, 277, 277)
startShadow.ZIndex = -1
startShadow.Parent = startFrame

local startTitle = Instance.new("TextLabel")
startTitle.Name = "StartTitle"
startTitle.Size = UDim2.new(1, 0, 0, 40)
startTitle.BackgroundTransparency = 1
startTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
startTitle.TextSize = 22
startTitle.Font = Enum.Font.GothamBold
startTitle.Text = "Bond Collector - for PAID EXEC"
startTitle.Parent = startFrame

local startDescription = Instance.new("TextLabel")
startDescription.Name = "Description"
startDescription.Size = UDim2.new(1, -40, 0, 50)
startDescription.Position = UDim2.new(0, 20, 0, 40)
startDescription.BackgroundTransparency = 1
startDescription.TextColor3 = Color3.fromRGB(220, 220, 220)
startDescription.TextSize = 16
startDescription.Font = Enum.Font.Gotham
startDescription.Text = "Please customize your settings before clicking start."
startDescription.TextWrapped = true
startDescription.Parent = startFrame

local buttonContainer = Instance.new("Frame")
buttonContainer.Name = "ButtonContainer"
buttonContainer.Size = UDim2.new(1, -40, 0, 50)
buttonContainer.Position = UDim2.new(0, 20, 1, -70)
buttonContainer.BackgroundTransparency = 1
buttonContainer.Parent = startFrame

local startSettingsButton = Instance.new("TextButton")
startSettingsButton.Name = "SettingsButton"
startSettingsButton.Size = UDim2.new(0.48, 0, 1, 0)
startSettingsButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
startSettingsButton.BorderSizePixel = 0
startSettingsButton.Text = "Settings"
startSettingsButton.TextColor3 = Color3.fromRGB(255, 255, 255)
startSettingsButton.TextSize = 16
startSettingsButton.Font = Enum.Font.GothamBold
startSettingsButton.Parent = buttonContainer

local settingsButtonCorner = Instance.new("UICorner")
settingsButtonCorner.CornerRadius = UDim.new(0, 8)
settingsButtonCorner.Parent = startSettingsButton

local startButton = Instance.new("TextButton")
startButton.Name = "StartButton"
startButton.Size = UDim2.new(0.48, 0, 1, 0)
startButton.Position = UDim2.new(0.52, 0, 0, 0)
startButton.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
startButton.BorderSizePixel = 0
startButton.Text = "Start"
startButton.TextColor3 = Color3.fromRGB(255, 255, 255)
startButton.TextSize = 16
startButton.Font = Enum.Font.GothamBold
startButton.Parent = buttonContainer

local startButtonCorner = Instance.new("UICorner")
startButtonCorner.CornerRadius = UDim.new(0, 8)
startButtonCorner.Parent = startButton

local versionText = Instance.new("TextLabel")
versionText.Name = "Version"
versionText.Size = UDim2.new(1, -20, 0, 20)
versionText.Position = UDim2.new(0, 10, 1, -20)
versionText.BackgroundTransparency = 1
versionText.TextColor3 = Color3.fromRGB(150, 150, 150)
versionText.TextSize = 12
versionText.Font = Enum.Font.Gotham
versionText.Text = "Version 2.5 • by cyberseall"
versionText.TextXAlignment = Enum.TextXAlignment.Center
versionText.Parent = startFrame

local function showNotification(message, color, duration)
    duration = duration or 3
    color = color or Color3.fromRGB(72, 133, 237)
    
    local notification = Instance.new("Frame")
    notification.Name = "Notification"
    notification.Size = UDim2.new(0, 300, 0, 50)
    notification.Position = UDim2.new(0.5, -150, 0, -60)
    notification.BackgroundColor3 = color
    notification.BorderSizePixel = 0
    notification.ZIndex = 100
    notification.Parent = screenGui
    
    local notifCorner = Instance.new("UICorner")
    notifCorner.CornerRadius = UDim.new(0, 8)
    notifCorner.Parent = notification
    
    local notifText = Instance.new("TextLabel")
    notifText.Size = UDim2.new(1, -20, 1, 0)
    notifText.Position = UDim2.new(0, 10, 0, 0)
    notifText.BackgroundTransparency = 1
    notifText.TextColor3 = Color3.fromRGB(255, 255, 255)
    notifText.TextSize = 16
    notifText.Font = Enum.Font.GothamBold
    notifText.Text = message
    notifText.TextWrapped = true
    notifText.ZIndex = 101
    notifText.Parent = notification
    
    local inTween = TweenService:Create(
        notification,
        TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Position = UDim2.new(0.5, -150, 0, 20)}
    )
    inTween:Play()
    
    task.delay(duration, function()
        local outTween = TweenService:Create(
            notification,
            TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            {Position = UDim2.new(0.5, -150, 0, -60)}
        )
        outTween:Play()
        
        outTween.Completed:Connect(function()
            notification:Destroy()
        end)
    end)
end

local function autoStart()
    mainFrame.Visible = true
    scriptStarted = true
    
    collectedBonds = 0
    totalBonds = 0
    startTime = 0
    
    updateStatus("Automatischer Neustart...", 0, 0)
    
    task.wait(0.5)
    
    pcall(function()
        run()
    end)
end

if _G.hasStartedBefore then
    startFrame.Visible = false
    autoStart()
end

mainFrame.Visible = _G.hasStartedBefore

startSettingsButton.MouseButton1Click:Connect(function()
    if not recreateSettingsPanel then
        warn("recreateSettingsPanel Funktion nicht verfügbar!")
        task.wait(0.5)
        if not recreateSettingsPanel then
            showNotification("Konnte Settings nicht laden.", Color3.fromRGB(220, 60, 60), 3)
            return
        end
    end
    
    local settingsPanel = recreateSettingsPanel()
    settingsPanel.Visible = true
    
    showNotification("Customize your settings before starting", Color3.fromRGB(72, 133, 237), 3)
end)

startButton.MouseButton1Click:Connect(function()
    _G.hasStartedBefore = true
    
    startFrame.Visible = false
    
    mainFrame.Visible = true
    
    scriptStarted = true
    
    collectedBonds = 0
    totalBonds = 0
    startTime = 0
    
    showNotification("Bond Collector started!", Color3.fromRGB(75, 181, 67), 3)
    
    updateStatus("Ready to collect bonds...", 0, 0)
    
    pcall(function()
        run()
    end)
end)

enableDragging(startFrame)

updateStatus("Initializing...", 0, 0)
task.wait(0.5)
updateStatus("Ready to start", 0, 0)

local settingsPanel = Instance.new("Frame")
settingsPanel.Name = "SettingsPanel"
settingsPanel.Size = UDim2.new(0, isMobile and 350 or 450, 0, isMobile and 400 or 500)
settingsPanel.Position = UDim2.new(0.5, -((isMobile and 350 or 450)/2), 0.5, -((isMobile and 400 or 500)/2))
settingsPanel.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
settingsPanel.BorderSizePixel = 0
settingsPanel.Visible = false
settingsPanel.ZIndex = 10
settingsPanel.Parent = screenGui

local settingsPanelCorner = Instance.new("UICorner")
settingsPanelCorner.CornerRadius = UDim.new(0, 10)
settingsPanelCorner.Parent = settingsPanel

local settingsTitleBar = Instance.new("Frame")
settingsTitleBar.Name = "TitleBar"
settingsTitleBar.Size = UDim2.new(1, 0, 0, 35)
settingsTitleBar.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
settingsTitleBar.BorderSizePixel = 0
settingsTitleBar.ZIndex = 11
settingsTitleBar.Parent = settingsPanel

local settingsTitleBarCorner = Instance.new("UICorner")
settingsTitleBarCorner.CornerRadius = UDim.new(0, 10)
settingsTitleBarCorner.Parent = settingsTitleBar

local settingsTitleClipping = Instance.new("Frame")
settingsTitleClipping.Size = UDim2.new(1, 0, 0, 20)
settingsTitleClipping.Position = UDim2.new(0, 0, 0.5, 0)
settingsTitleClipping.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
settingsTitleClipping.BorderSizePixel = 0
settingsTitleClipping.ZIndex = 11
settingsTitleClipping.Parent = settingsTitleBar

local settingsTitleText = Instance.new("TextLabel")
settingsTitleText.Size = UDim2.new(1, -10, 1, 0)
settingsTitleText.Position = UDim2.new(0, 10, 0, 0)
settingsTitleText.BackgroundTransparency = 1
settingsTitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
settingsTitleText.TextSize = 18
settingsTitleText.Font = Enum.Font.GothamBold
settingsTitleText.Text = "Bond Collector Settings"
settingsTitleText.TextXAlignment = Enum.TextXAlignment.Left
settingsTitleText.ZIndex = 12
settingsTitleText.Parent = settingsTitleBar

local closeSettingsButton = Instance.new("TextButton")
closeSettingsButton.Name = "CloseButton"
closeSettingsButton.Size = UDim2.new(0, 20, 0, 20)
closeSettingsButton.Position = UDim2.new(1, -25, 0.5, -10)
closeSettingsButton.BackgroundTransparency = 1
closeSettingsButton.Text = "×"
closeSettingsButton.TextColor3 = Color3.fromRGB(200, 200, 200)
closeSettingsButton.TextSize = 24
closeSettingsButton.Font = Enum.Font.GothamBold
closeSettingsButton.ZIndex = 12
closeSettingsButton.Parent = settingsTitleBar

local saveSettingsButton = Instance.new("TextButton")
saveSettingsButton.Name = "SaveButton"
saveSettingsButton.Size = UDim2.new(0, 70, 0, 25)
saveSettingsButton.Position = UDim2.new(1, -100, 0.5, -12.5)
saveSettingsButton.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
saveSettingsButton.BorderSizePixel = 0
saveSettingsButton.Text = "Save"
saveSettingsButton.TextColor3 = Color3.fromRGB(255, 255, 255)
saveSettingsButton.TextSize = 14
saveSettingsButton.Font = Enum.Font.GothamBold
saveSettingsButton.ZIndex = 12
saveSettingsButton.Parent = settingsTitleBar

local saveButtonCorner = Instance.new("UICorner")
saveButtonCorner.CornerRadius = UDim.new(0, 5)
saveButtonCorner.Parent = saveSettingsButton

local settingsScrollFrame = Instance.new("ScrollingFrame")
settingsScrollFrame.Name = "SettingsScroll"
settingsScrollFrame.Size = UDim2.new(1, -20, 1, -45)
settingsScrollFrame.Position = UDim2.new(0, 10, 0, 40)
settingsScrollFrame.BackgroundTransparency = 1
settingsScrollFrame.BorderSizePixel = 0
settingsScrollFrame.ScrollBarThickness = 5
settingsScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100)
settingsScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 1000)
settingsScrollFrame.ZIndex = 11
settingsScrollFrame.Parent = settingsPanel

local function createSettingsSection(name, displayName, layoutOrder)
    local sectionContainer = Instance.new("Frame")
    sectionContainer.Name = name .. "Section"
    sectionContainer.Size = UDim2.new(1, 0, 0, 35)
    sectionContainer.BackgroundTransparency = 0.9
    sectionContainer.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    sectionContainer.BorderSizePixel = 0
    sectionContainer.LayoutOrder = layoutOrder
    sectionContainer.ZIndex = 11
    sectionContainer.Parent = settingsScrollFrame
    
    local sectionCorner = Instance.new("UICorner")
    sectionCorner.CornerRadius = UDim.new(0, 5)
    sectionCorner.Parent = sectionContainer
    
    local sectionTitle = Instance.new("TextLabel")
    sectionTitle.Name = "Title"
    sectionTitle.Size = UDim2.new(1, -20, 0, 25)
    sectionTitle.Position = UDim2.new(0, 10, 0, 5)
    sectionTitle.BackgroundTransparency = 1
    sectionTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    sectionTitle.TextSize = 16
    sectionTitle.Font = Enum.Font.GothamBold
    sectionTitle.Text = displayName
    sectionTitle.TextXAlignment = Enum.TextXAlignment.Left
    sectionTitle.ZIndex = 12
    sectionTitle.Parent = sectionContainer
    
    local sectionContent = Instance.new("Frame")
    sectionContent.Name = "Content"
    sectionContent.Size = UDim2.new(1, -20, 1, -35)
    sectionContent.Position = UDim2.new(0, 10, 0, 30)
    sectionContent.BackgroundTransparency = 1
    sectionContent.ZIndex = 12
    sectionContent.Parent = sectionContainer
    
    local contentLayout = Instance.new("UIListLayout")
    contentLayout.Padding = UDim.new(0, 10)
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Parent = sectionContent
    
    local function updateSectionSize()
        local contentSize = contentLayout.AbsoluteContentSize.Y
        sectionContainer.Size = UDim2.new(1, 0, 0, contentSize + 40)
    end
    
    sectionContent:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateSectionSize)
    contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateSectionSize)
    
    return sectionContent, sectionContainer, updateSectionSize
end

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.Padding = UDim.new(0, 15)
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
settingsLayout.Parent = settingsScrollFrame

local generalSettings, generalContainer = createSettingsSection("General", "General Settings", 1)
local uiSettings, uiContainer = createSettingsSection("UI", "UI Settings", 2)
local scanSettings, scanContainer = createSettingsSection("Scan", "Scan Settings", 3)
local antiStuckSettings, antiStuckContainer = createSettingsSection("AntiStuck", "Anti-Stuck Settings", 4)
local teleportSettings, teleportContainer = createSettingsSection("Teleport", "Teleport Settings", 5)
local debugSettings, debugContainer = createSettingsSection("Debug", "Debug Settings", 6)
local failedBondsSettings = createSettingsSection("FailedBonds", "Failed Bonds Settings", 7) -- Neues Panel

updateCanvasSize = function()
    if settingsLayout and settingsScrollFrame then
        local totalHeight = settingsLayout.AbsoluteContentSize.Y + settingsLayout.Padding.Offset * 2
        settingsScrollFrame.CanvasSize = UDim2.new(0, 0, 0, totalHeight)
    end
end

settingsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize)

enableDragging(settingsPanel)
local function createToggle(parent, name, displayName, defaultValue, settingKey, layoutOrder)
    local toggleContainer = Instance.new("Frame")
    toggleContainer.Name = name .. "Container"
    toggleContainer.Size = UDim2.new(1, 0, 0, 30)
    toggleContainer.BackgroundTransparency = 1
    toggleContainer.LayoutOrder = layoutOrder
    toggleContainer.Parent = parent
    
    local toggleLabel = Instance.new("TextLabel")
    toggleLabel.Name = "Label"
    toggleLabel.Size = UDim2.new(0.7, 0, 1, 0)
    toggleLabel.BackgroundTransparency = 1
    toggleLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
    toggleLabel.TextSize = 14
    toggleLabel.Font = Enum.Font.Gotham
    toggleLabel.Text = displayName
    toggleLabel.TextXAlignment = Enum.TextXAlignment.Left
    toggleLabel.Parent = toggleContainer
    
    local toggleButton = Instance.new("Frame")
    toggleButton.Name = "ToggleButton"
    toggleButton.Size = UDim2.new(0, 40, 0, 20)
    toggleButton.Position = UDim2.new(1, -40, 0.5, -10)
    toggleButton.BackgroundColor3 = settings[settingKey] and Color3.fromRGB(72, 133, 237) or Color3.fromRGB(100, 100, 100)
    toggleButton.BorderSizePixel = 0
    toggleButton.Parent = toggleContainer
    
    local toggleButtonCorner = Instance.new("UICorner")
    toggleButtonCorner.CornerRadius = UDim.new(0, 10)
    toggleButtonCorner.Parent = toggleButton
    
    local toggleCircle = Instance.new("Frame")
    toggleCircle.Name = "Circle"
    toggleCircle.Size = UDim2.new(0, 16, 0, 16)
    toggleCircle.Position = UDim2.new(settings[settingKey] and 0.6 or 0.1, 0, 0.5, -8)
    toggleCircle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    toggleCircle.BorderSizePixel = 0
    toggleCircle.Parent = toggleButton
    
    local toggleCircleCorner = Instance.new("UICorner")
    toggleCircleCorner.CornerRadius = UDim.new(1, 0)
    toggleCircleCorner.Parent = toggleCircle
    
    toggleButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            settings[settingKey] = not settings[settingKey]
            
            local targetPosition = settings[settingKey] and UDim2.new(0.6, 0, 0.5, -8) or UDim2.new(0.1, 0, 0.5, -8)
            local targetColor = settings[settingKey] and Color3.fromRGB(72, 133, 237) or Color3.fromRGB(100, 100, 100)
            
            local positionTween = TweenService:Create(
                toggleCircle,
                TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                {Position = targetPosition}
            )
            
            local colorTween = TweenService:Create(
                toggleButton,
                TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                {BackgroundColor3 = targetColor}
            )
            
            positionTween:Play()
            colorTween:Play()
        end
    end)
    
    return toggleContainer
end
local function createSlider(parent, name, displayName, min, max, defaultValue, settingKey, layoutOrder, suffix)
    suffix = suffix or ""
    
    local sliderContainer = Instance.new("Frame")
    sliderContainer.Name = name .. "Container"
    sliderContainer.Size = UDim2.new(1, 0, 0, 50)
    sliderContainer.BackgroundTransparency = 1
    sliderContainer.LayoutOrder = layoutOrder
    sliderContainer.Parent = parent
    
    local sliderLabel = Instance.new("TextLabel")
    sliderLabel.Name = "Label"
    sliderLabel.Size = UDim2.new(1, 0, 0, 20)
    sliderLabel.BackgroundTransparency = 1
    sliderLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
    sliderLabel.TextSize = 14
    sliderLabel.Font = Enum.Font.Gotham
    sliderLabel.Text = displayName
    sliderLabel.TextXAlignment = Enum.TextXAlignment.Left
    sliderLabel.Parent = sliderContainer
    
    local sliderValueLabel = Instance.new("TextLabel")
    sliderValueLabel.Name = "Value"
    sliderValueLabel.Size = UDim2.new(0, 50, 0, 20)
    sliderValueLabel.Position = UDim2.new(1, -50, 0, 0)
    sliderValueLabel.BackgroundTransparency = 1
    sliderValueLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    sliderValueLabel.TextSize = 14
    sliderValueLabel.Font = Enum.Font.Gotham
    sliderValueLabel.Text = tostring(settings[settingKey]) .. suffix
    sliderValueLabel.TextXAlignment = Enum.TextXAlignment.Right
    sliderValueLabel.Parent = sliderContainer
    
    local sliderTrack = Instance.new("Frame")
    sliderTrack.Name = "Track"
    sliderTrack.Size = UDim2.new(1, 0, 0, 4)
    sliderTrack.Position = UDim2.new(0, 0, 0.7, 0)
    sliderTrack.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    sliderTrack.BorderSizePixel = 0
    sliderTrack.Parent = sliderContainer
    
    local sliderTrackCorner = Instance.new("UICorner")
    sliderTrackCorner.CornerRadius = UDim.new(1, 0)
    sliderTrackCorner.Parent = sliderTrack
    
    local sliderFill = Instance.new("Frame")
    sliderFill.Name = "Fill"
    sliderFill.Size = UDim2.new((settings[settingKey] - min) / (max - min), 0, 1, 0)
    sliderFill.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
    sliderFill.BorderSizePixel = 0
    sliderFill.Parent = sliderTrack
    
    local sliderFillCorner = Instance.new("UICorner")
    sliderFillCorner.CornerRadius = UDim.new(1, 0)
    sliderFillCorner.Parent = sliderFill
    
    local sliderButton = Instance.new("TextButton")
    sliderButton.Name = "SliderButton"
    sliderButton.Size = UDim2.new(0, 16, 0, 16)
    sliderButton.Position = UDim2.new((settings[settingKey] - min) / (max - min), -8, 0.7, -6)
    sliderButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    sliderButton.BorderSizePixel = 0
    sliderButton.Text = ""
    sliderButton.Parent = sliderContainer
    
    local sliderButtonCorner = Instance.new("UICorner")
    sliderButtonCorner.CornerRadius = UDim.new(1, 0)
    sliderButtonCorner.Parent = sliderButton
    
    local isDragging = false
    
    sliderButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
        end
    end)
    
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = false
        end
    end)
    
    UserInputService.InputChanged:Connect(function(input)
        if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local trackAbsolutePosition = sliderTrack.AbsolutePosition.X
            local trackAbsoluteSize = sliderTrack.AbsoluteSize.X
            local percentage = math.clamp((input.Position.X - trackAbsolutePosition) / trackAbsoluteSize, 0, 1)
            
            local value = min + (max - min) * percentage
            -- Round to 1 decimal place for nicer display
            value = math.floor(value * 10) / 10
            
            settings[settingKey] = value
            
            sliderValueLabel.Text = tostring(value) .. suffix
            sliderFill.Size = UDim2.new(percentage, 0, 1, 0)
            sliderButton.Position = UDim2.new(percentage, -8, 0.7, -6)
        end
    end)
    
    return sliderContainer
end

-- Now create the actual settings in each section
createToggle(generalSettings, "AutoRestart", "Auto restart after round ends", true, "autoRestart", 1)
createToggle(generalSettings, "EnableOutput", "Enable console output", true, "enableConsoleOutput", 2)
createToggle(generalSettings, "EnableSaving", "Save settings to file", true, "enableSaving", 3)

createSlider(uiSettings, "UIScale", "UI Scale", 0.8, 1.5, 1.0, "uiScale", 1, "x")

createToggle(scanSettings, "ScanEnabled", "Perform map scanning", true, "scanEnabled", 1)
createSlider(scanSettings, "ScanSteps", "Scan steps", 10, 100, 50, "scanSteps", 2)
createSlider(scanSettings, "ScanDelay", "Scan delay", 0.1, 1.0, 0.3, "scanDelay", 3, "s")

createToggle(antiStuckSettings, "JumpOnStuck", "Jump when stuck", true, "jumpOnStuck", 1)
createToggle(antiStuckSettings, "SkipStuckBonds", "Skip bonds that take too long", true, "skipStuckBonds", 2)
createSlider(antiStuckSettings, "StuckTimeout", "Stuck detection time", 1, 10, 2, "stuckTimeout", 3, "s")
createSlider(antiStuckSettings, "MaxBondTime", "Max time per bond", 10, 60, 30, "maxBondTime", 4, "s")
createSlider(antiStuckSettings, "MaxAttempts", "Max attempts per bond", 1, 10, 3, "maxAttemptsPerBond", 5)
createSlider(antiStuckSettings, "GlobalStuckTimeout", "Global stuck timeout", 5, 30, 15, "globalStuckTimeout", 6, "s")

createSlider(teleportSettings, "TeleportHeight", "Teleport height above bond", 2, 10, 5, "teleportHeight", 1)
createSlider(teleportSettings, "RetryDelay", "Teleport retry delay", 0.1, 1.0, 0.3, "teleportRetryDelay", 2, "s")
createSlider(teleportSettings, "TargetProximity", "Target proximity", 2, 15, 6, "targetProximity", 3)

createToggle(debugSettings, "RetryFailedBonds", "Retry collecting failed bonds", true, "retryFailedBonds", 1)
createToggle(debugSettings, "UseNoClipForRetry", "Use no-clip when retrying failed bonds", true, "useNoClipForRetry", 2)
createSlider(debugSettings, "MaxFailedRetries", "Maximum retries for failed bonds", 1, 10, 2, "maxFailedRetries", 3)
createSlider(debugSettings, "FailedBondRetryDelay", "Delay between failed bond retries", 0.1, 1.0, 0.5, "failedBondRetryDelay", 4, "s")

createToggle(debugSettings, "DebugMode", "Enable debug mode", false, "debugMode", 1)

local function applyUIScale()
    local scale = settings.uiScale or 1.0
    mainFrame.Size = UDim2.new(0, isMobile and 320*scale or 280*scale, 0, isMobile and 220*scale or 180*scale)
    mainFrame.Position = UDim2.new(0.5, -((isMobile and 320*scale or 280*scale)/2), 0.5, -((isMobile and 220*scale or 180*scale)/2))
    
    titleText.TextSize = 16 * scale
    currentStatusLabel.TextSize = (isMobile and 16 or 14) * scale
    progressLabel.TextSize = (isMobile and 16 or 14) * scale
    etaLabel.TextSize = (isMobile and 14 or 12) * scale
    infoLabel.TextSize = (isMobile and 14 or 12) * scale
end

local originalSaveSettings = saveSettings
saveSettings = function()
    local result = originalSaveSettings()
    applyUIScale()
    return result
end

applyUIScale()

local settingsClickConnection
settingsClickConnection = settingsButton.MouseButton1Click:Connect(function()
    settingsPanel.Visible = not settingsPanel.Visible
    updateCanvasSize()
end)

closeSettingsButton.MouseButton1Click:Connect(function()
    settingsPanel.Visible = false
end)

saveSettingsButton.MouseButton1Click:Connect(function()
    if saveSettings() then
        local notifText = Instance.new("TextLabel")
        notifText.Text = "Settings saved!"
        notifText.Size = UDim2.new(0, 150, 0, 30)
        notifText.Position = UDim2.new(0.5, -75, 0, 0)
        notifText.BackgroundColor3 = Color3.fromRGB(59, 165, 93)
        notifText.TextColor3 = Color3.fromRGB(255, 255, 255)
        notifText.Font = Enum.Font.GothamBold
        notifText.TextSize = 14
        notifText.TextWrapped = true
        notifText.BorderSizePixel = 0
        notifText.Parent = settingsPanel
        
        local notifCorner = Instance.new("UICorner")
        notifCorner.CornerRadius = UDim.new(0, 5)
        notifCorner.Parent = notifText
        
        local showTween = TweenService:Create(
            notifText,
            TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Position = UDim2.new(0.5, -75, 0, 40)}
        )
        showTween:Play()
        
        task.delay(2, function()
            local hideTween = TweenService:Create(
                notifText,
                TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                {Position = UDim2.new(0.5, -75, 0, 0)}
            )
            hideTween:Play()
            
            hideTween.Completed:Connect(function()
                notifText:Destroy()
            end)
        end)
    end
end)

local isMobile = UserInputService.TouchEnabled

local function createSafeUI(func)
    local success, result = pcall(func)
    if not success then
        warn("UI-Erstellungsfehler: " .. tostring(result))
    end
end

--Mobile Version i guess
function recreateSettingsPanel()
    if _G.bondCollectorSettingsPanel then
        _G.bondCollectorSettingsPanel:Destroy()
    end
    
    local panel = Instance.new("Frame")
    panel.Name = "SettingsPanel"
    panel.Size = UDim2.new(0, isMobile and 350 or 450, 0, isMobile and 450 or 500)
    panel.Position = UDim2.new(0.5, -((isMobile and 350 or 450)/2), 0.5, -((isMobile and 450 or 500)/2))
    panel.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.ZIndex = 100
    panel.Parent = screenGui
    
    _G.bondCollectorSettingsPanel = panel
    
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 10)
    panelCorner.Parent = panel
    
    local shadow = Instance.new("ImageLabel")
    shadow.Name = "Shadow"
    shadow.Size = UDim2.new(1, 30, 1, 30)
    shadow.Position = UDim2.new(0, -15, 0, -15)
    shadow.BackgroundTransparency = 1
    shadow.Image = "rbxassetid://5554236805"
    shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
    shadow.ImageTransparency = 0.6
    shadow.ScaleType = Enum.ScaleType.Slice
    shadow.SliceCenter = Rect.new(23, 23, 277, 277)
    shadow.ZIndex = 99
    shadow.Parent = panel
    
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 40)
    titleBar.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    titleBar.BorderSizePixel = 0
    titleBar.ZIndex = 101
    titleBar.Parent = panel
    
    local titleBarCorner = Instance.new("UICorner")
    titleBarCorner.CornerRadius = UDim.new(0, 10)
    titleBarCorner.Parent = titleBar
    
    local titleClipping = Instance.new("Frame")
    titleClipping.Size = UDim2.new(1, 0, 0, 20)
    titleClipping.Position = UDim2.new(0, 0, 0.5, 0)
    titleClipping.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    titleClipping.BorderSizePixel = 0
    titleClipping.ZIndex = 101
    titleClipping.Parent = titleBar
    
    local titleText = Instance.new("TextLabel")
    titleText.Size = UDim2.new(1, -10, 1, 0)
    titleText.Position = UDim2.new(0, 10, 0, 0)
    titleText.BackgroundTransparency = 1
    titleText.TextColor3 = Color3.fromRGB(255, 255, 255)
    titleText.TextSize = isMobile and 20 or 18
    titleText.Font = Enum.Font.GothamBold
    titleText.Text = "Bond Collector Settings"
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.ZIndex = 102
    titleText.Parent = titleBar
    
    local closeButton = Instance.new("TextButton")
    closeButton.Name = "CloseButton"
    closeButton.Size = UDim2.new(0, 26, 0, 26)
    closeButton.Position = UDim2.new(1, -32, 0.5, -13)
    closeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    closeButton.Text = "×"
    closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeButton.TextSize = 24
    closeButton.Font = Enum.Font.GothamBold
    closeButton.ZIndex = 102
    closeButton.Parent = titleBar
    
    local closeButtonCorner = Instance.new("UICorner")
    closeButtonCorner.CornerRadius = UDim.new(0, 5)
    closeButtonCorner.Parent = closeButton
    
    local saveButton = Instance.new("TextButton")
    saveButton.Name = "SaveButton"
    saveButton.Size = UDim2.new(0, 70, 0, 30)
    saveButton.Position = UDim2.new(1, -110, 0.5, -15)
    saveButton.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
    saveButton.BorderSizePixel = 0
    saveButton.Text = "Save"
    saveButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    saveButton.TextSize = isMobile and 16 or 14
    saveButton.Font = Enum.Font.GothamBold
    saveButton.ZIndex = 102
    saveButton.Parent = titleBar
    
    local saveButtonCorner = Instance.new("UICorner")
    saveButtonCorner.CornerRadius = UDim.new(0, 5)
    saveButtonCorner.Parent = saveButton
    
    local scrollFrame = Instance.new("ScrollingFrame")
    scrollFrame.Name = "SettingsScroll"
    scrollFrame.Size = UDim2.new(1, -20, 1, -50)
    scrollFrame.Position = UDim2.new(0, 10, 0, 45)
    scrollFrame.BackgroundTransparency = 1
    scrollFrame.BorderSizePixel = 0
    scrollFrame.ScrollBarThickness = isMobile and 8 or 5
    scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100)
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 1000)
    scrollFrame.ZIndex = 101
    scrollFrame.Parent = panel
    
    local function createSection(name, displayName, layoutOrder)
        local container = Instance.new("Frame")
        container.Name = name .. "Section"
        container.Size = UDim2.new(1, 0, 0, 35)
        container.BackgroundTransparency = 0.9
        container.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
        container.BorderSizePixel = 0
        container.LayoutOrder = layoutOrder
        container.ZIndex = 101
        container.Parent = scrollFrame
        
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = container
        
        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.Size = UDim2.new(1, -20, 0, 25)
        title.Position = UDim2.new(0, 10, 0, 5)
        title.BackgroundTransparency = 1
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextSize = 16
        title.Font = Enum.Font.GothamBold
        title.Text = displayName
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 102
        title.Parent = container
        
        local content = Instance.new("Frame")
        content.Name = "Content"
        content.Size = UDim2.new(1, -20, 1, -35)
        content.Position = UDim2.new(0, 10, 0, 30)
        content.BackgroundTransparency = 1
        content.ZIndex = 102
        content.Parent = container
        
        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 10)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = content
        
        local function updateSectionSize()
            local contentSize = layout.AbsoluteContentSize.Y
            container.Size = UDim2.new(1, 0, 0, contentSize + 40)
        end
        
        content:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateSectionSize)
        layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateSectionSize)
        
        return content, container
    end
    
    local settingsLayout = Instance.new("UIListLayout")
    settingsLayout.Padding = UDim.new(0, 15)
    settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    settingsLayout.Parent = scrollFrame
    
    local generalSettings = createSection("General", "General Settings", 1)
    local uiSettings = createSection("UI", "UI Settings", 2)
    local scanSettings = createSection("Scan", "Scan Settings", 3)
    local antiStuckSettings = createSection("AntiStuck", "Anti-Stuck Settings", 4)
    local teleportSettings = createSection("Teleport", "Teleport Settings", 5)
    local failedBondsSettings = createSection("FailedBonds", "Failed Bonds Settings", 6)
    local bondAuraSettings = createSection("BondAura", "Bond Aura Settings", 7)
    local noClipSettings = createSection("NoClip", "NoClip Settings", 8)
    local debugSettings = createSection("Debug", "Debug Settings", 9)
    
    local function updateCanvasSize()
        if settingsLayout and scrollFrame then
            local totalHeight = settingsLayout.AbsoluteContentSize.Y + settingsLayout.Padding.Offset * 2
            scrollFrame.CanvasSize = UDim2.new(0, 0, 0, totalHeight)
        end
    end
    
    settingsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize)
    
    local function createToggle(parent, name, displayName, defaultValue, settingKey, layoutOrder)
        local toggleContainer = Instance.new("Frame")
        toggleContainer.Name = name .. "Container"
        toggleContainer.Size = UDim2.new(1, 0, 0, 30)
        toggleContainer.BackgroundTransparency = 1
        toggleContainer.LayoutOrder = layoutOrder
        toggleContainer.Parent = parent
        
        local toggleLabel = Instance.new("TextLabel")
        toggleLabel.Name = "Label"
        toggleLabel.Size = UDim2.new(0.7, 0, 1, 0)
        toggleLabel.BackgroundTransparency = 1
        toggleLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
        toggleLabel.TextSize = 14
        toggleLabel.Font = Enum.Font.Gotham
        toggleLabel.Text = displayName
        toggleLabel.TextXAlignment = Enum.TextXAlignment.Left
        toggleLabel.Parent = toggleContainer
        
        local toggleButton = Instance.new("Frame")
        toggleButton.Name = "ToggleButton"
        toggleButton.Size = UDim2.new(0, 40, 0, 20)
        toggleButton.Position = UDim2.new(1, -40, 0.5, -10)
        toggleButton.BackgroundColor3 = settings[settingKey] and Color3.fromRGB(72, 133, 237) or Color3.fromRGB(100, 100, 100)
        toggleButton.BorderSizePixel = 0
        toggleButton.Parent = toggleContainer
        
        local toggleButtonCorner = Instance.new("UICorner")
        toggleButtonCorner.CornerRadius = UDim.new(0, 10)
        toggleButtonCorner.Parent = toggleButton
        
        local toggleCircle = Instance.new("Frame")
        toggleCircle.Name = "Circle"
        toggleCircle.Size = UDim2.new(0, 16, 0, 16)
        toggleCircle.Position = UDim2.new(settings[settingKey] and 0.6 or 0.1, 0, 0.5, -8)
        toggleCircle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        toggleCircle.BorderSizePixel = 0
        toggleCircle.Parent = toggleButton
        
        local toggleCircleCorner = Instance.new("UICorner")
        toggleCircleCorner.CornerRadius = UDim.new(1, 0)
        toggleCircleCorner.Parent = toggleCircle
        
        toggleButton.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                settings[settingKey] = not settings[settingKey]
                
                local targetPosition = settings[settingKey] and UDim2.new(0.6, 0, 0.5, -8) or UDim2.new(0.1, 0, 0.5, -8)
                local targetColor = settings[settingKey] and Color3.fromRGB(72, 133, 237) or Color3.fromRGB(100, 100, 100)
                
                local positionTween = TweenService:Create(
                    toggleCircle,
                    TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    {Position = targetPosition}
                )
                
                local colorTween = TweenService:Create(
                    toggleButton,
                    TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    {BackgroundColor3 = targetColor}
                )
                
                positionTween:Play()
                colorTween:Play()
            end
        end)
        
        return toggleContainer
    end
    
    local function createSlider(parent, name, displayName, min, max, defaultValue, settingKey, layoutOrder, suffix)
        suffix = suffix or ""
        
        local sliderContainer = Instance.new("Frame")
        sliderContainer.Name = name .. "Container"
        sliderContainer.Size = UDim2.new(1, 0, 0, 50)
        sliderContainer.BackgroundTransparency = 1
        sliderContainer.LayoutOrder = layoutOrder
        sliderContainer.Parent = parent
        
        local sliderLabel = Instance.new("TextLabel")
        sliderLabel.Name = "Label"
        sliderLabel.Size = UDim2.new(1, 0, 0, 20)
        sliderLabel.BackgroundTransparency = 1
        sliderLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
        sliderLabel.TextSize = 14
        sliderLabel.Font = Enum.Font.Gotham
        sliderLabel.Text = displayName
        sliderLabel.TextXAlignment = Enum.TextXAlignment.Left
        sliderLabel.Parent = sliderContainer
        
        local sliderValueLabel = Instance.new("TextLabel")
        sliderValueLabel.Name = "Value"
        sliderValueLabel.Size = UDim2.new(0, 50, 0, 20)
        sliderValueLabel.Position = UDim2.new(1, -50, 0, 0)
        sliderValueLabel.BackgroundTransparency = 1
        sliderValueLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
        sliderValueLabel.TextSize = 14
        sliderValueLabel.Font = Enum.Font.Gotham
        sliderValueLabel.Text = tostring(settings[settingKey]) .. suffix
        sliderValueLabel.TextXAlignment = Enum.TextXAlignment.Right
        sliderValueLabel.Parent = sliderContainer
        
        local sliderTrack = Instance.new("Frame")
        sliderTrack.Name = "Track"
        sliderTrack.Size = UDim2.new(1, 0, 0, 4)
        sliderTrack.Position = UDim2.new(0, 0, 0.7, 0)
        sliderTrack.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        sliderTrack.BorderSizePixel = 0
        sliderTrack.Parent = sliderContainer
        
        local sliderTrackCorner = Instance.new("UICorner")
        sliderTrackCorner.CornerRadius = UDim.new(1, 0)
        sliderTrackCorner.Parent = sliderTrack
        
        local sliderFill = Instance.new("Frame")
        sliderFill.Name = "Fill"
        sliderFill.Size = UDim2.new((settings[settingKey] - min) / (max - min), 0, 1, 0)
        sliderFill.BackgroundColor3 = Color3.fromRGB(72, 133, 237)
        sliderFill.BorderSizePixel = 0
        sliderFill.Parent = sliderTrack
        
        local sliderFillCorner = Instance.new("UICorner")
        sliderFillCorner.CornerRadius = UDim.new(1, 0)
        sliderFillCorner.Parent = sliderFill
        
        local sliderButton = Instance.new("TextButton")
        sliderButton.Name = "SliderButton"
        sliderButton.Size = UDim2.new(0, 16, 0, 16)
        sliderButton.Position = UDim2.new((settings[settingKey] - min) / (max - min), -8, 0.7, -6)
        sliderButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        sliderButton.BorderSizePixel = 0
        sliderButton.Text = ""
        sliderButton.Parent = sliderContainer
        
        local sliderButtonCorner = Instance.new("UICorner")
        sliderButtonCorner.CornerRadius = UDim.new(1, 0)
        sliderButtonCorner.Parent = sliderButton
        
        local isDragging = false
        
        sliderButton.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isDragging = true
            end
        end)
        
        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isDragging = false
            end
        end)
        
        UserInputService.InputChanged:Connect(function(input)
            if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local trackAbsolutePosition = sliderTrack.AbsolutePosition.X
                local trackAbsoluteSize = sliderTrack.AbsoluteSize.X
                local percentage = math.clamp((input.Position.X - trackAbsolutePosition) / trackAbsoluteSize, 0, 1)
                
                local value = min + (max - min) * percentage
                value = math.floor(value * 10) / 10
                
                settings[settingKey] = value
                
                sliderValueLabel.Text = tostring(value) .. suffix
                sliderFill.Size = UDim2.new(percentage, 0, 1, 0)
                sliderButton.Position = UDim2.new(percentage, -8, 0.7, -6)
            end
        end)
        
        return sliderContainer
    end
    
    createToggle(generalSettings, "AutoRestart", "Auto restart after round ends", true, "autoRestart", 1)
    createToggle(generalSettings, "EnableOutput", "Enable console output", true, "enableConsoleOutput", 2)
    createToggle(generalSettings, "EnableSaving", "Save settings to file", true, "enableSaving", 3)
    
    createSlider(uiSettings, "UIScale", "UI Scale", 0.8, 1.5, 1.0, "uiScale", 1, "x")
    
    createToggle(scanSettings, "ScanEnabled", "Perform map scanning", true, "scanEnabled", 1)
    createSlider(scanSettings, "ScanSteps", "Scan steps", 10, 100, 50, "scanSteps", 2)
    createSlider(scanSettings, "ScanDelay", "Scan delay", 0.1, 1.0, 0.3, "scanDelay", 3, "s")
    
    createToggle(antiStuckSettings, "JumpOnStuck", "Jump when stuck", true, "jumpOnStuck", 1)
    createToggle(antiStuckSettings, "SkipStuckBonds", "Skip bonds that take too long", true, "skipStuckBonds", 2)
    createSlider(antiStuckSettings, "StuckTimeout", "Stuck detection time", 1, 10, 2, "stuckTimeout", 3, "s")
    createSlider(antiStuckSettings, "MaxBondTime", "Max time per bond", 10, 60, 30, "maxBondTime", 4, "s")
    createSlider(antiStuckSettings, "MaxAttempts", "Max attempts per bond", 1, 10, 3, "maxAttemptsPerBond", 5)
    createSlider(antiStuckSettings, "GlobalStuckTimeout", "Global stuck timeout", 5, 30, 15, "globalStuckTimeout", 6, "s")
    
    createSlider(teleportSettings, "TeleportHeight", "Teleport height above bond", 2, 10, 5, "teleportHeight", 1)
    createSlider(teleportSettings, "RetryDelay", "Teleport retry delay", 0.1, 1.0, 0.3, "teleportRetryDelay", 2, "s")
    createSlider(teleportSettings, "TargetProximity", "Target proximity", 2, 15, 6, "targetProximity", 3)
    
    createToggle(debugSettings, "DebugMode", "Enable debug mode", false, "debugMode", 1)
    
    createToggle(failedBondsSettings, "RetryFailedBonds", "Retry failed bonds", true, "retryFailedBonds", 1)
    createToggle(failedBondsSettings, "UseNoClipForRetry", "Use no-clip for retries", true, "useNoClipForRetry", 2)
    createSlider(failedBondsSettings, "MaxFailedRetries", "Max failed bond retries", 1, 5, 2, "maxFailedRetries", 3)
    createSlider(failedBondsSettings, "FailedBondRetryDelay", "Retry delay", 0.1, 2.0, 0.5, "failedBondRetryDelay", 4, "s")
    
    createToggle(bondAuraSettings, "EnableBondAura", "Enable bond aura", true, "enableBondAura", 1)
    createSlider(bondAuraSettings, "BondAuraRadius", "Aura radius", 5, 20, 12, "bondAuraRadius", 2, " studs")
    createSlider(bondAuraSettings, "BondAuraInterval", "Check interval", 0.1, 2.0, 0.5, "bondAuraInterval", 3, "s")
    
    createToggle(noClipSettings, "SmartNoClip", "Smart NoClip (only collide with floor)", true, "smartNoClip", 1)
    
    debugSettings = createSection("Debug", "Debug Settings", 10)
    
    closeButton.MouseButton1Click:Connect(function()
        panel.Visible = false
    end)
    
    saveButton.MouseButton1Click:Connect(function()
        if saveSettings() then
            showNotification("Settings saved!", Color3.fromRGB(59, 165, 93), 2)
        end
    end)
    
    enableDragging(panel)
    
    updateCanvasSize()
    
    return panel
end

_G.recreateSettingsPanel = recreateSettingsPanel

local function setupAutoRestart()
    local success, errorMsg = pcall(function()
        if _G.queuedRestart then 
            print("Auto-Restart ist bereits in der Queue - überspringe")
            return 
        end
        
        if not settings or not settings.autoRestart then 
            print("Auto-Restart ist deaktiviert in den Einstellungen")
            return 
        end
        
        _G.queuedRestart = true
        _G.isInRestart = true
            
        local restartCode = [[
        -- Restart-Status zurücksetzen
        _G.queuedRestart = false;
        _G.isInRestart = false;
        
        -- Vorherigen Start merken
        _G.hasStartedBefore = true;
        
        -- Skript neustarten
        pcall(function()
            loadstring(game:HttpGet("CHANGE THIS YOU RETARED NIGGER"))()
        end)
        ]]

        if queue_on_tp then
            queue_on_tp(restartCode)
            print("Auto-Restart-Code erfolgreich in die Queue gestellt")
        else
            warn("Queue-on-Teleport-Funktion nicht verfügbar")
            _G.queuedRestart = false
        end
    end)
    
    if not success then
        warn("Fehler beim Einrichten des Auto-Restarts: " .. tostring(errorMsg))
        _G.queuedRestart = false
        _G.isInRestart = false
    end
end


