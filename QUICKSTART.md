# Quick Start Guide

## Files Created

This update provides a complete boat physics system with three new files:

1. **BoatServer.lua** - Server-side physics script
2. **BoatClient.lua** - Client-side interaction script  
3. **BoatSetup.md** - Detailed setup instructions

## Quick Setup (5 minutes)

### 1. Install the Client Script
- Open Roblox Studio
- Go to: **StarterPlayer → StarterPlayerScripts**
- Create a new **LocalScript** named "BoatClient"
- Copy the contents of `BoatClient.lua` into this script

### 2. Create Your Boat Model
In Workspace, create this structure:
```
Workspace
└── Boats (Folder) ← Create this folder
    └── RowBoat (Model) ← Your boat
        ├── Hull (Part) ← Size: 5.593, 2.472, 12.828
        ├── DriverSeat (Seat or VehicleSeat)
        └── BoatServer (Script) ← Copy BoatServer.lua here
```

### 3. Configure the Hull Part
- Select the Hull part
- Set properties:
  - `Anchored`: **false** ⚠️ Important!
  - `CanCollide`: **true**
  - `CustomPhysicalProperties`: Density = 0.3
- Set the Hull as **PrimaryPart** of the boat Model

### 4. Add the Server Script
- Insert a **Script** (not LocalScript) into the boat Model
- Name it "BoatServer"
- Copy the contents of `BoatServer.lua` into this script

### 5. Add Terrain Water
- Use the Terrain Editor to paint water where boats should float
- Make sure water terrain exists at boat's location

### 6. Test!
- Press Play in Studio
- Approach the boat (you'll see "[E] Board Boat" prompt)
- Press **E** to board
- Drive with **W/A/S/D** or Arrow keys
- Press **Space** or click the seat to exit

## How It Works

### Boarding
1. Player approaches boat (within 10 studs)
2. Billboard prompt appears when looking at boat
3. Press **E** to board
4. Player sits in DriverSeat automatically

### Driving
- **W/Up**: Forward
- **S/Down**: Backward  
- **A/Left**: Turn left
- **D/Right**: Turn right
- **Space**: Exit boat

### Physics
- **In Water**: Boat floats naturally, drives smoothly
- **On Land**: Boat can be driven but is much slower (friction)
- **Falling**: If boat goes off cliff into water, it falls and splashes naturally
- **Player Weight**: Boat does NOT react to player weight (as requested)

## Troubleshooting

**Boat doesn't float?**
- Make sure Hull is **unanchored**
- Check that water terrain exists below boat
- Verify BoatServer script is running (check Output for "BoatServer: Initialized")

**Can't board boat?**
- Ensure boat is in **Workspace/Boats** folder
- Make sure BoatClient script is in StarterPlayerScripts
- Check that boat has a DriverSeat

**Boat is too bouncy?**
- Edit `CONFIG.buoyancyDamping` in BoatServer.lua (increase to 60-80)

**Boat tips over?**
- Edit `CONFIG.stabilizationStrength` in BoatServer.lua (increase to 0.6-0.8)

## Advanced Configuration

Open `BoatServer.lua` and find the `CONFIG` table (around line 13):

```lua
-- Movement settings
maxSpeed = 25,              -- Adjust boat speed
turnSpeed = 1.2,            -- Adjust turn rate
terrainFriction = 10,       -- Adjust land slowdown

-- Buoyancy settings  
buoyancyForce = 1.8,        -- Adjust float strength
buoyancyDamping = 45,       -- Adjust bounce reduction

-- Debug
showDebugPoints = true,     -- Shows colored float points
```

## Need More Help?

See **BoatSetup.md** for:
- Detailed setup instructions
- Multiple boat setup
- Custom boat sizes
- Advanced physics tuning
- Complete troubleshooting guide

## What's Different From Old Scripts

### Old Scripts (BoatScript.lua, CustomBoat.lua)
- Complex configuration
- Manual setup required
- No interaction system

### New System
- ✅ Simple E key interaction
- ✅ Billboard GUI prompts (like loot/workstations)
- ✅ Auto-creates RemoteEvents
- ✅ Cleaner code organization
- ✅ Better documentation
- ✅ Easier to configure

The old scripts are kept for reference but are replaced by this new system.
