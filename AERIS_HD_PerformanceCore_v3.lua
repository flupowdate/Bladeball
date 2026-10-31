--[[
    AERIS HD Performance Core v3.0
    Visual-preserving workload scheduler for Roblox Luau.

    PURPOSE
      * Reduce avoidable CPU spikes by spreading NON-CRITICAL client work.
      * Adapt background-task frequency to observed frame pressure.
      * Prevent duplicate/overlapping executions of the same registered task.
      * Keep visual quality untouched: no particle deletion, no effect disabling,
        no Lighting/material/texture changes, and no forced graphics settings.

    IMPORTANT
      This module cannot create FPS from nothing or optimize code it does not own.
      Register only non-critical work such as UI/stat refreshes, cosmetic counters,
      and background scans. Do NOT register input, parry, physics, or timing-critical
      callbacks. A callback that performs expensive work can still cause a hitch.

    BACKWARD-COMPATIBLE CORE API
      local Core = require(path.To.AERIS_HD_PerformanceCore_v3)
      Core.Start()
      local token = Core.RegisterTask("StatsRefresh", function()
          -- non-critical work only
      end, 0.25, "low")
      Core.SetEnabled(true)
      -- later: Core.UnregisterTask(token); Core.Stop()

    OPTIONAL CONTROLS
      Core.Configure({ maxDispatchPerFrame = 1, maxConcurrentTasks = 2 })
      Core.SetTaskEnabled(token, false)
      local stats = Core.GetStats()
]]

local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = "3.0.0"

local enabled = false
local started = false
local heartbeatConnection = nil
local tasks = {}
local taskCount = 0
local nextTaskId = 0
local scanCursor = 1
local runningCount = 0

local fps = 0
local frameTimeMs = 0
local averageFrameTimeMs = 0
local callbackTimeMs = 0
local averageCallbackTimeMs = 0
local pressure = 1
local sampleElapsed = 0
local sampleFrames = 0
local schedulerElapsed = 0
local schedulerInterval = 1 / 30
local totalDispatches = 0
local totalSkipped = 0
local totalErrors = 0

local SAMPLE_WINDOW = 0.5
local MIN_TASK_INTERVAL = 1 / 60
local MAX_TASK_INTERVAL = 30
local EMA_ALPHA = 0.10
local DEFAULT_MAX_DISPATCH = 1
local DEFAULT_MAX_CONCURRENT = 2
local maxDispatchPerFrame = DEFAULT_MAX_DISPATCH
local maxConcurrentTasks = DEFAULT_MAX_CONCURRENT

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function countActiveTasks()
    local count = 0
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.active then count += 1 end
    end
    return count
end

local function compactTasks()
    local write = 1
    for read = 1, #tasks do
        local item = tasks[read]
        if item and item.active then
            tasks[write] = item
            write += 1
        end
    end
    for i = write, #tasks do tasks[i] = nil end
    taskCount = write - 1
    if scanCursor > taskCount then scanCursor = 1 end
end

local function updatePressure(dt)
    frameTimeMs = dt * 1000
    if averageFrameTimeMs <= 0 then
        averageFrameTimeMs = frameTimeMs
    else
        averageFrameTimeMs += (frameTimeMs - averageFrameTimeMs) * EMA_ALPHA
    end

    local framePressure = averageFrameTimeMs / 16.67
    local callbackPressure = averageCallbackTimeMs / 2.0
    local target = clamp(math.max(framePressure, callbackPressure, 1), 1, 4)
    pressure += (target - pressure) * 0.16
    schedulerInterval = clamp((1 / 30) * pressure, 1 / 60, 4 / 30)
end

local function dispatch(item, now)
    if item.running or not item.active then
        totalSkipped += 1
        return false
    end

    item.running = true
    runningCount += 1
    item.nextRun = now + item.interval * pressure * (item.priority == "normal" and 1 or 1.5)
    totalDispatches += 1

    task.defer(function()
        local startedAt = os.clock()
        local ok, err = pcall(item.callback)
        local elapsed = (os.clock() - startedAt) * 1000

        item.lastDurationMs = elapsed
        callbackTimeMs = elapsed
        if averageCallbackTimeMs <= 0 then
            averageCallbackTimeMs = elapsed
        else
            averageCallbackTimeMs += (elapsed - averageCallbackTimeMs) * 0.12
        end

        if ok then
            item.runCount += 1
            item.lastRun = os.clock()
        else
            item.errorCount += 1
            item.lastError = tostring(err)
            totalErrors += 1
        end

        item.running = false
        runningCount = math.max(0, runningCount - 1)
    end)
    return true
end

local function runDueTasks(now)
    if not enabled or taskCount == 0 then return end
    if now - schedulerElapsed < schedulerInterval then return end
    schedulerElapsed = now

    local dispatched = 0
    local checked = 0
    while checked < taskCount and dispatched < maxDispatchPerFrame and runningCount < maxConcurrentTasks do
        if scanCursor > taskCount then scanCursor = 1 end
        local item = tasks[scanCursor]
        scanCursor += 1
        checked += 1

        if item and item.active and not item.running and now >= item.nextRun then
            if dispatch(item, now) then dispatched += 1 end
        end
    end
end

function Core.Start()
    if started then return false, "already_started" end
    started = true
    heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
        if dt <= 0 then return end
        updatePressure(dt)
        sampleElapsed += dt
        sampleFrames += 1
        if sampleElapsed >= SAMPLE_WINDOW then
            fps = sampleFrames / sampleElapsed
            sampleElapsed = 0
            sampleFrames = 0
        end
        runDueTasks(os.clock())
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
    if enabled and not started then Core.Start() end
    return enabled
end

function Core.Configure(options)
    if type(options) ~= "table" then return false, "options_must_be_table" end
    if options.maxDispatchPerFrame ~= nil then
        maxDispatchPerFrame = math.floor(clamp(tonumber(options.maxDispatchPerFrame) or DEFAULT_MAX_DISPATCH, 1, 4))
    end
    if options.maxConcurrentTasks ~= nil then
        maxConcurrentTasks = math.floor(clamp(tonumber(options.maxConcurrentTasks) or DEFAULT_MAX_CONCURRENT, 1, 8))
    end
    return true
end

function Core.RegisterTask(name, callback, interval, priority)
    assert(type(callback) == "function", "callback must be a function")
    nextTaskId += 1
    local id = nextTaskId
    local safeInterval = clamp(tonumber(interval) or 0.25, MIN_TASK_INTERVAL, MAX_TASK_INTERVAL)
    local normalizedPriority = (priority == "normal" or priority == "low") and priority or "low"

    local item = {
        id = id,
        name = tostring(name or ("Task_" .. id)),
        callback = callback,
        interval = safeInterval,
        priority = normalizedPriority,
        nextRun = os.clock(),
        lastRun = 0,
        lastDurationMs = 0,
        runCount = 0,
        errorCount = 0,
        lastError = nil,
        active = true,
        running = false,
    }
    tasks[#tasks + 1] = item
    taskCount += 1
    return id
end

function Core.UnregisterTask(token)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token then
            item.active = false
            if not item.running then compactTasks() end
            return true
        end
    end
    return false
end

function Core.SetTaskEnabled(token, value)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token then
            item.active = value == true
            if item.active then item.nextRun = os.clock() end
            return true
        end
    end
    return false
end

function Core.GetStats()
    return {
        version = Core.VERSION,
        enabled = enabled,
        started = started,
        fps = fps,
        frameTimeMs = frameTimeMs,
        averageFrameTimeMs = averageFrameTimeMs,
        callbackTimeMs = callbackTimeMs,
        averageCallbackTimeMs = averageCallbackTimeMs,
        workloadPressure = pressure,
        schedulerInterval = schedulerInterval,
        activeTasks = countActiveTasks(),
        runningTasks = runningCount,
        maxDispatchPerFrame = maxDispatchPerFrame,
        maxConcurrentTasks = maxConcurrentTasks,
        totalDispatches = totalDispatches,
        totalSkipped = totalSkipped,
        totalErrors = totalErrors,
    }
end

function Core.GetTaskStats(token)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token then
            return {
                name = item.name,
                priority = item.priority,
                interval = item.interval,
                active = item.active,
                running = item.running,
                runCount = item.runCount,
                errorCount = item.errorCount,
                lastRun = item.lastRun,
                lastDurationMs = item.lastDurationMs,
                lastError = item.lastError,
            }
        end
    end
    return nil
end

return Core
