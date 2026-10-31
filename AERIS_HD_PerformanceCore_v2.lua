--[[
    AERIS HD Performance Core v2.0
    Visual-safe client workload scheduler for Roblox Luau.

    PURPOSE
      - Measures frame time/FPS without changing graphics quality.
      - Lets a host script register NON-CRITICAL background callbacks.
      - Spreads registered work across frames and backs off under frame pressure.

    IMPORTANT
      This module does not magically optimize unrelated game code. To gain CPU
      savings, move suitable non-critical polling/UI/statistics work into
      RegisterTask callbacks. Never register parry/input/physics-critical work.
      It does not delete particles, disable effects, alter Lighting, or cap FPS.

    USAGE
      local Core = require(path.To.AERIS_HD_PerformanceCore_v2)
      Core.Start()
      local token = Core.RegisterTask("StatsRefresh", function()
          -- non-critical stats/UI refresh only
      end, 0.25, "low")
      Core.SetEnabled(true)
      -- later: Core.UnregisterTask(token); Core.Stop()
]]

local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = "2.0.0"

local enabled = false
local started = false
local heartbeatConnection = nil
local tasks = {}
local nextTaskId = 0

local sampleElapsed = 0
local sampleFrames = 0
local fps = 0
local frameTimeMs = 0
local averageFrameTimeMs = 0
local pressure = 1
local lastSchedulerTime = 0
local schedulerInterval = 1 / 30

local SAMPLE_WINDOW = 0.5
local MIN_INTERVAL = 1 / 60
local MAX_INTERVAL = 2.0
local EMA_ALPHA = 0.12

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function updatePressure(dt)
    frameTimeMs = dt * 1000
    if averageFrameTimeMs <= 0 then
        averageFrameTimeMs = frameTimeMs
    else
        averageFrameTimeMs += (frameTimeMs - averageFrameTimeMs) * EMA_ALPHA
    end

    -- Pressure is based on measured frame time, not ping/network latency.
    -- 16.7 ms ~= 60 FPS; 25 ms ~= 40 FPS; 33.3 ms ~= 30 FPS.
    local targetPressure = clamp(averageFrameTimeMs / 16.67, 1, 3)
    pressure += (targetPressure - pressure) * 0.18
    schedulerInterval = clamp((1 / 30) * pressure, MIN_INTERVAL, MAX_INTERVAL)
end

local function runDueTasks(now)
    if not enabled then
        return
    end

    if now - lastSchedulerTime < schedulerInterval then
        return
    end
    lastSchedulerTime = now

    for id, item in pairs(tasks) do
        if item.active and now >= item.nextRun then
            local priorityScale = item.priority == "normal" and 1 or 1.5
            item.nextRun = now + math.max(item.interval, schedulerInterval) * pressure * priorityScale
            -- Isolate callback failures so one task cannot stop the scheduler.
            task.spawn(function()
                local ok, err = pcall(item.callback)
                if not ok then
                    item.lastError = tostring(err)
                    item.errorCount += 1
                else
                    item.runCount += 1
                    item.lastRun = os.clock()
                end
            end)
        end
    end
end

function Core.Start()
    if started then
        return false, "already_started"
    end
    started = true
    heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
        if dt > 0 then
            updatePressure(dt)
            sampleElapsed += dt
            sampleFrames += 1
            if sampleElapsed >= SAMPLE_WINDOW then
                fps = sampleFrames / sampleElapsed
                sampleElapsed = 0
                sampleFrames = 0
            end
            runDueTasks(os.clock())
        end
    end)
    return true
end

function Core.Stop()
    enabled = false
    if heartbeatConnection then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
    started = false
    return true
end

function Core.SetEnabled(value)
    enabled = value == true
    if enabled and not started then
        Core.Start()
    end
    return enabled
end

function Core.RegisterTask(name, callback, interval, priority)
    assert(type(callback) == "function", "callback must be a function")
    nextTaskId += 1
    local id = nextTaskId
    local safeInterval = clamp(tonumber(interval) or 0.25, MIN_INTERVAL, MAX_INTERVAL)
    local normalizedPriority = (priority == "normal" or priority == "low") and priority or "low"

    tasks[id] = {
        id = id,
        name = tostring(name or ("Task_" .. id)),
        callback = callback,
        interval = safeInterval,
        priority = normalizedPriority,
        nextRun = os.clock(),
        lastRun = 0,
        runCount = 0,
        errorCount = 0,
        lastError = nil,
        active = true,
    }
    return id
end

function Core.UnregisterTask(token)
    if tasks[token] then
        tasks[token].active = false
        tasks[token] = nil
        return true
    end
    return false
end

function Core.SetTaskEnabled(token, value)
    local item = tasks[token]
    if not item then
        return false
    end
    item.active = value == true
    if item.active then
        item.nextRun = os.clock()
    end
    return true
end

function Core.GetStats()
    local activeTasks = 0
    local totalRuns = 0
    local totalErrors = 0
    for _, item in pairs(tasks) do
        if item.active then activeTasks += 1 end
        totalRuns += item.runCount
        totalErrors += item.errorCount
    end
    return {
        enabled = enabled,
        started = started,
        fps = fps,
        frameTimeMs = frameTimeMs,
        averageFrameTimeMs = averageFrameTimeMs,
        workloadPressure = pressure,
        schedulerInterval = schedulerInterval,
        activeTasks = activeTasks,
        totalRuns = totalRuns,
        totalErrors = totalErrors,
    }
end

function Core.GetTaskStats(token)
    local item = tasks[token]
    if not item then return nil end
    return {
        name = item.name,
        priority = item.priority,
        interval = item.interval,
        active = item.active,
        runCount = item.runCount,
        errorCount = item.errorCount,
        lastRun = item.lastRun,
        lastError = item.lastError,
    }
end

return Core
