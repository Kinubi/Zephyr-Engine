-- Avoider Game - Dodge falling obstacles!
-- Uses init() + prepare(dt) lifecycle pattern

-- =============================================================================
-- Game Constants
-- =============================================================================

-- Player settings
local PLAYER_START_X = 0
local PLAYER_START_Y = -3
local PLAYER_SPEED = 8
local PLAYER_BOUND_LEFT = -5
local PLAYER_BOUND_RIGHT = 5

-- Obstacle settings
local MAX_OBSTACLES = 5
local OBSTACLE_SPAWN_Y = 8
local OBSTACLE_DESPAWN_Y = -6
local OBSTACLE_HIDDEN_Y = -100
local OBSTACLE_SPAWN_X_MIN = -5
local OBSTACLE_SPAWN_X_MAX = 5
local OBSTACLE_SPEED_MIN = 3
local OBSTACLE_SPEED_MAX = 5

-- Collision settings
local COLLISION_SIZE = 1.0

-- Spawn timing
local SPAWN_INTERVAL = 1.5

-- =============================================================================
-- Game State
-- =============================================================================

-- Game state (persistent across frames)
local game = {
    initialized = false,
    player_x = PLAYER_START_X,
    player_y = PLAYER_START_Y,
    score = 0,
    game_over = false,
    spawn_timer = 0,
}

-- Obstacle pool - each entry tracks: entity_id, active, x, y, speed
local obstacles = {}

-- Initialize game (called once when script loads)
function init()
    -- Find all obstacle entities
    for i = 1, MAX_OBSTACLES do
        local entity = zephyr.entity.find("Obstacle" .. i)
        if entity then
            obstacles[i] = {
                entity = entity,
                active = false,
                x = 0,
                y = OBSTACLE_HIDDEN_Y,
                speed = 0
            }
        end
    end
    
    game.initialized = true
    game.player_x = PLAYER_START_X
    game.player_y = PLAYER_START_Y
    game.score = 0
    game.game_over = false
    game.spawn_timer = 0
end

-- Reset game
local function reset_game()
    game.player_x = PLAYER_START_X
    game.player_y = PLAYER_START_Y
    game.score = 0
    game.game_over = false
    game.spawn_timer = 0
    
    -- Hide all obstacles
    for i = 1, MAX_OBSTACLES do
        if obstacles[i] then
            obstacles[i].active = false
            obstacles[i].y = OBSTACLE_HIDDEN_Y
            zephyr.transform.set_position(obstacles[i].entity, 0, OBSTACLE_HIDDEN_Y, 0)
        end
    end
end

-- Update player movement based on input
local function update_player(dt)
    local move_speed = PLAYER_SPEED * dt
    
    if zephyr.input.is_key_down(Key.A) or zephyr.input.is_key_down(Key.Left) then
        game.player_x = game.player_x - move_speed
    end
    
    if zephyr.input.is_key_down(Key.D) or zephyr.input.is_key_down(Key.Right) then
        game.player_x = game.player_x + move_speed
    end
    
    -- Clamp player to screen bounds
    if game.player_x < PLAYER_BOUND_LEFT then game.player_x = PLAYER_BOUND_LEFT end
    if game.player_x > PLAYER_BOUND_RIGHT then game.player_x = PLAYER_BOUND_RIGHT end
    
    -- Reset game with R
    if zephyr.input.is_key_down(Key.R) then
        reset_game()
    end
end

-- Find an inactive obstacle from the pool
local function get_inactive_obstacle()
    for i = 1, MAX_OBSTACLES do
        if obstacles[i] and not obstacles[i].active then
            return obstacles[i]
        end
    end
    return nil
end

-- Spawn a new obstacle
local function spawn_obstacle()
    local obs = get_inactive_obstacle()
    if obs then
        obs.active = true
        local spawn_range = OBSTACLE_SPAWN_X_MAX - OBSTACLE_SPAWN_X_MIN
        obs.x = math.random() * spawn_range + OBSTACLE_SPAWN_X_MIN
        obs.y = OBSTACLE_SPAWN_Y
        local speed_range = OBSTACLE_SPEED_MAX - OBSTACLE_SPEED_MIN
        obs.speed = OBSTACLE_SPEED_MIN + math.random() * speed_range
        zephyr.transform.set_position(obs.entity, obs.x, obs.y, 0)
    end
end

-- Update obstacles
local function update_obstacles(dt)
    game.spawn_timer = game.spawn_timer + dt
    
    if game.spawn_timer >= SPAWN_INTERVAL then
        spawn_obstacle()
        game.spawn_timer = 0
        game.score = game.score + 1
    end
    
    for i = 1, MAX_OBSTACLES do
        local obs = obstacles[i]
        if obs and obs.active then
            obs.y = obs.y - obs.speed * dt
            zephyr.transform.set_position(obs.entity, obs.x, obs.y, 0)
            
            if obs.y < OBSTACLE_DESPAWN_Y then
                obs.active = false
                obs.y = OBSTACLE_HIDDEN_Y
                zephyr.transform.set_position(obs.entity, 0, OBSTACLE_HIDDEN_Y, 0)
            else
                local dx = math.abs(obs.x - game.player_x)
                local dy = math.abs(obs.y - game.player_y)
                if dx < COLLISION_SIZE and dy < COLLISION_SIZE then
                    game.game_over = true
                end
            end
        end
    end
end

-- Main update (called every frame with delta time)
function prepare(dt)
    if game.game_over then
        if zephyr.input.is_key_down(Key.R) then
            reset_game()
        end
        return
    end
    
    update_player(dt)
    update_obstacles(dt)
    
    local player = zephyr.entity.find("Player")
    if player then
        zephyr.transform.set_position(player, game.player_x, game.player_y, 0)
    end
end
