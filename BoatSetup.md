# Boat Setup Guide

This guide explains how to set up the boat physics system in your Roblox game.

## Required Model Structure

Your boat model should have the following structure:

```
BoatModel (Model)
├── Hull (Part) - The main boat body [Set as PrimaryPart]
├── DriverSeat (Seat or VehicleSeat) - Where the player sits
├── BoatServer (Script) - The server-side physics script
└── [Other decorative parts]
```

## Boat Model Setup

### 1. Create the Boat Model

1. Create a new Model in Workspace
2. Name it something like "RowBoat" or "Boat"
3. Move it to a folder called "Boats" in Workspace (required for detection)

### 2. Set Up the Hull Part

1. Create a Part named "Hull" inside the boat model
2. Set the size to approximately: `5.593, 2.472, 12.828` (or adjust to your boat size)
3. Set the Hull as the PrimaryPart of the model:
   - Select the boat Model
   - In Properties, set `PrimaryPart` to the Hull part
4. Configure Hull properties:
   - `Anchored`: false
   - `CanCollide`: true
   - `Material`: Wood (or your preference)
   - `Color`: Brown/appropriate boat color
   - `CustomPhysicalProperties`: 
     - Density: 0.3 (makes it float better)
     - Friction: 0.5
     - Elasticity: 0.1

### 3. Add the Driver Seat

1. Insert a Seat or VehicleSeat into the boat model
2. Name it "DriverSeat"
3. Position it where you want the player to sit
4. Configure Seat properties:
   - `Anchored`: false
   - `CanCollide`: true
   - Make sure it's positioned above the Hull

### 4. Add the Server Script

1. Insert a Script (not LocalScript) into the boat model
2. Name it "BoatServer"
3. Copy the contents of `BoatServer.lua` into this script
4. The script will automatically initialize when the boat loads

### 5. Add Decorative Parts (Optional)

You can add additional parts for seats, railings, oars, etc:
- Make sure all parts have `Anchored`: false
- These parts will be automatically welded to the Hull
- Set `CanCollide`: false for decorative parts to prevent physics issues

## Workspace Setup

### 1. Create Boats Folder

```
Workspace
└── Boats (Folder)
    ├── RowBoat1 (Model)
    ├── RowBoat2 (Model)
    └── etc...
```

The client script looks for boats in `Workspace.Boats`.

### 2. Terrain Water

Make sure you have Terrain water in your game:
1. Open the Terrain Editor
2. Select the "Add" tool
3. Choose "Water" material
4. Paint water where you want boats to float
5. The boat will automatically detect water using voxel reading

## ReplicatedStorage Setup

### Create Required RemoteEvents

The boat system uses two RemoteEvents that will be created automatically by the server script, but you can create them manually if needed:

```
ReplicatedStorage
└── BoatInput (RemoteEvent) - Sends driving input from client to server
└── BoatSeated (RemoteEvent) - Notifies client when player boards/leaves boat
```

These are created automatically by the server script if they don't exist.

## Client Script Installation

1. Go to StarterPlayer → StarterPlayerScripts
2. Insert a LocalScript
3. Name it "BoatClient"
4. Copy the contents of `BoatClient.lua` into this script

## Configuration

You can adjust boat behavior by modifying the `CONFIG` table in `BoatServer.lua`:

### Movement Settings
```lua
maxSpeed = 25,              -- Maximum speed (studs/second)
acceleration = 3,           -- How fast boat accelerates
turnSpeed = 1.2,            -- How fast boat turns
waterDrag = 2.5,            -- Drag force in water
terrainFriction = 10,       -- Friction on land (slows boat)
```

### Buoyancy Settings
```lua
buoyancyForce = 1.8,        -- Upward force multiplier
buoyancyDamping = 45,       -- Reduces bounce/oscillation
waterDetectionDepth = 1.5,  -- How deep to check for water
floatHeight = 0.5,          -- Target height above water
```

### Physics Settings
```lua
stabilizationStrength = 0.4, -- How strongly boat resists tipping
maxStabilizationTorque = 2.0, -- Maximum corrective rotation
```

### Debug Settings
```lua
showDebugPoints = true,      -- Shows colored spheres at float points
                             -- Green = in water, Orange = on land
```

## How It Works

### Boarding the Boat
1. Player approaches boat (within 10 studs)
2. Look at the boat
3. Press **E** to board
4. Player sits in the DriverSeat

### Driving the Boat
- **W** or **Up Arrow**: Move forward
- **S** or **Down Arrow**: Move backward
- **A** or **Left Arrow**: Turn left
- **D** or **Right Arrow**: Turn right
- **Space** or click the seat again: Exit boat

### Physics Behavior

#### In Water
- Boat floats on top of water terrain
- Four float points (corners) check water level
- Buoyancy forces keep boat at target height
- Can drive smoothly with W/A/S/D controls
- Auto-stabilizes to stay upright

#### On Land
- Boat can be driven onto land/beach
- Movement is much slower due to terrain friction
- Physics still applies (boat can roll down hills)
- Can drive back into water

#### Falling from Height
- If boat goes off a cliff or elevated beach into water
- Gravity pulls it down naturally
- Boat splashes into water and then floats
- Basic physics applied realistically

### Player Weight
The boat **does not react to player weight** as per requirements. The physics calculations ignore player mass for buoyancy.

## Troubleshooting

### Boat doesn't float
- Check that there is Terrain water below the boat
- Verify the Hull is unanchored
- Check that PrimaryPart is set to the Hull
- Increase `buoyancyForce` in CONFIG if needed

### Can't board the boat
- Verify boat is in `Workspace.Boats` folder
- Check that DriverSeat exists and is named correctly
- Make sure BoatClient script is in StarterPlayerScripts

### Boat is too bouncy
- Increase `buoyancyDamping` value (try 60-80)
- Decrease `buoyancyForce` slightly
- Adjust `floatHeight` to a lower value

### Boat tips over too easily
- Increase `stabilizationStrength` (try 0.6-0.8)
- Increase `maxStabilizationTorque` (try 3.0-4.0)
- Make sure Hull has proper CustomPhysicalProperties

### Boat moves too slow on land
- Decrease `terrainFriction` value (try 6-8)
- Keep it high enough that there's noticeable slowdown

### Boat falls through water
- Check water terrain exists at that location
- Verify `waterDetectionDepth` is set appropriately
- Check that float points are positioned correctly (debug mode)

## Advanced Customization

### Multiple Boats
You can have multiple boats in the Boats folder. Each boat needs:
- Its own BoatServer script
- Unique name
- Proper Hull and DriverSeat

### Different Boat Sizes
Adjust the float point positions in the script based on your boat size:
```lua
floatPointOffset = 0.8,  -- Distance from edges
```

For larger boats, increase this value. For smaller boats, decrease it.

### Custom Controls
Modify the key bindings in `BoatClient.lua`:
```lua
local INTERACTION_KEY = Enum.KeyCode.E  -- Change boarding key
```

## Summary Checklist

- [ ] Boat Model in Workspace/Boats folder
- [ ] Hull part set as PrimaryPart (unanchored)
- [ ] DriverSeat added to boat
- [ ] BoatServer script in boat model
- [ ] BoatClient script in StarterPlayerScripts
- [ ] Terrain water painted in world
- [ ] RemoteEvents in ReplicatedStorage (auto-created)
- [ ] Test by approaching boat and pressing E
- [ ] Test driving with W/A/S/D
- [ ] Test driving onto land (should slow down)
- [ ] Test falling from height into water

Enjoy your realistic boat physics!
