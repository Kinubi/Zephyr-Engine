-- =============================================================================
-- ZEPHYR AVOIDER - A Simple Demo Game
-- =============================================================================
-- Control the player cube to avoid falling obstacles!
-- 
-- Controls:
--   A/D or Left/Right - Move left/right
--   Space - Jump (when on ground)
--   R - Reset game
--
-- Setup Required:
--   1. Create entity named "Player" with Transform, RigidBody
--   2. Create entity named "GameLight" with PointLight
--   3. Create entities named "Obstacle1", "Obstacle2", "Obstacle3" with Transform
--   4. Create entity named "ScoreText" (optional, for UI)
-- =============================================================================

-- ============== GAME STATE ==============
game = game or {
    initialized = false,
    score = 0,
    high_score = 0,
    game_over = false,
    spawn_timer = 0,
    difficulty = 1.0,
    obstacle_pool = {},
    player_start_y = 0,
}

-- ============== CONFIGURATION ==============
local CONFIG = {
    move_speed = 40.0,       -- Horizontal movement force
    jump_force = 12.0,       -- Jump impulse
    max_speed = 15.0,        -- Max horizontal velocity
    spawn_interval = 2.0,    -- Base time between obstacles
    obstacle_speed = 8.0,    -- How fast obstacles fall
    play_area_width = 10.0,  -- Half-width of play area
    obstacle_reset_y = -5.0, -- Y position to reset obstacles
    obstacle_spawn_y = 20.0, -- Y position to spawn obstacles
    hit_range = 1.5,         -- Collision detection range
}

-- ============== INITIALIZATION ==============
local function init_game()
    local player = zephyr.entity.find("Player")
    if not player then
        console.log("error", "Avoider: Player entity not found!")
        return false
    end
    
    -- Store starting position
    local px, py, pz = zephyr.transform.get_position(player)
    game.player_start_y = py
    
    -- Find obstacle pool
    game.obstacle_pool = {}
    for i = 1, 10 do
        local obs = zephyr.entity.find("Obstacle" .. i)
        if obs then
            table.insert(game.obstacle_pool, {
                entity = obs,
                active = false,
                vx = 0,
                vy = 0,
            })
            -- Hide initially
            zephyr.transform.set_position(obs, 0, -100, 0)
        end
    end
    
    if #game.obstacle_pool == 0 then
        console.log("warn", "Avoider: No obstacles found (need Obstacle1, Obstacle2, etc.)")
    end
    
    game.initialized = true
    game.score = 0
    game.game_over = false
    game.spawn_timer = 0
    game.difficulty = 1.0
    
    console.log("info", "=== ZEPHYR AVOIDER ===")
    console.log("info", "A/D to move, Space to jump!")
    console.log("info", "Avoid the falling obstacles!")
    
    return true
end

-- ============== PLAYER MOVEMENT ==============
local function update_player(dt)
    local player = zephyr.entity.find("Player")
    if not player then return end
    
    -- Horizontal movement
    local move = 0
    if zephyr.input.is_key_down(Key.A) or zephyr.input.is_key_down(Key.Left) then
        move = move - 1
    end
    if zephyr.input.is_key_down(Key.D) or zephyr.input.is_key_down(Key.Right) then
        move = move + 1
    end
    
    if move ~= 0 then
        zephyr.physics.add_force(player, move * CONFIG.move_speed, 0, 0)
    end
    
    -- Speed limit
    local vx, vy, vz = zephyr.physics.get_velocity(player)
    if math.abs(vx) > CONFIG.max_speed then
        local clamped = CONFIG.max_speed * (vx > 0 and 1 or -1)
        zephyr.physics.set_velocity(player, clamped, vy, vz)
    end
    
    -- Jumping (simple ground check)
    local px, py, pz = zephyr.transform.get_position(player)
    local on_ground = py <= game.player_start_y + 0.1 and vy <= 0.1
    
    if zephyr.input.is_key_down(Key.Space) and on_ground then
        zephyr.physics.add_impulse(player, 0, CONFIG.jump_force, 0)
    end
    
    -- Keep in bounds
    if px < -CONFIG.play_area_width then
        zephyr.transform.set_position(player, -CONFIG.play_area_width, py, pz)
        zephyr.physics.set_velocity(player, 0, vy, vz)
    elseif px > CONFIG.play_area_width then
        zephyr.transform.set_position(player, CONFIG.play_area_width, py, pz)
        zephyr.physics.set_velocity(player, 0, vy, vz)
    end
end

-- ============== OBSTACLE SPAWNING ==============
local function spawn_obstacle()
    -- Find inactive obstacle
    for _, obs in ipairs(game.obstacle_pool) do
        if not obs.active then
            -- Activate at random X position
            local x = (math.random() * 2 - 1) * CONFIG.play_area_width
            zephyr.transform.set_position(obs.entity, x, CONFIG.obstacle_spawn_y, 0)
            obs.active = true
            obs.vy = -CONFIG.obstacle_speed * game.difficulty
            -- Random slight horizontal drift
            obs.vx = (math.random() * 2 - 1) * 2
            return true
        end
    end
    return false
end

local function update_obstacles(dt)
    local player = zephyr.entity.find("Player")
    local px, py, pz = 0, 0, 0
    if player then
        px, py, pz = zephyr.transform.get_position(player)
    end
    
    for _, obs in ipairs(game.obstacle_pool) do
        if obs.active then
            local ox, oy, oz = zephyr.transform.get_position(obs.entity)
            
            -- Move obstacle
            local new_x = ox + obs.vx * dt
            local new_y = oy + obs.vy * dt
            zephyr.transform.set_position(obs.entity, new_x, new_y, oz)
            
            -- Spin for visual flair
            zephyr.transform.rotate(obs.entity, 0.5, 1, 0.3, dt * 3)
            
            -- Check for collision with player
            if player and not game.game_over then
                local dist = zephyr.math.distance(px, py, pz, new_x, new_y, oz)
                if dist < CONFIG.hit_range then
                    trigger_game_over()
                end
            end
            
            -- Reset if below screen
            if new_y < CONFIG.obstacle_reset_y then
                obs.active = false
                zephyr.transform.set_position(obs.entity, 0, -100, 0)
                
                -- Score point for dodging
                if not game.game_over then
                    game.score = game.score + 10
                    game.difficulty = game.difficulty + 0.02
                end
            end
        end
    end
end

-- ============== GAME OVER ==============
local function trigger_game_over()
    game.game_over = true
    
    if game.score > game.high_score then
        game.high_score = game.score
        console.log("info", "NEW HIGH SCORE: " .. game.score)
    end
    
    console.log("warn", "GAME OVER! Score: " .. game.score)
    console.log("info", "Press R to restart")
    
    -- Flash the light red
    local light = zephyr.entity.find("GameLight")
    if light then
        zephyr.light.set_color(light, 1, 0, 0)
        zephyr.light.set_intensity(light, 5.0)
    end
end

local function reset_game()
    -- Reset player
    local player = zephyr.entity.find("Player")
    if player then
        zephyr.transform.set_position(player, 0, game.player_start_y, 0)
        zephyr.physics.set_velocity(player, 0, 0, 0)
    end
    
    -- Reset all obstacles
    for _, obs in ipairs(game.obstacle_pool) do
        obs.active = false
        zephyr.transform.set_position(obs.entity, 0, -100, 0)
    end
    
    -- Reset state
    game.score = 0
    game.difficulty = 1.0
    game.game_over = false
    game.spawn_timer = 0
    
    -- Reset light
    local light = zephyr.entity.find("GameLight")
    if light then
        zephyr.light.set_color(light, 1, 1, 1)
        zephyr.light.set_intensity(light, 2.0)
    end
    
    console.log("info", "Game reset! GO!")
end

-- ============== VISUAL EFFECTS ==============
local function update_visuals(dt)
    local light = zephyr.entity.find("GameLight")
    if not light then return end
    
    if game.game_over then
        -- Pulsing red on game over
        local pulse = math.sin(zephyr.time.elapsed() * 5) * 0.3 + 0.7
        zephyr.light.set_intensity(light, pulse * 5)
    else
        -- Normal gameplay - intensity based on score/difficulty
        local intensity = 1.5 + game.difficulty * 0.5
        zephyr.light.set_intensity(light, intensity)
        
        -- Slight color shift based on difficulty
        local danger = math.min(game.difficulty / 3.0, 1.0)
        zephyr.light.set_color(light, 1, 1 - danger * 0.3, 1 - danger * 0.5)
    end
end

-- ============== MAIN UPDATE LOOP ==============
local dt = zephyr.time.delta()

-- Initialize on first run
if not game.initialized then
    if not init_game() then
        return  -- Can't run without player
    end
end

-- Reset check
if zephyr.input.is_key_down(Key.R) then
    -- Simple debounce using frame count
    local frame = zephyr.time.frame()
    if not game.last_reset_frame or frame - game.last_reset_frame > 30 then
        game.last_reset_frame = frame
        reset_game()
    end
end

-- Main game logic
if not game.game_over then
    update_player(dt)
    
    -- Spawn timer
    game.spawn_timer = game.spawn_timer + dt
    local spawn_rate = CONFIG.spawn_interval / game.difficulty
    if game.spawn_timer >= spawn_rate then
        game.spawn_timer = 0
        spawn_obstacle()
    end
end

update_obstacles(dt)
update_visuals(dt)

-- HUD (print score periodically)
if zephyr.time.frame() % 120 == 0 and not game.game_over then
    console.log("debug", "Score: " .. game.score .. " | Difficulty: " .. string.format("%.1f", game.difficulty))
end
