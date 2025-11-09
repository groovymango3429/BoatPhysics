-- CustomBoat.client.lua
-- Place this LocalScript in StarterPlayer -> StarterPlayerScripts
-- Sends throttle and steer to the server RemoteEvent (BoatInput).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local eventName = "BoatInput"
local boatEvent = ReplicatedStorage:WaitForChild(eventName)

-- Input state
local throttle = 0     -- forward/back [-1,1]
local steer = 0        -- left/right [-1,1]

-- Key mapping
local throttleUpKeys = {
	Enum.KeyCode.W, Enum.KeyCode.Up
}
local throttleDownKeys = {
	Enum.KeyCode.S, Enum.KeyCode.Down
}
local steerLeftKeys = {
	Enum.KeyCode.A, Enum.KeyCode.Left
}
local steerRightKeys = {
	Enum.KeyCode.D, Enum.KeyCode.Right
}

local keysDown = {}

local function updateFromKeys()
	-- throttle: W/Up => +1, S/Down => -1
	local up = keysDown[Enum.KeyCode.W] or keysDown[Enum.KeyCode.Up]
	local down = keysDown[Enum.KeyCode.S] or keysDown[Enum.KeyCode.Down]
	if up and not down then
		throttle = 1
	elseif down and not up then
		throttle = -1
	else
		throttle = 0
	end

	-- steer: A/Left => -1, D/Right => +1
	local left = keysDown[Enum.KeyCode.A] or keysDown[Enum.KeyCode.Left]
	local right = keysDown[Enum.KeyCode.D] or keysDown[Enum.KeyCode.Right]
	if left and not right then
		steer = 1
	elseif right and not left then
		steer = -1
	else
		steer = 0
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = true
		updateFromKeys()
	end
end)

UserInputService.InputEnded:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
		updateFromKeys()
	end
end)

-- Also support Gamepad thumbsticks (optional)
UserInputService.InputChanged:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local v = input.Position -- Vector2
			-- y -> throttle, x -> steer
			-- push threshold
			local deadzone = 0.15
			throttle = math.abs(v.Y) > deadzone and -v.Y or 0 -- note: many controllers have Y inverted
			steer = math.abs(v.X) > deadzone and v.X or 0
		end
	end
end)

-- Throttle smoothing and send loop
local sendInterval = 1/20 -- 20 times per second

RunService.Heartbeat:Connect(function(dt)
	-- send the current inputs to the server
	-- we don't need to spam identical values too frequently; still okay at 20Hz.
	boatEvent:FireServer(throttle, steer)
	wait(sendInterval)
end)