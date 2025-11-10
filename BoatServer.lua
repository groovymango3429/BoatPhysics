-- BoatServer.lua
-- Server-side script for boat validation and seat management
-- Place this script inside the boat model in Workspace
-- Physics now handled client-side for better performance

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local boat = script.Parent
assert(boat and boat:IsA("Model"), "Script must be placed inside the boat model")

-- Minimal server configuration - most physics moved to client
local CONFIG = {
	-- Debug
	showDebugPoints = true,
}

-- State variables
local hull = nil
local seat = nil
local currentDriver = nil

-- RemoteEvent for client communication (create if missing)
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

	-- Set network owner to driver when they board (client-side physics)
	-- This is now handled when player boards

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
	print("BoatServer: Initialized boat with hull:", hull.Name)
	return true
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
				
				-- Set network owner to player for client-side physics
				if hull then
					hull:SetNetworkOwner(player)
					print("[BoatServer DEBUG] Set network owner to player for client-side physics")
				end
				
				-- Notify that player is seated. Send boat model so client knows which boat it is.
				boatSeatedEvent:FireClient(player, true, boat)
			end
		else
			-- occupant became nil
			local prevDriver = currentDriver
			print("[BoatServer DEBUG] Player left seat, previous driver was:", prevDriver and prevDriver.Name or "nil")
			
			-- Return network owner to server
			if hull then
				hull:SetNetworkOwner(nil)
				print("[BoatServer DEBUG] Reset network owner to server")
			end
			
			if prevDriver then
				boatSeatedEvent:FireClient(prevDriver, false)
			end
			currentDriver = nil
		end
	end)
end

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

print("BoatServer: Boat script loaded successfully (client-side physics mode)")
