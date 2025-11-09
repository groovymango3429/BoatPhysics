-- BoatClient.lua
-- Client-side script for boat interaction and input
-- Place this LocalScript in StarterPlayer -> StarterPlayerScripts

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local INTERACTION_KEY = Enum.KeyCode.E
local MAX_DISTANCE = 10

-- Wait for RemoteEvents (server will create BoatRequestSeat if needed)
local boatInputEvent = ReplicatedStorage:WaitForChild("BoatInput")
local boatSeatedEvent = ReplicatedStorage:WaitForChild("BoatSeated")
local boatRequestSeatEvent = ReplicatedStorage:WaitForChild("BoatRequestSeat")

-- State variables
local currentBoat = nil
local isSeated = false
local throttle = 0
local steer = 0

-- Input tracking
local keysDown = {}

-- Function to find boats in workspace
local function getBoatsFolder()
	return Workspace:FindFirstChild("Boats")
end

-- Function to get the boat the player is looking at or nearest to
local function getTargetBoat()
	local boatsFolder = getBoatsFolder()
	if not boatsFolder then return nil end

	local char = player.Character
	if not char or not char:FindFirstChild("HumanoidRootPart") then return nil end

	local hrp = char.HumanoidRootPart
	local cam = Workspace.CurrentCamera
	if not cam then return nil end

	-- First, try raycast to see what player is looking at
	local rayOrigin = cam.CFrame.Position
	local rayDir = cam.CFrame.LookVector * MAX_DISTANCE

	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = {char}
	raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

	local rayResult = Workspace:Raycast(rayOrigin, rayDir, raycastParams)

	-- Check if raycast hit a boat
	if rayResult and rayResult.Instance then
		local hit = rayResult.Instance
		-- Check if this part is a child of a boat
		for _, boat in ipairs(boatsFolder:GetChildren()) do
			if boat:IsA("Model") and hit:IsDescendantOf(boat) then
				local boatPos = boat.PrimaryPart and boat.PrimaryPart.Position or boat:GetModelCFrame().Position
				if (hrp.Position - boatPos).Magnitude <= MAX_DISTANCE then
					return boat
				end
			end
		end
	end

	-- If not looking at a boat, find nearest one within range
	local nearestBoat = nil
	local nearestDist = MAX_DISTANCE

	for _, boat in ipairs(boatsFolder:GetChildren()) do
		if boat:IsA("Model") then
			local boatPos = boat.PrimaryPart and boat.PrimaryPart.Position or boat:GetModelCFrame().Position
			local dist = (hrp.Position - boatPos).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestBoat = boat
			end
		end
	end

	return nearestBoat
end

-- Create or update BillboardGui for a boat
local function ensureBoatPrompt(boat)
	if not boat or not boat.PrimaryPart then return end

	-- Check if billboard already exists
	local billboard = boat.PrimaryPart:FindFirstChild("InteractionPrompt")
	if not billboard then
		-- Create new billboard
		billboard = Instance.new("BillboardGui")
		billboard.Name = "InteractionPrompt"
		billboard.Size = UDim2.new(0, 100, 0, 50)
		billboard.StudsOffset = Vector3.new(0, 3, 0)
		billboard.AlwaysOnTop = true
		billboard.Enabled = false
		billboard.Parent = boat.PrimaryPart

		-- Create frame
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		frame.BackgroundTransparency = 0.5
		frame.BorderSizePixel = 0
		frame.Parent = billboard

		-- Add rounded corners
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		-- Create text label
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = "[E] Board Boat"
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = frame

		-- Add padding
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 5)
		padding.PaddingBottom = UDim.new(0, 5)
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingRight = UDim.new(0, 10)
		padding.Parent = label
	end

	return billboard
end

-- Update boat prompts visibility
local function updateBoatPrompts()
	local boatsFolder = getBoatsFolder()
	if not boatsFolder then return end

	local targetBoat = nil

	-- Don't show any prompts if player is seated
	if not isSeated then
		targetBoat = getTargetBoat()
		currentBoat = targetBoat
	end

	-- Update prompts for all boats
	for _, boat in ipairs(boatsFolder:GetChildren()) do
		if boat:IsA("Model") then
			local billboard = ensureBoatPrompt(boat)
			if billboard then
				-- Only show prompt if player is not seated and this is the target boat
				local shouldShow = (boat == targetBoat and not isSeated)
				billboard.Enabled = shouldShow
			end
		end
	end
end

-- Update driving input from keys
local function updateDrivingInput()
	if not isSeated then
		throttle = 0
		steer = 0
		--print("[BoatClient DEBUG] updateDrivingInput: Not seated, clearing inputs")
		return
	end

	-- Throttle: W/Up => +1, S/Down => -1
	local up = keysDown[Enum.KeyCode.W] or keysDown[Enum.KeyCode.Up]
	local down = keysDown[Enum.KeyCode.S] or keysDown[Enum.KeyCode.Down]
	if up and not down then
		throttle = 1
	elseif down and not up then
		throttle = -1
	else
		throttle = 0
	end

	-- Steer: A/Left => -1 (turn left), D/Right => +1 (turn right)
	local left = keysDown[Enum.KeyCode.A] or keysDown[Enum.KeyCode.Left]
	local right = keysDown[Enum.KeyCode.D] or keysDown[Enum.KeyCode.Right]
	if left and not right then
		steer = -1
	elseif right and not left then
		steer = 1
	else
		steer = 0
	end

	--print("[BoatClient DEBUG] updateDrivingInput: throttle =", throttle, "steer =", steer)
end

-- Try to board the current boat (client now requests server to seat the player)
local function tryBoardBoat()
	if not currentBoat or isSeated then 
		--print("[BoatClient DEBUG] Cannot board: currentBoat =", currentBoat, "isSeated =", isSeated)
		return 
	end

	-- Fire server request to seat the player. Server will validate and sit on server-side.
	print("[BoatClient DEBUG] Requesting server to board boat:", currentBoat.Name)
	boatRequestSeatEvent:FireServer(currentBoat)
end

-- Handle E key press and input tracking
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == INTERACTION_KEY then
		--print("[BoatClient DEBUG] E key pressed, attempting to board boat")
		tryBoardBoat()
	end

	-- Handle driving controls - track key presses regardless of seated state
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = true
		--print("[BoatClient DEBUG] Key pressed:", input.KeyCode, "isSeated:", isSeated)
		-- Update driving input if seated
		if isSeated then
			updateDrivingInput()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, processed)
	-- Track key releases regardless of seated state
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
		--print("[BoatClient DEBUG] Key released:", input.KeyCode, "isSeated:", isSeated)
		-- Update driving input if seated
		if isSeated then
			updateDrivingInput()
		end
	end
end)

-- Handle gamepad input
UserInputService.InputChanged:Connect(function(input, processed)
	if not isSeated then return end

	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local v = input.Position
			local deadzone = 0.15
			-- Y axis for throttle (inverted)
			throttle = math.abs(v.Y) > deadzone and -v.Y or 0
			-- X axis for steering
			steer = math.abs(v.X) > deadzone and v.X or 0
		end
	end
end)

-- Send input to server
local lastSendTime = 0
local sendInterval = 1/30 -- 30 times per second

RunService.Heartbeat:Connect(function()
	local now = tick()
	if now - lastSendTime >= sendInterval then
		if isSeated then
			boatInputEvent:FireServer(throttle, steer)
		end
		lastSendTime = now
	end
end)

-- Listen for seated status changes from server
boatSeatedEvent.OnClientEvent:Connect(function(seated, boatModel)
	--print("[BoatClient DEBUG] Seated status changed:", seated, "Boat:", boatModel)
	isSeated = seated

	if seated then
		-- Player just boarded - store the boat reference
		currentBoat = boatModel
		-- Hide all prompts
		local boatsFolder = getBoatsFolder()
		if boatsFolder then
			for _, boat in ipairs(boatsFolder:GetChildren()) do
				if boat:IsA("Model") and boat.PrimaryPart then
					local billboard = boat.PrimaryPart:FindFirstChild("InteractionPrompt")
					if billboard then
						billboard.Enabled = false
					end
				end
			end
		end
	else
		-- Player left boat - clear inputs and state
		throttle = 0
		steer = 0
		keysDown = {}
		currentBoat = nil
	end
end)

-- Update prompts at a throttled rate
local updateInterval = 0.1
local timeSinceLastUpdate = 0

RunService.Heartbeat:Connect(function(deltaTime)
	timeSinceLastUpdate = timeSinceLastUpdate + deltaTime
	if timeSinceLastUpdate >= updateInterval then
		updateBoatPrompts()
		timeSinceLastUpdate = 0
	end
end)

print("BoatClient: Boat client script loaded successfully")
