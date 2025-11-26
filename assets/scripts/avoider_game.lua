-- Avoider Game - Dodge falling obstacles!
-- Uses init() + prepare(dt) lifecycle pattern

-- Game state (persistent across frames)
local game = {
    initialized = false,
    player_x = 0,
    player_y = -3,
    player_speed = 8,
    score = 0,
    game_over = false,
    spawn_timer = 0,
    spawn_interval = 1.5,
}

-- Obstacle pool - each entry tracks: entity_id, active, x, y, speed
local obstacles = {}
local MAX_OBSTACLES = 5

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
                y = -100,
                speed = 0
            }
        end
    end
    
    game.initialized = true
    game.player_x = 0
    game.player_y = -3
    game.score = 0
    game.game_over = false
    game.spawn_timer = 0
end

-- Reset game
local function reset_game()
    game.player_x = 0
    game.player_y = -3
    game.score = 0
    game.game_over = false
    game.spawn_timer = 0
    
    -- Hide all obstacles
    for i = 1, MAX_OBSTACLES do
        if obstacles[i] then
            obstacles[i].active = false
            obstacles[i].y = -100
            zephyr.transform.set_position(obstacles[i].entity, 0, -100, 0)
        end
    end
end

-- Update player movement based on input
local function update_player(dt)
    local move_speed = game.player_speed * dt
    
    if zephyr.input.is_key_down(Key.A) or zephyr.input.is_key_down(Key.Left) then
        game.player_x = game.player_x - move_speed
    end
    
    if zephyr.input.is_key_down(Key.D) or zephyr.input.is_key_down(Key.Right) then
        game.player_x = game.player_x + move_speed
    end
    
    -- Clamp player to screen bounds
    if game.player_x < -5 then game.player_x = -5 end
    if game.player_x > 5 then game.player_x = 5 end
    
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
        obs.x = math.random() * 10 - 5
        obs.y = 8
        obs.speed = 3 + math.random() * 2
        zephyr.transform.set_position(obs.entity, obs.x, obs.y, 0)
    end
end

-- Update obstacles
local function update_obstacles(dt)
    game.spawn_timer = game.spawn_timer + dt
    
    if game.spawn_timer >= game.spawn_interval then
        spawn_obstacle()
        game.spawn_timer = 0
        game.score = game.score + 1
    end
    
    for i = 1, MAX_OBSTACLES do
        local obs = obstacles[i]
        if obs and obs.active then
            obs.y = obs.y - obs.speed * dt
            zephyr.transform.set_position(obs.entity, obs.x, obs.y, 0)
            
            if obs.y < -6 then
                obs.active = false
                obs.y = -100
                zephyr.transform.set_position(obs.entity, 0, -100, 0)
            else
                local dx = math.abs(obs.x - game.player_x)
                local dy = math.abs(obs.y - game.player_y)
                if dx < 1.0 and dy < 1.0 then
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
