# Zephyr Scripting API Reference

Complete reference for the Lua scripting API in Zephyr Engine.

---

## Table of Contents

1. [Overview](#overview)
2. [Entity API](#entity-api)
3. [Transform API](#transform-api)
4. [Input API](#input-api)
5. [Time API](#time-api)
6. [Light API](#light-api)
7. [Particles API](#particles-api)
8. [Physics API](#physics-api)
9. [Math API](#math-api)
10. [Scene API](#scene-api)
11. [Console API](#console-api)
12. [CVar API](#cvar-api)
13. [Key Constants](#key-constants)
14. [Complete Examples](#complete-examples)

---

## Overview

All game scripting APIs are under the `zephyr.*` namespace. Scripts run each frame during Play Mode and have access to the current scene's entities and components.

### Script Lifecycle

```lua
-- Scripts are executed once per frame
-- Use global state carefully (persists between frames)

local initialized = false
local player = nil

if not initialized then
    player = zephyr.entity.find("Player")
    initialized = true
end

-- Per-frame logic
local dt = zephyr.time.delta()
-- ... update logic ...
```

### Error Handling

All API functions fail gracefully - they return `nil` or `0` values rather than crashing. Always check return values:

```lua
local entity = zephyr.entity.find("MayNotExist")
if entity then
    -- Safe to use entity
end
```

---

## Entity API

Namespace: `zephyr.entity`

Manage entity lifecycle and naming.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `create` | `zephyr.entity.create()` | `entity_id` | Create a new empty entity |
| `destroy` | `zephyr.entity.destroy(entity_id)` | `void` | Destroy an entity |
| `exists` | `zephyr.entity.exists(entity_id)` | `boolean` | Check if entity exists |
| `find` | `zephyr.entity.find(name)` | `entity_id` or `nil` | Find entity by name |
| `get_name` | `zephyr.entity.get_name(entity_id)` | `string` or `nil` | Get entity's name |
| `set_name` | `zephyr.entity.set_name(entity_id, name)` | `void` | Set entity's name |

### Examples

```lua
-- Create a named entity
local bullet = zephyr.entity.create()
zephyr.entity.set_name(bullet, "Bullet_001")

-- Find entities by name
local player = zephyr.entity.find("Player")
local enemy = zephyr.entity.find("Enemy")

if player and enemy then
    print("Found both entities!")
end

-- Check existence before use
if zephyr.entity.exists(bullet) then
    -- Entity still alive
end

-- Cleanup
zephyr.entity.destroy(bullet)
```

---

## Transform API

Namespace: `zephyr.transform`

Manipulate entity position, rotation, and scale in 3D space.

### Position Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_position` | `zephyr.transform.get_position(entity)` | `x, y, z` | Get world position |
| `set_position` | `zephyr.transform.set_position(entity, x, y, z)` | `void` | Set world position |
| `translate` | `zephyr.transform.translate(entity, dx, dy, dz)` | `void` | Move relative to current position |

### Rotation Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_rotation` | `zephyr.transform.get_rotation(entity)` | `pitch, yaw, roll` | Get rotation as Euler angles (radians) |
| `set_rotation` | `zephyr.transform.set_rotation(entity, pitch, yaw, roll)` | `void` | Set rotation from Euler angles (radians) |
| `rotate` | `zephyr.transform.rotate(entity, dpitch, dyaw, droll)` | `void` | Rotate by Euler angle deltas (radians) |
| `look_at` | `zephyr.transform.look_at(entity, tx, ty, tz, [preserve_roll])` | `void` | Orient to face target point. Resets roll to 0 unless preserve_roll is true. |

### Scale Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_scale` | `zephyr.transform.get_scale(entity)` | `x, y, z` | Get scale |
| `set_scale` | `zephyr.transform.set_scale(entity, x, y, z)` | `void` | Set scale |

### Direction Vectors

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `forward` | `zephyr.transform.forward(entity)` | `x, y, z` | Get forward direction vector |
| `right` | `zephyr.transform.right(entity)` | `x, y, z` | Get right direction vector |
| `up` | `zephyr.transform.up(entity)` | `x, y, z` | Get up direction vector |

### Examples

```lua
-- Basic movement
local player = zephyr.entity.find("Player")
local speed = 5.0
local dt = zephyr.time.delta()

-- WASD movement
if zephyr.input.is_key_down(Key.W) then
    local fx, fy, fz = zephyr.transform.forward(player)
    zephyr.transform.translate(player, fx * speed * dt, fy * speed * dt, fz * speed * dt)
end

if zephyr.input.is_key_down(Key.S) then
    local fx, fy, fz = zephyr.transform.forward(player)
    zephyr.transform.translate(player, -fx * speed * dt, -fy * speed * dt, -fz * speed * dt)
end

if zephyr.input.is_key_down(Key.A) then
    local rx, ry, rz = zephyr.transform.right(player)
    zephyr.transform.translate(player, -rx * speed * dt, -ry * speed * dt, -rz * speed * dt)
end

if zephyr.input.is_key_down(Key.D) then
    local rx, ry, rz = zephyr.transform.right(player)
    zephyr.transform.translate(player, rx * speed * dt, ry * speed * dt, rz * speed * dt)
end

-- Rotation
local rot_speed = 2.0
if zephyr.input.is_key_down(Key.Q) then
    zephyr.transform.rotate(player, 0, rot_speed * dt, 0)  -- Rotate left (yaw)
end

-- Look at target
local target = zephyr.entity.find("Target")
if target then
    local tx, ty, tz = zephyr.transform.get_position(target)
    zephyr.transform.look_at(player, tx, ty, tz)
end

-- Uniform scale
zephyr.transform.set_scale(player, 2.0, 2.0, 2.0)  -- Double size
```

---

## Input API

Namespace: `zephyr.input`

Query keyboard and mouse input state.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `is_key_down` | `zephyr.input.is_key_down(key)` | `boolean` | Check if key is currently pressed |
| `is_mouse_button_down` | `zephyr.input.is_mouse_button_down(button)` | `boolean` | Check if mouse button is pressed |
| `get_mouse_position` | `zephyr.input.get_mouse_position()` | `x, y` | Get cursor position in pixels |

### Mouse Buttons

| Button | Value |
|--------|-------|
| Left | `0` |
| Right | `1` |
| Middle | `2` |

### Examples

```lua
-- Keyboard input
if zephyr.input.is_key_down(Key.Space) then
    jump()
end

if zephyr.input.is_key_down(Key.LeftShift) then
    sprint()
end

if zephyr.input.is_key_down(Key.Escape) then
    pause_game()
end

-- Mouse input
if zephyr.input.is_mouse_button_down(0) then  -- Left click
    shoot()
end

if zephyr.input.is_mouse_button_down(1) then  -- Right click
    aim_down_sights()
end

-- Mouse position (for aiming, UI, etc.)
local mx, my = zephyr.input.get_mouse_position()
print("Mouse at: " .. mx .. ", " .. my)
```

---

## Time API

Namespace: `zephyr.time`

Access frame timing information.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `delta` | `zephyr.time.delta()` | `seconds` (float) | Time since last frame |
| `elapsed` | `zephyr.time.elapsed()` | `seconds` (float) | Total time since engine start |
| `frame` | `zephyr.time.frame()` | `count` (integer) | Current frame number |

### Examples

```lua
-- Frame-rate independent movement
local velocity = 10.0
local dt = zephyr.time.delta()
zephyr.transform.translate(entity, velocity * dt, 0, 0)

-- Animation using elapsed time (bobbing motion)
local t = zephyr.time.elapsed()
local bob = math.sin(t * 2.0) * 0.5  -- Oscillates between -0.5 and 0.5
local base_y = 0  -- Base y position
zephyr.transform.set_position(entity, 0, base_y + bob, 0)

-- Pulsing effect
local pulse = math.sin(zephyr.time.elapsed() * 3.0) * 0.5 + 0.5  -- 0 to 1

-- Frame counting (useful for debugging)
if zephyr.time.frame() % 60 == 0 then
    print("One second passed (at 60 FPS)")
end

-- Timer pattern
local timer = timer or 0
timer = timer + zephyr.time.delta()
if timer > 2.0 then
    timer = 0
    spawn_enemy()
end
```

---

## Light API

Namespace: `zephyr.light`

Control PointLight components on entities.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_color` | `zephyr.light.get_color(entity)` | `r, g, b` | Get light color (0-1 range) |
| `set_color` | `zephyr.light.set_color(entity, r, g, b)` | `void` | Set light color |
| `get_intensity` | `zephyr.light.get_intensity(entity)` | `float` | Get light intensity |
| `set_intensity` | `zephyr.light.set_intensity(entity, value)` | `void` | Set light intensity |
| `get_range` | `zephyr.light.get_range(entity)` | `float` | Get light range |
| `set_range` | `zephyr.light.set_range(entity, value)` | `void` | Set light range |

### Examples

```lua
local torch = zephyr.entity.find("Torch")

-- Flickering torch effect
local t = zephyr.time.elapsed()
local flicker = 0.8 + math.sin(t * 15) * 0.1 + math.sin(t * 23) * 0.1
zephyr.light.set_intensity(torch, flicker)

-- Color cycling
local r = math.sin(t * 0.5) * 0.5 + 0.5
local g = math.sin(t * 0.7) * 0.5 + 0.5
local b = math.sin(t * 0.3) * 0.5 + 0.5
zephyr.light.set_color(torch, r, g, b)

-- Alarm light
local alarm = zephyr.entity.find("AlarmLight")
local blink = math.floor(zephyr.time.elapsed() * 2) % 2
zephyr.light.set_color(alarm, blink, 0, 0)
zephyr.light.set_intensity(alarm, blink * 5.0)

-- Expanding explosion light
local explosion = zephyr.entity.find("ExplosionLight")
local age = age or 0
age = age + zephyr.time.delta()
local range = age * 10.0  -- Expands over time
local intensity = math.max(0, 5.0 - age * 2.0)  -- Fades out
zephyr.light.set_range(explosion, range)
zephyr.light.set_intensity(explosion, intensity)
```

---

## Particles API

Namespace: `zephyr.particles`

Control ParticleEmitter components.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `set_rate` | `zephyr.particles.set_rate(entity, rate)` | `void` | Set particles per second |
| `set_color` | `zephyr.particles.set_color(entity, r, g, b)` | `void` | Set particle color |
| `set_active` | `zephyr.particles.set_active(entity, active)` | `void` | Enable/disable emitter |

### Examples

```lua
local sparks = zephyr.entity.find("Sparks")
local dust = zephyr.entity.find("Dust")
local fire = zephyr.entity.find("Fire")

-- Activate on collision
function on_hit()
    zephyr.particles.set_active(sparks, true)
    zephyr.particles.set_rate(sparks, 200)
    zephyr.particles.set_color(sparks, 1.0, 0.8, 0.2)  -- Orange sparks
end

-- Speed-based dust
local vx, vy, vz = zephyr.physics.get_velocity(player)
local speed = math.sqrt(vx*vx + vy*vy + vz*vz)
zephyr.particles.set_rate(dust, speed * 10)  -- More dust when moving fast

-- Fire intensity
local fuel = fuel or 100
if fuel > 0 then
    fuel = fuel - zephyr.time.delta()
    zephyr.particles.set_rate(fire, fuel)
    local intensity = fuel / 100
    zephyr.particles.set_color(fire, 1.0, intensity * 0.5, 0)
else
    zephyr.particles.set_active(fire, false)
end
```

---

## Physics API

Namespace: `zephyr.physics`

Interact with RigidBody physics components (Jolt Physics).

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_velocity` | `zephyr.physics.get_velocity(entity)` | `vx, vy, vz` | Get linear velocity |
| `set_velocity` | `zephyr.physics.set_velocity(entity, vx, vy, vz)` | `void` | Set linear velocity |
| `add_force` | `zephyr.physics.add_force(entity, fx, fy, fz)` | `void` | Apply continuous force |
| `add_impulse` | `zephyr.physics.add_impulse(entity, ix, iy, iz)` | `void` | Apply instant impulse |

### Force vs Impulse

- **Force**: Applied continuously, scaled by delta time internally. Use for engines, gravity, wind.
- **Impulse**: Applied instantly, one-time velocity change. Use for jumps, explosions, hits.

### Examples

```lua
local player = zephyr.entity.find("Player")

-- Jump
local on_ground = true  -- Detect via raycast or collision in real implementation
if zephyr.input.is_key_down(Key.Space) and on_ground then
    zephyr.physics.add_impulse(player, 0, 8, 0)  -- Jump up
end

-- Horizontal movement with physics
local move_force = 50.0
if zephyr.input.is_key_down(Key.D) then
    zephyr.physics.add_force(player, move_force, 0, 0)
end
if zephyr.input.is_key_down(Key.A) then
    zephyr.physics.add_force(player, -move_force, 0, 0)
end

-- Speed limit
local vx, vy, vz = zephyr.physics.get_velocity(player)
local max_speed = 10.0
local speed = math.sqrt(vx*vx + vz*vz)
if speed > max_speed then
    local scale = max_speed / speed
    zephyr.physics.set_velocity(player, vx * scale, vy, vz * scale)
end

-- Explosion knockback
function explode(center_x, center_y, center_z, radius, force)
    local entities = get_nearby_entities()  -- You'd implement this
    for _, e in ipairs(entities) do
        local ex, ey, ez = zephyr.transform.get_position(e)
        local dx, dy, dz = ex - center_x, ey - center_y, ez - center_z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if dist < radius and dist > 0.1 then
            local falloff = 1.0 - (dist / radius)
            local nx, ny, nz = dx/dist, dy/dist, dz/dist
            zephyr.physics.add_impulse(e, nx * force * falloff, ny * force * falloff, nz * force * falloff)
        end
    end
end
```

---

## Math API

Namespace: `zephyr.math`

Utility functions for game math.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `vec3` | `zephyr.math.vec3(x, y, z)` | `{x, y, z}` | Create vector table |
| `distance` | `zephyr.math.distance(x1, y1, z1, x2, y2, z2)` | `float` | 3D distance between points |
| `lerp` | `zephyr.math.lerp(a, b, t)` | `float` | Linear interpolation |
| `clamp` | `zephyr.math.clamp(value, min, max)` | `float` | Clamp value to range |
| `normalize` | `zephyr.math.normalize(x, y, z)` | `nx, ny, nz` | Normalize vector |
| `dot` | `zephyr.math.dot(x1, y1, z1, x2, y2, z2)` | `float` | Dot product |
| `cross` | `zephyr.math.cross(x1, y1, z1, x2, y2, z2)` | `x, y, z` | Cross product |

### Examples

```lua
-- Distance check for AI
local px, py, pz = zephyr.transform.get_position(player)
local ex, ey, ez = zephyr.transform.get_position(enemy)
local dist = zephyr.math.distance(px, py, pz, ex, ey, ez)

if dist < 5.0 then
    attack_player()
elseif dist < 20.0 then
    chase_player()
else
    patrol()
end

-- Smooth camera follow
local cam = zephyr.entity.find("Camera")
local target = zephyr.entity.find("Player")

local cx, cy, cz = zephyr.transform.get_position(cam)
local tx, ty, tz = zephyr.transform.get_position(target)

-- Add offset behind and above player
ty = ty + 3.0  -- Above
local fx, fy, fz = zephyr.transform.forward(target)
tx = tx - fx * 5.0
tz = tz - fz * 5.0

-- Smooth interpolation
local t = zephyr.math.clamp(zephyr.time.delta() * 5.0, 0, 1)
local nx = zephyr.math.lerp(cx, tx, t)
local ny = zephyr.math.lerp(cy, ty, t)
local nz = zephyr.math.lerp(cz, tz, t)

zephyr.transform.set_position(cam, nx, ny, nz)
zephyr.transform.look_at(cam, px, py + 1.0, pz)

-- Direction to target
local dx, dy, dz = tx - px, ty - py, tz - pz
local nx, ny, nz = zephyr.math.normalize(dx, dy, dz)
-- nx, ny, nz is now a unit vector pointing from player to target

-- Check if facing target (dot product)
local fx, fy, fz = zephyr.transform.forward(player)
local facing = zephyr.math.dot(fx, fy, fz, nx, ny, nz)
if facing > 0.9 then
    -- Player is facing the target
end
```

---

## Scene API

Namespace: `zephyr.scene`

Access scene information.

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `get_name` | `zephyr.scene.get_name()` | `string` | Get current scene name |

### Examples

```lua
local scene_name = zephyr.scene.get_name()
print("Current scene: " .. scene_name)

-- Scene-specific logic
if scene_name == "Level1" then
    spawn_level1_enemies()
elseif scene_name == "Boss" then
    start_boss_fight()
end
```

---

## Console API

Namespace: `console`

Log messages and execute console commands.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `log` | `console.log(level, message)` | Log a message |
| `execute` | `console.execute(command)` | Execute console command |

### Log Levels

- `"debug"` - Development info
- `"info"` - General information
- `"warn"` - Warnings
- `"error"` - Errors

### Examples

```lua
-- Logging
console.log("info", "Game started")
console.log("debug", "Player position: " .. px .. ", " .. py .. ", " .. pz)
console.log("warn", "Low health!")
console.log("error", "Failed to load asset")

-- Execute commands
console.execute("set r_vsync true")
console.execute("set r_fov 90")
```

---

## CVar API

Namespace: `cvar`

Get/set configuration variables and react to changes.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `cvar.get(name)` | Get CVar value as string |
| `set` | `cvar.set(name, value)` | Set CVar value |
| `on_change` | `cvar.on_change(name, handler_name)` | Register change handler |

### Examples

```lua
-- Get/set CVars
local fov = tonumber(cvar.get("r_fov"))
cvar.set("r_fov", "110")

-- Sensitivity from CVar
local sens = tonumber(cvar.get("m_sensitivity")) or 1.0

-- React to CVar changes
function OnFOVChanged(name, old_value, new_value)
    console.log("info", "FOV changed from " .. old_value .. " to " .. new_value)
    update_camera_fov(tonumber(new_value))
end

cvar.on_change("r_fov", "OnFOVChanged")
```

---

## Key Constants

All keyboard keys are available as `Key.*` constants.

### Letters

`Key.A` through `Key.Z`

### Numbers

`Key.Num0` through `Key.Num9`

### Arrow Keys

| Constant | Key |
|----------|-----|
| `Key.Left` | Left Arrow |
| `Key.Right` | Right Arrow |
| `Key.Up` | Up Arrow |
| `Key.Down` | Down Arrow |

### Special Keys

| Constant | Key |
|----------|-----|
| `Key.Space` | Spacebar |
| `Key.Escape` | Escape |
| `Key.Enter` | Enter/Return |
| `Key.Tab` | Tab |
| `Key.Backspace` | Backspace |
| `Key.LeftShift` | Left Shift |
| `Key.RightShift` | Right Shift |
| `Key.LeftControl` | Left Control |
| `Key.RightControl` | Right Control |
| `Key.LeftAlt` | Left Alt |
| `Key.RightAlt` | Right Alt |

---

## Complete Examples

### Player Controller

```lua
-- player_controller.lua
-- Attach to an entity with Transform and RigidBody

local player = zephyr.entity.find("Player")
if not player then return end

local move_speed = 50.0
local jump_force = 8.0
local look_speed = 2.0

local dt = zephyr.time.delta()

-- Movement (physics-based)
local fx, fy, fz = zephyr.transform.forward(player)
local rx, ry, rz = zephyr.transform.right(player)

if zephyr.input.is_key_down(Key.W) then
    zephyr.physics.add_force(player, fx * move_speed, 0, fz * move_speed)
end
if zephyr.input.is_key_down(Key.S) then
    zephyr.physics.add_force(player, -fx * move_speed, 0, -fz * move_speed)
end
if zephyr.input.is_key_down(Key.A) then
    zephyr.physics.add_force(player, -rx * move_speed, 0, -rz * move_speed)
end
if zephyr.input.is_key_down(Key.D) then
    zephyr.physics.add_force(player, rx * move_speed, 0, rz * move_speed)
end

-- Rotation
if zephyr.input.is_key_down(Key.Q) then
    zephyr.transform.rotate(player, 0, look_speed * dt, 0)
end
if zephyr.input.is_key_down(Key.E) then
    zephyr.transform.rotate(player, 0, -look_speed * dt, 0)
end

-- Jump
if zephyr.input.is_key_down(Key.Space) then
    local vx, vy, vz = zephyr.physics.get_velocity(player)
    if math.abs(vy) < 0.1 then  -- Simple ground check
        zephyr.physics.add_impulse(player, 0, jump_force, 0)
    end
end

-- Speed limit
local vx, vy, vz = zephyr.physics.get_velocity(player)
local max_speed = 10.0
local hspeed = math.sqrt(vx*vx + vz*vz)
if hspeed > max_speed then
    local scale = max_speed / hspeed
    zephyr.physics.set_velocity(player, vx * scale, vy, vz * scale)
end
```

### Camera Follow System

```lua
-- camera_follow.lua
-- Smooth third-person camera

local camera = zephyr.entity.find("Camera")
local target = zephyr.entity.find("Player")
if not camera or not target then return end

local offset_back = 8.0
local offset_up = 4.0
local smoothness = 5.0

local dt = zephyr.time.delta()
local t = zephyr.math.clamp(dt * smoothness, 0, 1)

-- Get target position and direction
local tx, ty, tz = zephyr.transform.get_position(target)
local fx, fy, fz = zephyr.transform.forward(target)

-- Calculate desired camera position
local desired_x = tx - fx * offset_back
local desired_y = ty + offset_up
local desired_z = tz - fz * offset_back

-- Get current camera position
local cx, cy, cz = zephyr.transform.get_position(camera)

-- Smooth interpolation
local new_x = zephyr.math.lerp(cx, desired_x, t)
local new_y = zephyr.math.lerp(cy, desired_y, t)
local new_z = zephyr.math.lerp(cz, desired_z, t)

zephyr.transform.set_position(camera, new_x, new_y, new_z)
zephyr.transform.look_at(camera, tx, ty + 1.5, tz)
```

### Day/Night Cycle

```lua
-- day_night_cycle.lua
-- Cycle sun light color and intensity

local sun = zephyr.entity.find("Sun")
if not sun then return end

local cycle_duration = 120.0  -- 2 minutes per day
local t = (zephyr.time.elapsed() % cycle_duration) / cycle_duration

-- 0.0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset
local sun_angle = t * 2 * math.pi

-- Intensity (0 at night, 1 at noon)
local intensity = math.max(0, math.sin(sun_angle))
zephyr.light.set_intensity(sun, intensity * 2.0)

-- Color (orange at sunrise/sunset, white at noon)
local warmth = 1.0 - math.abs(t - 0.5) * 2  -- 0 at noon, 1 at sunrise/sunset
local r = 1.0
local g = 1.0 - warmth * 0.3
local b = 1.0 - warmth * 0.5
zephyr.light.set_color(sun, r, g, b)

-- Range (simulate sun distance)
zephyr.light.set_range(sun, 50 + intensity * 50)
```

### Collectible Pickup

```lua
-- collectible.lua
-- Spin and check for player collision

local collectibles = {"Coin1", "Coin2", "Coin3", "Gem1"}
local player = zephyr.entity.find("Player")
if not player then return end

local px, py, pz = zephyr.transform.get_position(player)
local pickup_range = 1.5
local spin_speed = 3.0
local bob_speed = 2.0
local bob_height = 0.3
local dt = zephyr.time.delta()
local t = zephyr.time.elapsed()

for _, name in ipairs(collectibles) do
    local coin = zephyr.entity.find(name)
    if coin and zephyr.entity.exists(coin) then
        -- Spin animation
        zephyr.transform.rotate(coin, 0, spin_speed * dt, 0)
        
        -- Bob animation
        local cx, cy, cz = zephyr.transform.get_position(coin)
        local bob = math.sin(t * bob_speed) * bob_height * dt
        zephyr.transform.translate(coin, 0, bob, 0)
        
        -- Pickup check
        local dist = zephyr.math.distance(px, py, pz, cx, cy, cz)
        if dist < pickup_range then
            -- Collected!
            console.log("info", "Picked up " .. name)
            zephyr.entity.destroy(coin)
            -- Add score, play sound, etc.
        end
    end
end
```

---

## See Also

- [SCRIPTING_QUICK_REF.md](SCRIPTING_QUICK_REF.md) - Quick reference card
- [SCRIPTING_SYSTEM.md](SCRIPTING_SYSTEM.md) - Architecture and internals
- [CVAR_QUICK_REF.md](CVAR_QUICK_REF.md) - CVar system reference

---

**Last Updated**: November 26, 2025
