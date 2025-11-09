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
	acceleration = 3,           -- How fast the boat accelerates
	turnSpeed = 1.2,            -- How fast the boat turns
	waterDrag = 2.5,            -- Drag when in water
	terrainFriction = 10,       -- Friction when on land/terrain

	-- Buoyancy settings
	buoyancyForce = 0.5,        -- Multiplier for upward force in water (reduced from 1.8 to prevent bouncing)
	buoyancyDamping = 0.8,      -- Damping to reduce oscillation (changed to velocity-based damping)
	waterDetectionDepth = 1.5,  -- How deep to check for water below float points
	floatHeight = 0.5,          -- Target height above water surface

	-- Physics settings
	enableGravity = true,
	gravityScale = 1.0,

	-- Stabilization (keeps boat upright)
	stabilizationStrength = 0.4,
	maxStabilizationTorque = 2.0,

	-- Float points (corners of boat for buoyancy calculation)
	numFloatPoints = 4,
	floatPointOffset = 0.8,     -- Inset from edges

	-- Player weight - DISABLED per requirements
	ignorePlayerWeight = true,

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

	-- Weld other parts to hull
	for _, part in ipairs(boat:GetDescendants()) do
		if part:IsA("BasePart") and part ~= hull then
			part.Anchored = false
			if part ~= seat then
				part.CanCollide = false
			end

			-- Create weld to hull
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hull
			weld.Part1 = part
			weld.Parent = part
		end
	end

	print("[BoatServer DEBUG] Welded all parts to hull")

	-- Create BodyVelocity for movement
	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	bodyVelocity.Velocity = Vector3.new(0, 0, 0)
	bodyVelocity.P = 10000
	bodyVelocity.Parent = hull

	-- Create BodyGyro for stabilization
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	bodyGyro.P = 5000
	bodyGyro.D = 500
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
	print("BoatServer: Initialized boat with hull:", hull.Name)
	return true
end

-- Physics update loop
local function updateBoatPhysics(deltaTime)
	if not hull or not bodyVelocity or not bodyGyro then
		return
	end

	-- Get hull mass (ignore player weight per requirements)
	local hullMass = hull:GetMass()
	local totalMass = hullMass

	-- Check float points for water contact
	local floatPointsInWater = 0
	local totalBuoyancyVelocity = 0  -- Changed to track velocity change, not force
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
				-- Apply buoyancy as velocity correction based on submersion
				-- The deeper we are, the more upward velocity we want
				local targetUpwardVelocity = submersion * CONFIG.buoyancyForce * 10
				
				-- Get current vertical velocity
				local currentVerticalVelocity = hull.AssemblyLinearVelocity.Y
				
				-- Calculate desired velocity change with damping
				local velocityCorrection = (targetUpwardVelocity - currentVerticalVelocity) * CONFIG.buoyancyDamping
				
				-- Accumulate velocity corrections from all float points
				totalBuoyancyVelocity = totalBuoyancyVelocity + velocityCorrection / CONFIG.numFloatPoints

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

	-- Calculate movement forces
	local forwardVector = hull.CFrame.LookVector
	local rightVector = hull.CFrame.RightVector

	-- Horizontal movement direction
	local forwardHorizontal = Vector3.new(forwardVector.X, 0, forwardVector.Z)
	if forwardHorizontal.Magnitude > 0 then forwardHorizontal = forwardHorizontal.Unit end
	local rightHorizontal = Vector3.new(rightVector.X, 0, rightVector.Z)
	if rightHorizontal.Magnitude > 0 then rightHorizontal = rightHorizontal.Unit end

	-- Target velocity based on input
	local targetVelocity = Vector3.new(0, 0, 0)

	if currentDriver and math.abs(driveThrottle) > 0.01 then
		targetVelocity = forwardHorizontal * driveThrottle * CONFIG.maxSpeed
		-- Debug log movement
		--if math.floor(tick() * 2) % 4 == 0 then
		--	print("[BoatServer DEBUG] Moving boat: throttle =", driveThrottle, "targetVel =", targetVelocity)
		--end
	end

	-- Apply drag based on terrain
	local currentVelocity = hull.AssemblyLinearVelocity
	local dragCoefficient = isInWater and CONFIG.waterDrag or CONFIG.terrainFriction
	local dragForce = -currentVelocity * dragCoefficient * deltaTime

	-- Combine forces
	local totalForce = targetVelocity + dragForce

	-- Apply buoyancy or gravity
	if isInWater then
		-- In water - apply buoyancy velocity correction
		bodyVelocity.MaxForce = Vector3.new(4000, 4000, 4000) * totalMass
		totalForce = totalForce + Vector3.new(0, totalBuoyancyVelocity, 0)
	else
		-- On land - let gravity work, only control horizontal
		bodyVelocity.MaxForce = Vector3.new(4000, 0, 4000) * totalMass
	end

	bodyVelocity.Velocity = totalForce

	-- Handle turning (yaw) - ONLY when driver is present and steering
	local hasDriver = currentDriver ~= nil
	local isSteering = math.abs(driveSteer) > 0.01

	if hasDriver and isSteering then
		-- Only turn when moving
		local speed = currentVelocity.Magnitude
		local turnAmount = driveSteer * CONFIG.turnSpeed * math.max(speed / CONFIG.maxSpeed, 0.2)

		-- Apply rotation
		local currentCFrame = hull.CFrame
		local newCFrame = currentCFrame * CFrame.Angles(0, turnAmount * deltaTime, 0)

		bodyGyro.MaxTorque = Vector3.new(0, 10000, 0) * totalMass
		bodyGyro.CFrame = newCFrame
	elseif hasDriver then
		-- Driver present but not steering - maintain orientation for stabilization only
		bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	else
		-- No driver - completely disable BodyGyro
		bodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	end

	-- Apply stabilization (keep boat upright) - ONLY if in water
	if isInWater then
		local upVector = hull.CFrame.UpVector
		local targetUp = Vector3.new(0, 1, 0)

		-- Calculate tilt
		local tilt = math.acos(math.clamp(upVector:Dot(targetUp), -1, 1))

		if tilt > math.rad(5) then -- Only stabilize if tilted more than 5 degrees
			-- Calculate correction axis
			local correctionAxis = upVector:Cross(targetUp)

			if correctionAxis.Magnitude > 0.001 then
				correctionAxis = correctionAxis.Unit

				-- Apply corrective torque using BodyGyro's existing orientation
				local torqueMagnitude = math.min(tilt * CONFIG.stabilizationStrength, CONFIG.maxStabilizationTorque)

				-- Only apply stabilization if not actively steering or if no driver
				if not (hasDriver and isSteering) then
					-- Calculate target CFrame that keeps current yaw but levels the boat
					local currentYaw = math.atan2(forwardHorizontal.X, forwardHorizontal.Z)
					local targetCFrame = CFrame.new(hull.Position) * CFrame.Angles(0, currentYaw, 0)

					bodyGyro.MaxTorque = Vector3.new(5000, 0, 5000) * totalMass
					bodyGyro.CFrame = targetCFrame
					bodyGyro.P = 3000
					bodyGyro.D = 500
				end
			end
		end
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
		-- Optionally: log attempts to send input when not driver
		--print("[BoatServer DEBUG] Input from non-driver:", player.Name, "currentDriver:", currentDriver and currentDriver.Name or "nil")
		return
	end

	-- Clamp input values
	driveThrottle = math.clamp(throttle or 0, -1, 1)
	driveSteer = math.clamp(steer or 0, -1, 1)

	-- Debug: Log received inputs periodically (optional)
	--if math.abs(driveThrottle) > 0 or math.abs(driveSteer) > 0 then
	--	print("[BoatServer DEBUG] Received input from", player.Name, "throttle:", driveThrottle, "steer:", driveSteer)
	--end
end)

-- Handle client requests to be seated (server-authoritative)
boatRequestSeatEvent.OnServerEvent:Connect(function(player, boatModel)
	-- Basic validation: ensure the request is for this boat model
	if boatModel ~= boat then
		return
	end

	-- Ensure seat exists and isn't occupied
	if not seat then return end
	if seat.Occupant then
		print("[BoatServer DEBUG] Seat already occupied, rejecting request from", player.Name)
		return
	end

	-- Validate distance to boat to reduce abuse
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

	if (hrp.Position - boatPos).Magnitude > 12 then -- allow small buffer beyond MAX_DISTANCE
		print("[BoatServer DEBUG] Rejecting seat request: player too far", player.Name)
		return
	end

	-- Ensure humanoid exists and call seat:Sit on server
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		print("[BoatServer DEBUG] Server seating player:", player.Name)
		-- Seat the player's humanoid on the server so Occupant updates and seat events fire properly
		seat:Sit(humanoid)
		-- Occupant changed signal will set currentDriver and notify client
	else
		print("[BoatServer DEBUG] Can't seat player, no humanoid:", player.Name)
	end
end)

-- Connect to heartbeat
RunService.Heartbeat:Connect(updateBoatPhysics)

print("BoatServer: Boat script loaded successfully")
