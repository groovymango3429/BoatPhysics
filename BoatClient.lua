-- BoatClient.lua
-- Client-side script for boat interaction, input, and physics
-- Place this LocalScript in StarterPlayer -> StarterPlayerScripts
-- Physics moved to client for better performance (no server lag)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local INTERACTION_KEY = Enum.KeyCode.E
local MAX_DISTANCE = 10

-- Configuration for client-side physics
local CONFIG = {
	-- Boat dimensions (expected model size)
	boatSize = Vector3.new(5.593, 2.472, 12.828),

	-- Movement settings
	maxSpeed = 25,              -- Maximum speed in studs/second
	acceleration = 5,           -- How fast the boat accelerates
	turnSpeed = 8,              -- How fast the boat turns
	waterDrag = 2.5,            -- Drag when in water
	landFriction = 25,          -- High friction when on land (feels like pushing heavy boat)

	-- Buoyancy settings
	buoyancyForce = 2.5,        -- Upward force multiplier
	buoyancyDamping = 0.3,      -- Damping factor for smooth transitions
	waterDetectionDepth = 1.5,  -- How deep to check for water below float points
	floatHeight = 1.5,          -- Target height above water surface

	-- Physics settings
	enableGravity = true,
	gravityScale = 1.0,

	-- Stabilization (keeps boat upright)
	stabilizationStrength = 0.6,
	maxStabilizationTorque = 6.0,

	-- Float points (corners of boat for buoyancy calculation)
	numFloatPoints = 4,
	floatPointOffset = 0.8,     -- Inset from edges

	-- Player weight - DISABLED per requirements
	ignorePlayerWeight = true,

	-- Lateral damping (reduces unwanted sideways velocity)
	lateralDamping = 3.0,

	-- Angular damping (reduces runaway spins)
	angularDamping = 4.0,
	maxAngularVelocity = 8.0,   -- clamp for angular velocity (rad/s)

	-- Nosedive compensation
	nosediveCompensation = 0.5,

	-- BodyGyro torque tuning for pitch/roll/yaw
	pitchRollTorque = 6000,
	yawTorque = 25000,

	-- Idle bobbing (small, realistic movement)
	idleBobFrequency = 1.2,
	idleBobAmplitude = 0.02,

	-- Debug
	showDebugPoints = true,
}

-- Wait for RemoteEvents
local boatSeatedEvent = ReplicatedStorage:WaitForChild("BoatSeated")
local boatRequestSeatEvent = ReplicatedStorage:WaitForChild("BoatRequestSeat")

-- State variables
local currentBoat = nil
local isSeated = false
local throttle = 0
local steer = 0

-- Physics components for current boat
local hull = nil
local bodyVelocity = nil
local bodyGyro = nil
local floatPoints = {}
local debugParts = {}

-- Input tracking
local keysDown = {}

-- Helper: Get water level at a position using terrain voxels
local function getWaterLevelAt(position)
	local searchSize = Vector3.new(4, 4, 4)
	local region = Region3.new(position - searchSize/2, position + searchSize/2)
	region = region:ExpandToGrid(4)

	local success, materials, sizes = pcall(function()
		return workspace.Terrain:ReadVoxels(region, 4)
	end)

	if not success then
		return false, nil
	end

	local size = materials.Size
	local regionStart = region.CFrame.Position - region.Size / 2
	local voxelSize = 4
	local hasWater = false
	local highestWaterY = nil

	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if materials[x][y][z] == Enum.Material.Water then
					hasWater = true
					local voxelWorldY = regionStart.Y + (y - 1) * voxelSize + voxelSize / 2
					if not highestWaterY or voxelWorldY > highestWaterY then
						highestWaterY = voxelWorldY
					end
				end
			end
		end
	end

	return hasWater, highestWaterY
end

-- Helper: Check if a point is in water
local function isPointInWater(position)
	local hasWater, waterLevel = getWaterLevelAt(position)
	if hasWater and waterLevel then
		return position.Y < waterLevel + CONFIG.waterDetectionDepth, waterLevel
	end
	return false, nil
end

-- Initialize physics components for a boat
local function initializeBoatPhysics(boat)
	print("[BoatClient DEBUG] Initializing client-side physics for boat:", boat.Name)
	
	-- Clean up old physics components
	if bodyVelocity then bodyVelocity:Destroy() end
	if bodyGyro then bodyGyro:Destroy() end
	for _, part in ipairs(debugParts) do
		if part then part:Destroy() end
	end
	floatPoints = {}
	debugParts = {}
	
	-- Find the hull
	hull = boat.PrimaryPart or boat:FindFirstChild("Hull") or boat:FindFirstChildWhichIsA("BasePart")
	if not hull then
		warn("[BoatClient] No hull found for boat:", boat.Name)
		return false
	end
	
	print("[BoatClient DEBUG] Found hull:", hull.Name)
	
	-- Create BodyVelocity for movement
	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	bodyVelocity.Velocity = Vector3.new(0, 0, 0)
	bodyVelocity.P = 5000
	bodyVelocity.Parent = hull

	-- Create BodyGyro for stabilization
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	bodyGyro.P = 7000
	bodyGyro.D = 800
	bodyGyro.Parent = hull

	print("[BoatClient DEBUG] Created BodyVelocity and BodyGyro")

	-- Create float points at corners of boat
	local hullSize = hull.Size
	local offsets = {
		Vector3.new(-hullSize.X/2 + CONFIG.floatPointOffset, -hullSize.Y/2, -hullSize.Z/2 + CONFIG.floatPointOffset),  -- Front-left
		Vector3.new(hullSize.X/2 - CONFIG.floatPointOffset, -hullSize.Y/2, -hullSize.Z/2 + CONFIG.floatPointOffset),   -- Front-right
		Vector3.new(-hullSize.X/2 + CONFIG.floatPointOffset, -hullSize.Y/2, hullSize.Z/2 - CONFIG.floatPointOffset),   -- Back-left
		Vector3.new(hullSize.X/2 - CONFIG.floatPointOffset, -hullSize.Y/2, hullSize.Z/2 - CONFIG.floatPointOffset),    -- Back-right
	}

	for i, offset in ipairs(offsets) do
		-- Find or create attachment for float point
		local attachment = hull:FindFirstChild("FloatPoint" .. i)
		if not attachment then
			attachment = Instance.new("Attachment")
			attachment.Name = "FloatPoint" .. i
			attachment.Position = offset
			attachment.Parent = hull
		end

		table.insert(floatPoints, attachment)

		-- Create debug visualization
		if CONFIG.showDebugPoints then
			local debugPart = Instance.new("Part")
			debugPart.Name = "DebugFloat" .. i
			debugPart.Size = Vector3.new(0.5, 0.5, 0.5)
			debugPart.Anchored = true
			debugPart.CanCollide = false
			debugPart.Transparency = 0.5
			debugPart.Color = Color3.fromRGB(0, 170, 255)
			debugPart.Parent = hull

			table.insert(debugParts, debugPart)
		end
	end

	print("[BoatClient DEBUG] Created", #floatPoints, "float points")
	return true
end

-- Clean up physics components
local function cleanupBoatPhysics()
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
	if bodyGyro then
		bodyGyro:Destroy()
		bodyGyro = nil
	end
	for _, part in ipairs(debugParts) do
		if part then part:Destroy() end
	end
	floatPoints = {}
	debugParts = {}
	hull = nil
	print("[BoatClient DEBUG] Cleaned up physics components")
end

-- Client-side physics update loop
local function updateBoatPhysics(deltaTime)
	if not isSeated or not hull or not bodyVelocity or not bodyGyro then
		return
	end

	-- Mild angular damping
	local angVel = hull.AssemblyAngularVelocity
	local angDampFactor = math.clamp(1 - CONFIG.angularDamping * deltaTime, 0, 1)
	angVel = angVel * angDampFactor
	if angVel.Magnitude > CONFIG.maxAngularVelocity then
		angVel = angVel.Unit * CONFIG.maxAngularVelocity
	end
	hull.AssemblyAngularVelocity = angVel

	-- Get hull mass
	local hullMass = hull:GetMass()
	local totalMass = hullMass

	-- Check float points for water contact
	local floatPointsInWater = 0
	local totalBuoyancyVelocity = 0
	local avgWaterLevel = 0
	local waterLevelCount = 0

	for i, attachment in ipairs(floatPoints) do
		local worldPos = attachment.WorldPosition
		local inWater, waterLevel = isPointInWater(worldPos)

		if inWater and waterLevel then
			floatPointsInWater = floatPointsInWater + 1

			-- Calculate submersion depth
			local submersion = waterLevel - worldPos.Y + CONFIG.floatHeight

			if submersion > 0 then
				local buoyancyStrength = submersion * CONFIG.buoyancyForce
				local currentVerticalVelocity = hull.AssemblyLinearVelocity.Y
				local dampingFactor = -currentVerticalVelocity * CONFIG.buoyancyDamping
				local velocityCorrection = buoyancyStrength + dampingFactor
				totalBuoyancyVelocity = totalBuoyancyVelocity + velocityCorrection

				avgWaterLevel = avgWaterLevel + waterLevel
				waterLevelCount = waterLevelCount + 1
			end
		end

		-- Update debug visualization
		if CONFIG.showDebugPoints and debugParts[i] then
			debugParts[i].Position = worldPos
			if inWater then
				debugParts[i].Color = Color3.fromRGB(0, 255, 100)
			else
				debugParts[i].Color = Color3.fromRGB(255, 100, 0)
			end
		end
	end

	local isInWater = floatPointsInWater > 0
	if waterLevelCount > 0 then
		avgWaterLevel = avgWaterLevel / waterLevelCount
	end

	-- Movement basis vectors
	local forwardVector = hull.CFrame.LookVector
	local rightVector = hull.CFrame.RightVector

	-- Horizontal movement direction (world-space, flat)
	local forwardHorizontal = Vector3.new(forwardVector.X, 0, forwardVector.Z)
	if forwardHorizontal.Magnitude > 0 then forwardHorizontal = forwardHorizontal.Unit end
	local rightHorizontal = Vector3.new(rightVector.X, 0, rightVector.Z)
	if rightHorizontal.Magnitude > 0 then rightHorizontal = rightHorizontal.Unit end

	-- Current velocities
	local currentVelocity = hull.AssemblyLinearVelocity
	local currentHorizontal = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
	local currentVertical = currentVelocity.Y

	-- Convert current horizontal velocity into local forward/right components
	local forwardSpeed = 0
	local rightSpeed = 0
	if forwardHorizontal.Magnitude > 0 then
		forwardSpeed = currentHorizontal:Dot(forwardHorizontal)
	end
	if rightHorizontal.Magnitude > 0 then
		rightSpeed = currentHorizontal:Dot(rightHorizontal)
	end

	-- Desired forward speed from input
	local desiredForwardSpeed = 0
	if math.abs(throttle) > 0.01 then
		desiredForwardSpeed = throttle * CONFIG.maxSpeed
	end

	-- Apply friction based on terrain type
	local frictionMultiplier = isInWater and CONFIG.waterDrag or CONFIG.landFriction
	
	-- Smoothly accelerate forward/backward toward desiredForwardSpeed
	local accelFactor = math.clamp(CONFIG.acceleration * deltaTime, 0, 1)
	forwardSpeed = forwardSpeed + (desiredForwardSpeed - forwardSpeed) * accelFactor
	
	-- Apply friction/drag (stronger on land)
	local frictionFactor = math.clamp(1 - frictionMultiplier * deltaTime, 0, 1)
	if math.abs(throttle) < 0.01 then
		-- Apply friction when not accelerating
		forwardSpeed = forwardSpeed * frictionFactor
	end

	-- Lateral damping
	local lateralDampingFactor = math.clamp(1 - CONFIG.lateralDamping * deltaTime, 0, 1)
	rightSpeed = rightSpeed * lateralDampingFactor

	-- Recompose horizontal velocity
	local desiredHorizontal = forwardHorizontal * forwardSpeed + rightHorizontal * rightSpeed

	-- Compute vertical velocity target from buoyancy
	local verticalAdjustment = currentVertical
	if floatPointsInWater > 0 then
		local avgBuoyancyVelocity = totalBuoyancyVelocity / math.max(1, floatPointsInWater)
		verticalAdjustment = currentVertical + avgBuoyancyVelocity
	end

	-- Nosedive compensation
	if throttle > 0.01 then
		local speedFrac = math.clamp(math.abs(forwardSpeed) / CONFIG.maxSpeed, 0, 1)
		local nosediveBoost = CONFIG.nosediveCompensation * throttle * (0.35 + 0.65 * speedFrac)
		verticalAdjustment = verticalAdjustment + nosediveBoost * deltaTime
	end

	-- Idle bobbing
	if isInWater then
		local bob = math.sin(tick() * CONFIG.idleBobFrequency) * CONFIG.idleBobAmplitude
		verticalAdjustment = verticalAdjustment + bob * (1 - math.clamp(math.abs(throttle), 0, 1))
	end

	-- Limit vertical change rate
	local maxVertChangePerSec = 15
	local vertDelta = verticalAdjustment - currentVertical
	local maxDeltaThisFrame = maxVertChangePerSec * deltaTime
	if math.abs(vertDelta) > maxDeltaThisFrame then
		verticalAdjustment = currentVertical + math.sign(vertDelta) * maxDeltaThisFrame
	end

	-- Compose final velocity
	local finalVelocity = Vector3.new(desiredHorizontal.X, verticalAdjustment, desiredHorizontal.Z)

	-- Set BodyVelocity max force
	if isInWater then
		bodyVelocity.MaxForce = Vector3.new(5000, 5000, 5000) * totalMass
	else
		bodyVelocity.MaxForce = Vector3.new(5000, 0, 5000) * totalMass
	end

	bodyVelocity.Velocity = finalVelocity

	-- Handle turning (yaw) and stabilization
	local isSteering = math.abs(steer) > 0.01

	-- Compute yaw responsiveness
	local forwardSpeedFrac = math.clamp(math.abs(forwardSpeed) / CONFIG.maxSpeed, 0, 1)
	local baseTurnFactor = 0.45
	local speedTurnFactor = baseTurnFactor + 0.55 * forwardSpeedFrac
	local yawDelta = steer * CONFIG.turnSpeed * speedTurnFactor * deltaTime

	-- Target yaw
	local currentYaw = math.atan2(forwardVector.X, forwardVector.Z)
	local targetYaw = currentYaw + yawDelta

	-- Stabilization
	if isInWater then
		local pitchRollT = CONFIG.pitchRollTorque * totalMass
		local yawT = isSteering and (CONFIG.yawTorque * totalMass) or (CONFIG.yawTorque * 0.25 * totalMass)

		bodyGyro.MaxTorque = Vector3.new(pitchRollT, yawT, pitchRollT)
		bodyGyro.CFrame = CFrame.new(hull.Position) * CFrame.Angles(0, targetYaw, 0)
		bodyGyro.P = 7000
		bodyGyro.D = 900
	else
		-- On land: less stabilization, more friction
		bodyGyro.MaxTorque = Vector3.new(1500 * totalMass, 0, 1500 * totalMass)
		bodyGyro.CFrame = CFrame.new(hull.Position) * CFrame.Angles(0, targetYaw, 0)
		bodyGyro.P = 3000
		bodyGyro.D = 400
	end
end

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
				-- Extra safety: always hide if seated, regardless of targetBoat
				local shouldShow = (not isSeated) and (boat == targetBoat)
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
end

-- Try to board the current boat
local function tryBoardBoat()
	if not currentBoat or isSeated then 
		return 
	end

	-- Fire server request to seat the player
	print("[BoatClient DEBUG] Requesting server to board boat:", currentBoat.Name)
	boatRequestSeatEvent:FireServer(currentBoat)
end

-- Handle E key press and input tracking
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == INTERACTION_KEY then
		tryBoardBoat()
	end

	-- Handle driving controls
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = true
		if isSeated then
			updateDrivingInput()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, processed)
	-- Track key releases
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
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

-- Listen for seated status changes from server
boatSeatedEvent.OnClientEvent:Connect(function(seated, boatModel)
	print("[BoatClient DEBUG] Seated status changed:", seated, "Boat:", boatModel)
	isSeated = seated

	if seated then
		-- Player just boarded
		currentBoat = boatModel
		
		-- Initialize client-side physics
		if initializeBoatPhysics(boatModel) then
			print("[BoatClient DEBUG] Successfully initialized client-side physics")
		else
			warn("[BoatClient] Failed to initialize physics for boat")
		end
		
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
		-- Player left boat
		cleanupBoatPhysics()
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
	
	-- Update boat physics if seated
	if isSeated then
		updateBoatPhysics(deltaTime)
	end
end)

print("BoatClient: Boat client script loaded successfully (client-side physics enabled)")
