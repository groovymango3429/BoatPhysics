-- BoatServer.lua
-- Server-side script for boat physics and control
-- Place this script inside the boat model in Workspace

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local boat = script.Parent
assert(boat and boat:IsA("Model"), "Script must be placed inside the boat model")

-- Configuration
local CONFIG = {
	-- Boat dimensions (expected model size)
	boatSize = Vector3.new(5.593, 2.472, 12.828),

	-- Movement settings
	maxSpeed = 25,              -- Maximum speed in studs/second
	acceleration = 4,           -- How fast the boat accelerates (slightly snappier)
	turnSpeed = 7,            -- How fast the boat turns (increased responsiveness)
	waterDrag = 2.5,            -- Drag when in water
	terrainFriction = 10,       -- Friction when on land/terrain

	-- Buoyancy settings (tuned to avoid short bursts and sinking)
	buoyancyForce = 2.5,        -- Upward force multiplier (increased for better float)
	buoyancyDamping = 0.3,      -- Damping factor for smooth transitions
	waterDetectionDepth = 1.5,  -- How deep to check for water below float points
	floatHeight = 1.5,          -- Target height above water surface (raised to prevent sinking)

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
	lateralDamping = 3.0,       -- moderate suppression of sideways velocity

	-- Angular damping (reduces runaway spins)
	angularDamping = 4.0,       -- mild rotational damping so turns feel natural
	maxAngularVelocity = 8.0,   -- clamp for angular velocity (rad/s)

	-- Nosedive compensation (adds upward bias proportional to forward throttle & speed)
	nosediveCompensation = 0.5, -- reduced upward bias when accelerating to prevent excessive lift

	-- BodyGyro torque tuning for pitch/roll/yaw
	pitchRollTorque = 6000,     -- X/Z torque to keep level (higher so we don't nose over)
	yawTorque = 25000,          -- Y torque for steering (much higher to make turning responsive)

	-- Buoyancy smoothing scale (prevent instant large velocity jumps)
	buoyancyTimeScale = 1.0,    -- how strongly buoyancy applies per second (use deltaTime to scale)

	-- Idle bobbing (small, realistic movement)
	idleBobFrequency = 1.2,
	idleBobAmplitude = 0.02,  -- reduced amplitude for less movement

	-- Debug
	showDebugPoints = true,
}

-- State variables
local hull = nil
local seat = nil
local currentDriver = nil
local driveThrottle = 0
local driveSteer = 0

-- Physics components
local bodyVelocity = nil
local bodyGyro = nil
local floatPoints = {}
local debugParts = {}

-- RemoteEvent for client communication (create if missing)
local boatInputEvent = ReplicatedStorage:FindFirstChild("BoatInput")
if not boatInputEvent then
	boatInputEvent = Instance.new("RemoteEvent")
	boatInputEvent.Name = "BoatInput"
	boatInputEvent.Parent = ReplicatedStorage
end

local boatSeatedEvent = ReplicatedStorage:FindFirstChild("BoatSeated")
if not boatSeatedEvent then
	boatSeatedEvent = Instance.new("RemoteEvent")
	boatSeatedEvent.Name = "BoatSeated"
	boatSeatedEvent.Parent = ReplicatedStorage
end

local boatRequestSeatEvent = ReplicatedStorage:FindFirstChild("BoatRequestSeat")
if not boatRequestSeatEvent then
	boatRequestSeatEvent = Instance.new("RemoteEvent")
	boatRequestSeatEvent.Name = "BoatRequestSeat"
	boatRequestSeatEvent.Parent = ReplicatedStorage
end

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

-- Optional helper: add an invisible ballast to centralize mass (uncomment if needed)
local function addBallast()
	if boat:FindFirstChild("Ballast") then return end
	local ballast = Instance.new("Part")
	ballast.Name = "Ballast"
	ballast.Size = Vector3.new(0.6, 0.6, 0.6)
	ballast.Transparency = 1
	ballast.CanCollide = false
	ballast.Anchored = false
	-- Give a large density to increase mass contribution
	ballast.CustomPhysicalProperties = PhysicalProperties.new(200, 0.5, 0.5, 1, 1)
	ballast.Parent = boat
	-- Position it just under hull center (if hull exists this will be adjusted later)
	spawn(function()
		wait(0.02)
		if hull then
			ballast.Position = hull.Position - Vector3.new(0, math.max(hull.Size.Y/2,1), 0)
		end
	end)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hull
	weld.Part1 = ballast
	weld.Parent = ballast
end

-- Initialize the boat
local function initializeBoat()
	print("[BoatServer DEBUG] Initializing boat:", boat.Name)

	-- Find the hull (PrimaryPart)
	hull = boat.PrimaryPart or boat:FindFirstChild("Hull") or boat:FindFirstChildWhichIsA("BasePart")
	if not hull then
		warn("BoatServer: No hull found! Set Model.PrimaryPart or add a part named 'Hull'")
		return false
	end

	print("[BoatServer DEBUG] Found hull:", hull.Name, "Size:", hull.Size)

	-- Unanchor hull
	hull.Anchored = false
	hull.CanCollide = true

	-- Set network owner to server
	hull:SetNetworkOwner(nil)

	-- Find or create seat
	seat = boat:FindFirstChild("DriverSeat") or boat:FindFirstChildWhichIsA("Seat") or boat:FindFirstChildWhichIsA("VehicleSeat")
	if not seat then
		warn("BoatServer: No seat found! Add a Seat or VehicleSeat named 'DriverSeat'")
		return false
	end

	print("[BoatServer DEBUG] Found seat:", seat.Name)

	-- Weld other parts to hull and disable collisions on non-hull parts
	for _, part in ipairs(boat:GetDescendants()) do
		if part:IsA("BasePart") and part ~= hull then
			part.Anchored = false
			part.CanCollide = false -- ensure non-hull parts don't cause torque on collisions

			-- Create weld to hull
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hull
			weld.Part1 = part
			weld.Parent = part
		end
	end

	-- Ensure seat is non-collidable and unanchored
	if seat then
		seat.CanCollide = false
		seat.Anchored = false
	end

	print("[BoatServer DEBUG] Welded all parts to hull and disabled collisions on non-hull parts")

	-- Create BodyVelocity for movement
	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	bodyVelocity.Velocity = Vector3.new(0, 0, 0)
	bodyVelocity.P = 5000  -- Reduced from 10000 to prevent overshooting
	bodyVelocity.Parent = hull

	-- Create BodyGyro for stabilization
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	bodyGyro.P = 7000
	bodyGyro.D = 800
	bodyGyro.Parent = hull

	print("[BoatServer DEBUG] Created BodyVelocity and BodyGyro")

	-- Create float points at corners of boat
	local hullSize = hull.Size
	local offsets = {
		Vector3.new(-hullSize.X/2 + CONFIG.floatPointOffset, -hullSize.Y/2, -hullSize.Z/2 + CONFIG.floatPointOffset),  -- Front-left
		Vector3.new(hullSize.X/2 - CONFIG.floatPointOffset, -hullSize.Y/2, -hullSize.Z/2 + CONFIG.floatPointOffset),   -- Front-right
		Vector3.new(-hullSize.X/2 + CONFIG.floatPointOffset, -hullSize.Y/2, hullSize.Z/2 - CONFIG.floatPointOffset),   -- Back-left
		Vector3.new(hullSize.X/2 - CONFIG.floatPointOffset, -hullSize.Y/2, hullSize.Z/2 - CONFIG.floatPointOffset),    -- Back-right
	}

	for i, offset in ipairs(offsets) do
		-- Create attachment for float point
		local attachment = Instance.new("Attachment")
		attachment.Name = "FloatPoint" .. i
		attachment.Position = offset
		attachment.Parent = hull

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

	print("[BoatServer DEBUG] Created", #floatPoints, "float points with debug visualization")
	-- Optionally add ballast if model pivot/mass distribution is off (uncomment if needed)
	-- addBallast()
	print("BoatServer: Initialized boat with hull:", hull.Name)
	return true
end

-- Physics update loop
local function updateBoatPhysics(deltaTime)
	if not hull or not bodyVelocity or not bodyGyro then
		return
	end

	-- Mild angular damping to keep rotations under control but still allow natural turning
	local angVel = hull.AssemblyAngularVelocity
	local angDampFactor = math.clamp(1 - CONFIG.angularDamping * deltaTime, 0, 1)
	angVel = angVel * angDampFactor
	if angVel.Magnitude > CONFIG.maxAngularVelocity then
		angVel = angVel.Unit * CONFIG.maxAngularVelocity
	end
	hull.AssemblyAngularVelocity = angVel

	-- Get hull mass (ignore player weight per requirements)
	local hullMass = hull:GetMass()
	local totalMass = hullMass

	-- Check float points for water contact
	local floatPointsInWater = 0
	local totalBuoyancyVelocity = 0  -- Accumulate velocity corrections from float points
	local avgWaterLevel = 0
	local waterLevelCount = 0

	for i, attachment in ipairs(floatPoints) do
		local worldPos = attachment.WorldPosition
		local inWater, waterLevel = isPointInWater(worldPos)

		if inWater and waterLevel then
			floatPointsInWater = floatPointsInWater + 1

			-- Calculate submersion depth (positive means submerged)
			local submersion = waterLevel - worldPos.Y + CONFIG.floatHeight

			if submersion > 0 then
				-- Calculate buoyancy force more smoothly without velocity-based corrections
				-- Use a simpler proportional force based on submersion depth
				local buoyancyStrength = submersion * CONFIG.buoyancyForce
				
				-- Apply smooth damping based on current vertical velocity to prevent oscillation
				local currentVerticalVelocity = hull.AssemblyLinearVelocity.Y
				local dampingFactor = -currentVerticalVelocity * CONFIG.buoyancyDamping
				
				-- Combine buoyancy and damping for smooth behavior
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
	if currentDriver and math.abs(driveThrottle) > 0.01 then
		desiredForwardSpeed = driveThrottle * CONFIG.maxSpeed
	end

	-- Smoothly accelerate forward/backward toward desiredForwardSpeed
	local accelFactor = math.clamp(CONFIG.acceleration * deltaTime, 0, 1)
	forwardSpeed = forwardSpeed + (desiredForwardSpeed - forwardSpeed) * accelFactor

	-- Moderate lateral damping so the boat still feels natural in turns
	local lateralDampingFactor = math.clamp(1 - CONFIG.lateralDamping * deltaTime, 0, 1)
	rightSpeed = rightSpeed * lateralDampingFactor

	-- Recompose horizontal velocity
	local desiredHorizontal = forwardHorizontal * forwardSpeed + rightHorizontal * rightSpeed

	-- Compute vertical velocity target from buoyancy (average contributions)
	local verticalAdjustment = currentVertical
	if floatPointsInWater > 0 then
		local avgBuoyancyVelocity = totalBuoyancyVelocity / math.max(1, floatPointsInWater)
		verticalAdjustment = currentVertical + avgBuoyancyVelocity
	end

	-- Nosedive compensation: add upward bias when accelerating forward to prevent nose dipping
	if currentDriver and driveThrottle > 0.01 then
		local speedFrac = math.clamp(math.abs(forwardSpeed) / CONFIG.maxSpeed, 0, 1)
		local nosediveBoost = CONFIG.nosediveCompensation * driveThrottle * (0.35 + 0.65 * speedFrac)
		verticalAdjustment = verticalAdjustment + nosediveBoost * deltaTime
	end

	-- Idle bobbing for realism when in water and not accelerating heavily
	if isInWater then
		local bob = math.sin(tick() * CONFIG.idleBobFrequency) * CONFIG.idleBobAmplitude
		verticalAdjustment = verticalAdjustment + bob * (1 - math.clamp(math.abs(driveThrottle), 0, 1))
	end

	-- Limit vertical change rate to avoid quick pops
	local maxVertChangePerSec = 15  -- increased to allow faster response to buoyancy
	local vertDelta = verticalAdjustment - currentVertical
	local maxDeltaThisFrame = maxVertChangePerSec * deltaTime
	if math.abs(vertDelta) > maxDeltaThisFrame then
		verticalAdjustment = currentVertical + math.sign(vertDelta) * maxDeltaThisFrame
	end

	-- Compose final velocity to assign to BodyVelocity:
	local finalVelocity = Vector3.new(desiredHorizontal.X, verticalAdjustment, desiredHorizontal.Z)

	-- Set BodyVelocity max force depending on whether we need vertical authority
	if isInWater then
		bodyVelocity.MaxForce = Vector3.new(5000, 5000, 5000) * totalMass  -- Reduced from 8000 for smoother control
	else
		bodyVelocity.MaxForce = Vector3.new(5000, 0, 5000) * totalMass
	end

	bodyVelocity.Velocity = finalVelocity

	-- Handle turning (yaw) and stabilization
	local hasDriver = currentDriver ~= nil
	local isSteering = math.abs(driveSteer) > 0.01

	-- Compute yaw responsiveness: allow baseline turning even at low speed, scale up with forward speed
	local forwardSpeedFrac = math.clamp(math.abs(forwardSpeed) / CONFIG.maxSpeed, 0, 1)
	local baseTurnFactor = 0.45 -- ensures turning remains responsive at zero/low speed
	local speedTurnFactor = baseTurnFactor + 0.55 * forwardSpeedFrac
	local yawDelta = 0
	if hasDriver then
		yawDelta = driveSteer * CONFIG.turnSpeed * speedTurnFactor * deltaTime
	end

	-- Target yaw (preserve current yaw, add yawDelta)
	local currentYaw = math.atan2(forwardVector.X, forwardVector.Z)
	local targetYaw = currentYaw + yawDelta

	-- Always keep pitch/roll leveled while in water by enforcing BodyGyro X/Z torque.
	-- Allow yaw torque to be large for steering.
	if isInWater then
		local pitchRollT = CONFIG.pitchRollTorque * totalMass
		local yawT = (hasDriver and isSteering) and (CONFIG.yawTorque * totalMass) or (CONFIG.yawTorque * 0.25 * totalMass)

		bodyGyro.MaxTorque = Vector3.new(pitchRollT, yawT, pitchRollT)
		bodyGyro.CFrame = CFrame.new(hull.Position) * CFrame.Angles(0, targetYaw, 0)
		-- keep high P for responsive yaw but tuned D for stability
		bodyGyro.P = 7000
		bodyGyro.D = 900
	else
		-- On land: allow gravity/terrain to act more, but try to keep level
		bodyGyro.MaxTorque = Vector3.new(1500 * totalMass, 0, 1500 * totalMass)
		bodyGyro.CFrame = CFrame.new(hull.Position) * CFrame.Angles(0, targetYaw, 0)
		bodyGyro.P = 3000
		bodyGyro.D = 400
	end
end

-- Initialize boat
if not initializeBoat() then
	warn("BoatServer: Failed to initialize boat")
	return
end

-- Connect seat occupancy changes AFTER initialization so 'seat' is defined
if seat then
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		if occupant then
			local character = occupant.Parent
			local player = Players:GetPlayerFromCharacter(character)
			if player then
				print("[BoatServer DEBUG] Player seated:", player.Name)
				currentDriver = player
				-- Notify that player is seated. Send boat model so client knows which boat it is.
				boatSeatedEvent:FireClient(player, true, boat)
			end
		else
			-- occupant became nil
			local prevDriver = currentDriver
			print("[BoatServer DEBUG] Player left seat, previous driver was:", prevDriver and prevDriver.Name or "nil")
			if prevDriver then
				boatSeatedEvent:FireClient(prevDriver, false)
			end
			currentDriver = nil
			driveThrottle = 0
			driveSteer = 0

			-- Reset BodyGyro to prevent spinning
			if bodyGyro then
				bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
				bodyGyro.CFrame = hull.CFrame
				print("[BoatServer DEBUG] Reset BodyGyro after player exit")
			end
		end
	end)
end

-- Handle player input from client
boatInputEvent.OnServerEvent:Connect(function(player, throttle, steer)
	-- Validate player is the driver
	if currentDriver ~= player then
		return
	end

	-- Clamp input values
	driveThrottle = math.clamp(throttle or 0, -1, 1)
	driveSteer = math.clamp(steer or 0, -1, 1)
end)

-- Handle client requests to be seated (server-authoritative)
boatRequestSeatEvent.OnServerEvent:Connect(function(player, boatModel)
	if boatModel ~= boat then
		return
	end

	if not seat then return end
	if seat.Occupant then
		print("[BoatServer DEBUG] Seat already occupied, rejecting request from", player.Name)
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		print("[BoatServer DEBUG] Rejecting seat request: no HRP for player", player.Name)
		return
	end

	local boatPos = hull and hull.Position or (boat.PrimaryPart and boat.PrimaryPart.Position)
	if not boatPos then
		print("[BoatServer DEBUG] Rejecting seat request: no boat position")
		return
	end

	if (hrp.Position - boatPos).Magnitude > 12 then
		print("[BoatServer DEBUG] Rejecting seat request: player too far", player.Name)
		return
	end

	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		print("[BoatServer DEBUG] Server seating player:", player.Name)
		seat:Sit(humanoid)
	else
		print("[BoatServer DEBUG] Can't seat player, no humanoid:", player.Name)
	end
end)

-- Connect to heartbeat
RunService.Heartbeat:Connect(updateBoatPhysics)

print("BoatServer: Boat script loaded successfully")
