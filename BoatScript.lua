-- CustomBoat.server.lua
-- Combined fixes:
-- - Buoyancy with distributed float points and smoothing
-- - Standing-on-stern mass compensation so players standing at the rear don't sink the boat
-- - Beached "fall off" behavior that activates while driver is seated and reversing
-- - Reentry stabilization to prevent springy oscillation when hull re-enters water
-- - Debug printing and debug float-point parts
-- Tweak config values below to tune behavior for your map/boat.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local boatModel = script.Parent
assert(boatModel and boatModel:IsA("Model"), "Script parent must be the Boat Model")

-- user-visible config (tweak)
local config = {
	-- movement
	maxSpeed = 20,
	accel = 2,
	turnSpeed = 1.6,
	driveDrag = 3.0,

	-- buoyancy (global values split across float points)
	buoyancySpring = 12,
	buoyancyDamp = 50,
	perPointClamp = 20000,
	buoyancyStrength = 1.5,
	floatPointDepth = 2.0,
	useModelBounds = true,

	-- Transition smoothing
	transitionSmoothness = 0.5,

	-- water detection
	minFloatPointsInWater = 1,
	waterDetectionMargin = 2,

	-- Gravity and terrain handling
	enableGravity = true,
	gravityMultiplier = 1.0,
	terrainFriction = 8,
	minWaterDepthForFloat = 0.05,

	-- Beached pushing settings
	enableBeachedPushing = true,
	pushForce = 8,
	pushBurstDuration = 0.6,
	pushCooldown = 0.4,
	pushFriction = 15,
	maxPushSpeed = 4,
	pushTurnSpeed = 0.3,

	-- Auto-return to water settings
	enableAutoReturnToWater = false,
	returnToWaterForce = 15,
	beachedStabilizationMultiplier = 3,
	slopeSlideForce = 10,
	waterSearchRadius = 50,
	minBeachedTime = 0.5,

	-- water sampling / terrain
	waterLevelValue = boatModel:FindFirstChild("WaterLevel"),
	terrainSampleHeight = 20,

	-- stabilization (pitch/roll damping via AngularVelocity targets)
	angDampingGain = 0.6,
	beachedDampingGain = 0.8,
	maxStabilAng = 1.5,

	-- Active uprighting
	enableActiveUprighting = true,
	uprightingGain = 0.15,
	maxTiltAngle = 30,
	uprightingDamping = 0.85,

	-- actuator tuning
	forceFactor = 300,
	torqueFactor = 100,

	-- idle settings
	idle = {
		forceFactor = 300,
		torqueFactor = 100,
		buoyancySpring = 10,
		buoyancyDamp = 40,
		angDampingGain = 0.6,
		dragMultiplier = 6,
	},

	-- buoyancy layout
	numFloatPoints = 4,
	debug = true,
	debugWaterDetection = true,

	-- helper
	autoWeld = true,
	autoDisableInternalCollisions = true,

	-- Standing compensation
	compensateStandingWeight = true,
	standingDetectRadius = 10,
	standingVerticalMin = -1,
	standingVerticalMax = 4,

	-- Beached fall tuning & reentry stabilization
	beachedFall = {
		enabled = true,
		torqueScale = 0.08,         -- fraction of normal torque to allow physics to dominate
		dampingReduction = 0.25,    -- multiply damping by this when falling
		uprightingReduction = 0.25, -- reduce uprighting while falling
		backwardSpeedThreshold = -0.6, -- desiredSpeed threshold to consider reversing
		reentryDuration = 0.6,        -- seconds to stabilize after first contact
		reentrySpringScale = 0.6,     -- reduce spring during reentry
		reentryDampScale = 1.6,       -- increase damping during reentry
		reentryForceBlend = 0.35,     -- blend previousForces on reentry to reduce overshoot
	},

	-- debug flags
	debugBeachedFall = true,
	debugReentry = true,
}

-- runtime state
local hull = nil
local attachment = nil
local linearVel = nil
local angularVel = nil
local floatPoints = {} -- { {att=..., vf=..., dbg=...}, ... }

local driverSeat = nil

-- Beached tracking
local beachedStartTime = nil
local isBeached = false

-- Push burst tracking
local lastPushTime = 0
local currentPushBurstEnd = 0
local isPushing = false

-- Debug tracking
local lastDebugPrint = 0
local debugPrintInterval = 2 -- print every 2 seconds

-- Track previous forces for smoothing
local previousForces = {}

-- Track previous uprighting correction for damping
local previousUprightingX = 0
local previousUprightingZ = 0

-- Beached-fall and reentry state
local reentryActive = false
local reentryEndTime = 0
local prevPointsInWater = 0

-- Optional vertical override while forcing fall
local currentVelYOverride = nil

-- RemoteEvent
local eventName = "BoatInput"
local boatEvent = ReplicatedStorage:FindFirstChild(eventName)
if not boatEvent then
	boatEvent = Instance.new("RemoteEvent")
	boatEvent.Name = eventName
	boatEvent.Parent = ReplicatedStorage
end

-- Helper: destroy existing actuators/floatpoints
local function cleanupActuators()
	if linearVel and linearVel.Parent then linearVel:Destroy() end
	if angularVel and angularVel.Parent then angularVel:Destroy() end
	if attachment and attachment.Parent then attachment:Destroy() end
	for _, entry in ipairs(floatPoints) do
		if entry.vf and entry.vf.Parent then entry.vf:Destroy() end
		if entry.att and entry.att.Parent then entry.att:Destroy() end
		if entry.dbg and entry.dbg.Parent then entry.dbg:Destroy() end
	end
	floatPoints = {}
	linearVel = nil
	angularVel = nil
	attachment = nil
	previousForces = {}
	previousUprightingX = 0
	previousUprightingZ = 0
	prevPointsInWater = 0
	reentryActive = false
	reentryEndTime = 0
	currentVelYOverride = nil
end

-- Helper: ensure parts are unanchored and optionally weld them to new hull
local function ensureAssemblyForHull(newHull)
	for _, part in ipairs(boatModel:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.Anchored then
				pcall(function() part.Anchored = false end)
			end
			if config.autoDisableInternalCollisions and part ~= newHull then
				pcall(function() part.CanCollide = false end)
			end
			if config.autoWeld and part ~= newHull then
				local found = false
				for _, c in ipairs(part:GetChildren()) do
					if c:IsA("WeldConstraint") then
						if c.Part0 == newHull or c.Part1 == newHull then
							found = true
							break
						end
					end
				end
				if not found then
					local weld = Instance.new("WeldConstraint")
					weld.Name = "AutoWeldToHull"
					weld.Part0 = newHull
					weld.Part1 = part
					weld.Parent = part
				end
			end
		end
	end
end

-- Get the bounding box of the entire boat model
local function getModelBounds()
	local minPos = Vector3.new(math.huge, math.huge, math.huge)
	local maxPos = Vector3.new(-math.huge, -math.huge, -math.huge)

	for _, part in ipairs(boatModel:GetDescendants()) do
		if part:IsA("BasePart") then
			local cf = part.CFrame
			local size = part.Size
			local corners = {
				cf * CFrame.new( size.X/2,  size.Y/2,  size.Z/2),
				cf * CFrame.new( size.X/2,  size.Y/2, -size.Z/2),
				cf * CFrame.new( size.X/2, -size.Y/2,  size.Z/2),
				cf * CFrame.new( size.X/2, -size.Y/2, -size.Z/2),
				cf * CFrame.new(-size.X/2,  size.Y/2,  size.Z/2),
				cf * CFrame.new(-size.X/2,  size.Y/2, -size.Z/2),
				cf * CFrame.new(-size.X/2, -size.Y/2,  size.Z/2),
				cf * CFrame.new(-size.X/2, -size.Y/2, -size.Z/2),
			}
			for _, corner in ipairs(corners) do
				local pos = corner.Position
				minPos = Vector3.new(
					math.min(minPos.X, pos.X),
					math.min(minPos.Y, pos.Y),
					math.min(minPos.Z, pos.Z)
				)
				maxPos = Vector3.new(
					math.max(maxPos.X, pos.X),
					math.max(maxPos.Y, pos.Y),
					math.max(maxPos.Z, pos.Z)
				)
			end
		end
	end

	local center = (minPos + maxPos) / 2
	local size = maxPos - minPos
	return center, size, minPos, maxPos
end

-- Helper: find mass of characters standing on stern (near stern float point)
local function getStandingOnSternMass()
	if not hull or #floatPoints == 0 then return 0 end
	if not config.compensateStandingWeight then return 0 end

	local sternPos = floatPoints[2] and floatPoints[2].att and floatPoints[2].att.WorldPosition or hull.Position
	local total = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char then
			local hrp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
			if hrp then
				local horizontalDist = Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(sternPos.X, 0, sternPos.Z)
				if horizontalDist.Magnitude <= config.standingDetectRadius then
					local verticalDiff = hrp.Position.Y - hull.Position.Y
					if verticalDiff >= config.standingVerticalMin and verticalDiff <= config.standingVerticalMax then
						for _, p in ipairs(char:GetDescendants()) do
							if p:IsA("BasePart") then
								pcall(function() total = total + p:GetMass() end)
							end
						end
					end
				end
			end
		end
	end
	return total
end

-- Helper: create actuators & float points on new hull
local function createActuatorsAndFloatPoints(newHull)
	attachment = Instance.new("Attachment")
	attachment.Name = "BoatRootAttachment"
	attachment.Parent = newHull
	attachment.Position = Vector3.new(0,0,0)

	linearVel = Instance.new("LinearVelocity")
	linearVel.Name = "BoatLinearVelocity"
	linearVel.Attachment0 = attachment
	linearVel.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVel.MaxForce = 0
	linearVel.Parent = newHull

	angularVel = Instance.new("AngularVelocity")
	angularVel.Name = "BoatAngularVelocity"
	angularVel.Attachment0 = attachment
	angularVel.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	angularVel.MaxTorque = 0
	angularVel.Parent = newHull

	local forwardOffset, sideOffset, heightOffset
	if config.useModelBounds then
		local modelCenter, modelSize, minPos, maxPos = getModelBounds()
		local hullCF = newHull.CFrame
		local minLocal = hullCF:PointToObjectSpace(minPos)
		local maxLocal = hullCF:PointToObjectSpace(maxPos)
		forwardOffset = math.max(math.abs(maxLocal.Z), math.abs(minLocal.Z)) - 0.4
		sideOffset = math.max(math.abs(maxLocal.X), math.abs(minLocal.X)) - 0.4
		heightOffset = math.min(minLocal.Y, maxLocal.Y) - config.floatPointDepth
	else
		local hx, hy, hz = newHull.Size.X, newHull.Size.Y, newHull.Size.Z
		forwardOffset = math.max((hz / 2) - 0.4, 0.6)
		sideOffset = math.max((hx / 2) - 0.4, 0.6)
		heightOffset = - (hy / 2) - config.floatPointDepth
	end

	local offsets = {
		Vector3.new( 0, heightOffset, -forwardOffset), -- bow/front
		Vector3.new( 0, heightOffset,  forwardOffset), -- stern/rear
		Vector3.new(-sideOffset, heightOffset,  0),    -- port/left
		Vector3.new( sideOffset, heightOffset,  0),    -- starboard/right
	}

	for i, offset in ipairs(offsets) do
		local att = Instance.new("Attachment")
		att.Name = "BuoyAtt"..i
		att.Parent = newHull
		att.Position = offset

		local vf = Instance.new("VectorForce")
		vf.Name = "BuoyVF"..i
		vf.Attachment0 = att
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.Parent = newHull

		local dbg = nil
		if config.debug then
			dbg = Instance.new("Part")
			dbg.Name = "BuoyDbg"..i
			dbg.Anchored = true
			dbg.CanCollide = false
			dbg.Size = Vector3.new(0.3, 0.3, 0.3)
			dbg.Transparency = 0.25
			dbg.Color = Color3.fromRGB(0, 150, 255)
			dbg.Parent = newHull

			local billboard = Instance.new("BillboardGui")
			billboard.Size = UDim2.new(0, 50, 0, 20)
			billboard.Adornee = dbg
			billboard.AlwaysOnTop = true
			billboard.Parent = dbg

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, 0, 1, 0)
			label.BackgroundTransparency = 1
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextStrokeTransparency = 0.5
			label.Text = ({"Front", "Back", "Left", "Right"})[i]
			label.TextScaled = true
			label.Parent = billboard
		end

		table.insert(floatPoints, {att = att, vf = vf, dbg = dbg})
		previousForces[i] = 0
	end
end

-- Helper: set the hull (PrimaryPart) and reinit everything
local function setHull(newHull)
	if newHull == hull then return end
	cleanupActuators()
	hull = newHull
	if not hull then
		warn("CustomBoat: PrimaryPart is nil; waiting for PrimaryPart to be set")
		return
	end
	pcall(function() hull.Anchored = false end)
	pcall(function() hull:SetNetworkOwner(nil) end)
	driverSeat = boatModel:FindFirstChild("DriverSeat")
	ensureAssemblyForHull(hull)
	createActuatorsAndFloatPoints(hull)
	print("CustomBoat: Initialized on PrimaryPart:", hull:GetFullName())
end

boatModel:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
	local pp = boatModel.PrimaryPart
	if pp then setHull(pp) end
end)

if boatModel.PrimaryPart then
	setHull(boatModel.PrimaryPart)
else
	warn("CustomBoat: Model.PrimaryPart is not set. Set PrimaryPart to your hull part for the boat to initialize.")
end

-- Get water info at a specific point using voxel reading
local function getWaterInfoAtPoint(worldPos)
	local searchSize = Vector3.new(2, 2, 2)
	local region = Region3.new(worldPos - searchSize/2, worldPos + searchSize/2)
	region = region:ExpandToGrid(4)

	local success, materials, sizes = pcall(function()
		return Workspace.Terrain:ReadVoxels(region, 4)
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

-- Find nearest water location within search radius
local function findNearestWater(fromPosition, searchRadius)
	local bestWaterPos = nil
	local bestDistance = math.huge
	local sampleStep = 8
	local samples = math.floor(searchRadius / sampleStep)

	for x = -samples, samples do
		for z = -samples, samples do
			local samplePos = fromPosition + Vector3.new(x * sampleStep, 0, z * sampleStep)
			local hasWater, waterY = getWaterInfoAtPoint(samplePos)
			if hasWater and waterY then
				local waterPos = Vector3.new(samplePos.X, waterY, samplePos.Z)
				local distance = (waterPos - fromPosition).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestWaterPos = waterPos
				end
			end
		end
	end

	return bestWaterPos, bestDistance
end

-- Calculate terrain slope/normal at a position
local function getTerrainNormal(position)
	local sampleDist = 2
	local center = position
	local function getHeight(pos)
		local hasWater, waterY = getWaterInfoAtPoint(pos)
		if hasWater and waterY then return waterY end
		local ray = Ray.new(pos + Vector3.new(0, 10, 0), Vector3.new(0, -30, 0))
		local hit, hitPos = Workspace:FindPartOnRay(ray, boatModel)
		if hit and hit == Workspace.Terrain then return hitPos.Y end
		return position.Y
	end

	local hCenter = getHeight(center)
	local hNorth = getHeight(center + Vector3.new(0, 0, -sampleDist))
	local hSouth = getHeight(center + Vector3.new(0, 0, sampleDist))
	local hEast = getHeight(center + Vector3.new(sampleDist, 0, 0))
	local hWest = getHeight(center + Vector3.new(-sampleDist, 0, 0))

	local dx = hEast - hWest
	local dz = hSouth - hNorth

	local normal = Vector3.new(-dx, sampleDist * 2, -dz).Unit
	return normal
end

-- Helper: compute occupants mass
local function getOccupantsMass()
	local occMass = 0
	for _, desc in ipairs(boatModel:GetDescendants()) do
		if desc:IsA("Seat") and desc.Occupant then
			local humanoid = desc.Occupant
			local char = humanoid.Parent
			if char then
				for _, p in ipairs(char:GetDescendants()) do
					if p:IsA("BasePart") then
						pcall(function() occMass = occMass + p:GetMass() end)
					end
				end
			end
		end
	end
	return occMass
end

-- Input handling (secure)
local desiredSpeed = 0
local desiredTurnRate = 0
local currentSpeedTarget = 0
local currentDriver = nil

local function isPlayerDriver(player)
	if not driverSeat then return false end
	local occ = driverSeat.Occupant
	if not occ then return false end
	local character = player and player.Character
	if not character then return false end
	return occ:IsDescendantOf(character)
end

boatEvent.OnServerEvent:Connect(function(player, throttle, steer)
	if not isPlayerDriver(player) then return end
	throttle = math.clamp(tonumber(throttle) or 0, -1, 1)
	steer = math.clamp(tonumber(steer) or 0, -1, 1)

	-- Handle beached pushing with burst mechanic
	if isBeached and config.enableBeachedPushing then
		local currentTime = tick()
		if math.abs(throttle) > 0.1 then
			if currentTime >= lastPushTime + config.pushCooldown then
				lastPushTime = currentTime
				currentPushBurstEnd = currentTime + config.pushBurstDuration
				isPushing = true
			end
		end

		if isPushing and currentTime <= currentPushBurstEnd then
			desiredSpeed = throttle * config.maxPushSpeed
			local speedFrac = math.abs(desiredSpeed) / math.max(config.maxPushSpeed, 1)
			desiredTurnRate = steer * config.pushTurnSpeed * math.max(0.12, speedFrac)
		else
			isPushing = false
			desiredSpeed = 0
			desiredTurnRate = 0
		end
	else
		desiredSpeed = throttle * config.maxSpeed
		local speedFrac = math.abs(desiredSpeed) / math.max(config.maxSpeed, 1)
		desiredTurnRate = steer * config.turnSpeed * math.max(0.12, speedFrac)
		isPushing = false
	end
end)

-- Track driver seat occupant
if boatModel:FindFirstChild("DriverSeat") then
	boatModel.DriverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = boatModel.DriverSeat.Occupant
		if occ then
			local humanoid = occ.Parent:FindFirstChildOfClass("Humanoid")
			if humanoid then
				currentDriver = Players:GetPlayerFromCharacter(humanoid.Parent)
			end
		else
			currentDriver = nil
			desiredSpeed = 0
			desiredTurnRate = 0
			isPushing = false
		end
	end)
end

-- Buoyancy with smooth force transition + reentry adjustments
local function applyDistributedBuoyancy(dt, activeMode, totalMass)
	if not hull or #floatPoints == 0 then return 0, {}, 0 end

	local floatCount = #floatPoints

	-- Use reentry-adjusted spring/damp when reentryActive
	local spring = activeMode and config.buoyancySpring or config.idle.buoyancySpring
	local damp   = activeMode and config.buoyancyDamp or config.idle.buoyancyDamp
	if reentryActive then
		spring = spring * config.beachedFall.reentrySpringScale
		damp = damp * config.beachedFall.reentryDampScale
	end

	local springPerPoint = spring / floatCount
	local dampPerPoint = damp / floatCount
	local gravityPerPoint = (totalMass * Workspace.Gravity * config.gravityMultiplier) / floatCount

	local perPointClampDynamic = math.max(config.perPointClamp, gravityPerPoint * 5)

	local velY = hull.AssemblyLinearVelocity.Y
	local pointsInWater = 0
	local debugInfo = {}
	local avgWaterLevel = 0
	local waterLevelCount = 0

	for i, entry in ipairs(floatPoints) do
		local att = entry.att
		local vf = entry.vf
		local pointWorldPos = att.WorldPosition

		local hasWaterNearby, waterLevelY = getWaterInfoAtPoint(pointWorldPos)

		local submersion = 0
		if waterLevelY then
			submersion = waterLevelY - pointWorldPos.Y
			avgWaterLevel = avgWaterLevel + waterLevelY
			waterLevelCount = waterLevelCount + 1
		end

		local isNearWater = hasWaterNearby and (submersion > -config.waterDetectionMargin)
		if isNearWater then pointsInWater = pointsInWater + 1 end

		debugInfo[i] = {
			position = pointWorldPos,
			waterY = waterLevelY or 0,
			pointY = pointWorldPos.Y,
			submersion = submersion,
			hasWater = hasWaterNearby,
			nearWater = isNearWater
		}

		local targetForceY = 0
		if hasWaterNearby and waterLevelY and submersion > config.minWaterDepthForFloat then
			local springForce = (submersion * springPerPoint * config.buoyancyStrength) - (velY * dampPerPoint)
			targetForceY = springForce + gravityPerPoint
			targetForceY = math.clamp(targetForceY, -perPointClampDynamic, perPointClampDynamic)
		else
			targetForceY = 0
		end

		local previousForce = previousForces[i] or 0
		local smoothedForce = previousForce + (targetForceY - previousForce) * config.transitionSmoothness
		previousForces[i] = smoothedForce

		vf.Force = Vector3.new(0, smoothedForce, 0)

		if config.debug and entry.dbg then
			entry.dbg.CFrame = CFrame.new(pointWorldPos)
			if submersion > config.minWaterDepthForFloat then
				local depthFactor = math.clamp(submersion / 2, 0, 1)
				entry.dbg.Color = Color3.fromRGB(0, 150 + 105 * depthFactor, 255)
				entry.dbg.Transparency = 0.25
			elseif isNearWater then
				entry.dbg.Color = Color3.fromRGB(0, 150, 255)
				entry.dbg.Transparency = 0.4
			elseif isBeached then
				entry.dbg.Color = Color3.fromRGB(255, 165, 0)
				entry.dbg.Transparency = 0.25
			else
				entry.dbg.Color = Color3.fromRGB(255, 50, 50)
				entry.dbg.Transparency = 0.25
			end
		end
	end

	if waterLevelCount > 0 then avgWaterLevel = avgWaterLevel / waterLevelCount end
	return pointsInWater, debugInfo, avgWaterLevel
end

-- Apply forces to return boat to water when beached (unchanged)
local function applyReturnToWaterForces(totalMass)
	if not hull then return Vector3.new(0, 0, 0) end
	local hullPos = hull.Position
	local nearestWater, waterDistance = findNearestWater(hullPos, config.waterSearchRadius)
	if not nearestWater then
		local terrainNormal = getTerrainNormal(hullPos)
		local slopeDirection = Vector3.new(terrainNormal.X, 0, terrainNormal.Z)
		if slopeDirection.Magnitude > 0.01 then
			return slopeDirection.Unit * config.slopeSlideForce * totalMass
		end
		return Vector3.new(0, 0, 0)
	end

	local toWater = nearestWater - hullPos
	local toWaterHorizontal = Vector3.new(toWater.X, 0, toWater.Z)
	if toWaterHorizontal.Magnitude < 1 then return Vector3.new(0, 0, 0) end
	local directionToWater = toWaterHorizontal.Unit
	local terrainNormal = getTerrainNormal(hullPos)
	local slopeDirection = Vector3.new(terrainNormal.X, 0, terrainNormal.Z)
	local combinedDirection = (directionToWater * 0.7 + slopeDirection * 0.3)
	if combinedDirection.Magnitude > 0.01 then combinedDirection = combinedDirection.Unit else combinedDirection = directionToWater end
	local forceMagnitude = config.returnToWaterForce * totalMass
	local distanceFactor = math.min(1, waterDistance / 10)
	return combinedDirection * forceMagnitude * distanceFactor
end

-- Heartbeat: apply drive, stabilization and buoyancy (main)
RunService.Heartbeat:Connect(function(dt)
	if not dt or dt <= 0 then return end
	if not hull or not linearVel or not angularVel then return end

	local hullMass = 1
	pcall(function() hullMass = math.max(0.001, hull:GetMass()) end)
	local occMass = getOccupantsMass()
	local standingMass = getStandingOnSternMass()
	local totalMass = hullMass + occMass + standingMass

	local active = currentDriver ~= nil

	-- compute intended actuator limits and allow beached-fall to reduce torque BEFORE assignment
	local intendedMaxForce = totalMass * (active and config.forceFactor or config.idle.forceFactor)
	local intendedMaxTorque = totalMass * (active and config.torqueFactor or config.idle.torqueFactor)

	-- Determine if driver is intentionally reversing (use desiredSpeed so it triggers when holding reverse)
	local isMovingBackward = active and (desiredSpeed <= config.beachedFall.backwardSpeedThreshold)

	local applyFallMode = false

	-- assign linear force capacity
	linearVel.MaxForce = intendedMaxForce

	-- Check how many float points are in water and apply buoyancy
	local pointsInWater, debugInfo, avgWaterLevel = applyDistributedBuoyancy(dt, active, totalMass)
	local isInWater = pointsInWater >= config.minFloatPointsInWater

	-- Track beached state
	local currentTime = tick()
	if not isInWater then
		if not beachedStartTime then beachedStartTime = currentTime end
		local beachedDuration = currentTime - beachedStartTime
		isBeached = beachedDuration >= config.minBeachedTime
	else
		beachedStartTime = nil
		isBeached = false
		isPushing = false
	end

	-- Decide whether to enable beached-fall mode (beached + reversing)
	if isBeached and isMovingBackward and config.beachedFall.enabled then
		applyFallMode = true
		intendedMaxTorque = intendedMaxTorque * config.beachedFall.torqueScale
	end

	-- assign angular torque
	angularVel.MaxTorque = intendedMaxTorque

	-- Debug logs (periodic)
	if config.debugWaterDetection and currentTime - lastDebugPrint >= debugPrintInterval then
		lastDebugPrint = currentTime
		local rollAngle = math.deg(math.asin(math.clamp(hull.CFrame.RightVector.Y, -1, 1)))
		local pitchAngle = math.deg(math.asin(math.clamp(-hull.CFrame.LookVector.Y, -1, 1)))
		print("========== BOAT WATER DEBUG ==========")
		print("Hull Position:", hull.Position)
		print("Hull Velocity:", hull.AssemblyLinearVelocity)
		print("Hull Angular Velocity:", hull.AssemblyAngularVelocity)
		print("Hull Mass:", hullMass, "Occupant Mass:", occMass, "StandingMass:", standingMass, "Total:", totalMass)
		print("Roll Angle:", string.format("%.1f°", rollAngle), "Pitch Angle:", string.format("%.1f°", pitchAngle))
		print("Average Water Level Y:", avgWaterLevel)
		print("Points in Water:", pointsInWater, "/", #floatPoints)
		print("Is In Water:", isInWater)
		print("Is Beached:", isBeached)
		print("Is Pushing:", isPushing)
		print("BeachedFallActive:", tostring(applyFallMode))
		print("ReentryActive:", tostring(reentryActive))
		print("\nFloat Point Details:")
		for i, info in ipairs(debugInfo) do
			print(string.format("  Point %d: Y=%.2f, WaterY=%.2f, Sub=%.2f, HasWater=%s, NearWater=%s, PrevForce=%.2f",
				i, info.pointY, info.waterY, info.submersion, tostring(info.hasWater), tostring(info.nearWater), previousForces[i] or 0))
		end
		print("======================================")
	end

	-- FALL MODE: if we're beached and the player is reversing, force a drop
	if applyFallMode then
		-- aggressively reduce any lingering per-point buoyancy so it won't hold elevation
		for i = 1, #previousForces do
			previousForces[i] = (previousForces[i] or 0) * 0.12 -- rapid bleed while falling
		end

		-- Give a downward velocity nudge so hull begins to fall
		local fallVel = -math.max(6, Workspace.Gravity * 0.9) -- tuneable
		currentVelYOverride = fallVel

		if config.debugBeachedFall then
			print(string.format("[CustomBoat] Fall mode active: forcing downward velocity %.2f", fallVel))
		end
	else
		currentVelYOverride = nil
	end

	-- Detect reentry (first frame where we went from zero water contact to some contact) while in fall mode
	if prevPointsInWater <= 0 and pointsInWater > 0 and applyFallMode then
		reentryActive = true
		reentryEndTime = tick() + config.beachedFall.reentryDuration
		-- Immediately damp previousForces to reduce initial overshoot
		for i = 1, #previousForces do
			previousForces[i] = (previousForces[i] or 0) * config.beachedFall.reentryForceBlend
		end
		if config.debugReentry then
			print(string.format("[CustomBoat] Reentry stabilization activated for %.2fs", config.beachedFall.reentryDuration))
		end
	end

	-- Turn off reentry when time passes
	if reentryActive and tick() >= reentryEndTime then
		reentryActive = false
		if config.debugReentry then
			print("[CustomBoat] Reentry stabilization ended")
		end
	end

	prevPointsInWater = pointsInWater

	-- Smooth speed (water driving or pushing)
	local canDrive = isInWater and active
	local canPush = isBeached and active and isPushing and config.enableBeachedPushing
	local accel = active and config.accel or (config.accel * 0.6)
	local maxDelta = accel * dt * (canDrive and config.maxSpeed or config.maxPushSpeed)

	if canDrive or canPush then
		currentSpeedTarget = currentSpeedTarget + math.clamp(desiredSpeed - currentSpeedTarget, -maxDelta, maxDelta)
	else
		currentSpeedTarget = currentSpeedTarget * 0.85
		if math.abs(currentSpeedTarget) < 0.1 then currentSpeedTarget = 0 end
	end

	-- horizontal forward
	local look = hull.CFrame.LookVector
	local forwardHorizontal = Vector3.new(look.X, 0, look.Z)
	if forwardHorizontal.Magnitude < 0.01 then
		forwardHorizontal = Vector3.new(hull.CFrame.RightVector.X, 0, hull.CFrame.RightVector.Z)
	end
	forwardHorizontal = forwardHorizontal.Unit

	local velocityTargetWorld = forwardHorizontal * currentSpeedTarget
	local currentVel = hull.AssemblyLinearVelocity

	-- Different drag for pushing vs driving vs terrain
	local dragFactor
	if canPush then
		dragFactor = config.pushFriction
	elseif not isInWater and not active then
		dragFactor = config.terrainFriction
	elseif active then
		dragFactor = config.driveDrag
	else
		dragFactor = config.driveDrag * config.idle.dragMultiplier
	end

	local dragComp = -currentVel * (dragFactor * dt)
	velocityTargetWorld = velocityTargetWorld + dragComp

	-- If we set a vertical override for falling, apply it here
	if currentVelYOverride then
		velocityTargetWorld = Vector3.new(velocityTargetWorld.X, currentVelYOverride, velocityTargetWorld.Z)
	end

	if isBeached and config.enableAutoReturnToWater and not active and not isPushing then
		local returnForce = applyReturnToWaterForces(totalMass)
		local returnVelocity = returnForce / totalMass * dt
		velocityTargetWorld = velocityTargetWorld + returnVelocity
	end

	linearVel.VectorVelocity = velocityTargetWorld

	-- yaw and pitch/roll damping and uprighting
	local sign = (currentSpeedTarget >= 0) and 1 or -1
	local yawRate = (canDrive or canPush) and (desiredTurnRate * sign) or 0

	local worldAngVel = hull.AssemblyAngularVelocity
	local localAngVel = hull.CFrame:VectorToObjectSpace(worldAngVel)

	local dampingGain = active and config.angDampingGain or config.idle.angDampingGain
	if isBeached then dampingGain = math.max(dampingGain, config.beachedDampingGain) end
	if applyFallMode then dampingGain = dampingGain * config.beachedFall.dampingReduction end

	local localX = -localAngVel.X * dampingGain
	local localZ = -localAngVel.Z * dampingGain

	if config.enableActiveUprighting then
		local upVector = hull.CFrame.UpVector
		local targetUp = Vector3.new(0, 1, 0)
		local tiltDot = upVector:Dot(targetUp)
		local tiltAngle = math.acos(math.clamp(tiltDot, -1, 1))
		local rotationAxis = upVector:Cross(targetUp)
		if rotationAxis.Magnitude > 0.001 then
			rotationAxis = rotationAxis.Unit
			local localRotAxis = hull.CFrame:VectorToObjectSpace(rotationAxis)
			local uprightGain = config.uprightingGain
			if applyFallMode then uprightGain = uprightGain * config.beachedFall.uprightingReduction end
			if math.deg(tiltAngle) > config.maxTiltAngle then uprightGain = uprightGain * 1.3 end

			local correctionX = localRotAxis.X * tiltAngle * uprightGain
			local correctionZ = localRotAxis.Z * tiltAngle * uprightGain

			correctionX = previousUprightingX + (correctionX - previousUprightingX) * config.uprightingDamping
			correctionZ = previousUprightingZ + (correctionZ - previousUprightingZ) * config.uprightingDamping

			previousUprightingX = correctionX
			previousUprightingZ = correctionZ

			localX = localX + correctionX
			localZ = localZ + correctionZ
		end
	end

	localX = math.clamp(localX, -config.maxStabilAng, config.maxStabilAng)
	localZ = math.clamp(localZ, -config.maxStabilAng, config.maxStabilAng)
	angularVel.AngularVelocity = Vector3.new(localX, yawRate, localZ)
end)