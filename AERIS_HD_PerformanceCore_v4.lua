--[[
    AERIS HD Performance Core v4.0
    Visual-preserving adaptive scheduler for Roblox Luau.

    BASE: AERIS_HD_PerformanceCore_v3.lua

    PURPOSE
      - Reduce avoidable CPU spikes caused by NON-CRITICAL background work.
      - Enforce a per-frame dispatch budget and a global callback-time budget.
      - Adapt background cadence to frame-time pressure with hysteresis.
      - Prevent duplicate runs, runaway callbacks, and scheduler starvation.
      - Preserve all visual settings and effects: this module does not modify
        particles, Lighting, materials, textures, meshes, rendering, or quality.

    IMPORTANT LIMIT
      This is a workload scheduler, not a renderer/engine replacement. It can
      improve performance only after expensive, non-critical work is registered
      here. It cannot guarantee 10x FPS, and it must not own input, parry,
      physics, animation, networking, or other timing-critical callbacks.

    BACKWARD-COMPATIBLE API
      Core.Start()
      local token = Core.RegisterTask("StatsRefresh", callback, 0.25, "low")
      Core.SetEnabled(true)
      Core.UnregisterTask(token)
      Core.Stop()

    OPTIONAL
      Core.Configure({
          targetFrameRate = 60,
          maxDispatchPerFrame = 1,
          maxConcurrentTasks = 2,
          maxBackgroundMsPerSecond = 3.0,
          overloadFrameMs = 20,
      })
      Core.SetTaskEnabled(token, false)
      Core.GetStats()
      Core.GetTaskStats(token)
]]

local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = "4.0.0"

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
local averageFrameTimeMs = 16.67
local worstFrameTimeMs = 0
local averageCallbackTimeMs = 0
local lastCallbackTimeMs = 0
local pressure = 1
local sampleElapsed = 0
local sampleFrames = 0
local schedulerElapsed = 0
local schedulerInterval = 1 / 30
local budgetWindowElapsed = 0
local callbackBudgetUsedMs = 0
local callbackBudgetWindowMs = 0
local totalDispatches = 0
local totalSkipped = 0
local totalErrors = 0
local totalBudgetDeferrals = 0
local totalOverloadFrames = 0

local SAMPLE_WINDOW = 0.5
local MIN_TASK_INTERVAL = 1 / 60
local MAX_TASK_INTERVAL = 60
local EMA_ALPHA = 0.08
local CALLBACK_EMA_ALPHA = 0.15
local DEFAULT_TARGET_FPS = 60
local DEFAULT_MAX_DISPATCH = 1
local DEFAULT_MAX_CONCURRENT = 2
local DEFAULT_BUDGET_MS_PER_SECOND = 3.0
local DEFAULT_OVERLOAD_FRAME_MS = 20

local targetFrameRate = DEFAULT_TARGET_FPS
local maxDispatchPerFrame = DEFAULT_MAX_DISPATCH
local maxConcurrentTasks = DEFAULT_MAX_CONCURRENT
local maxBackgroundMsPerSecond = DEFAULT_BUDGET_MS_PER_SECOND
local overloadFrameMs = DEFAULT_OVERLOAD_FRAME_MS

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
    if taskCount == 0 then
        scanCursor = 1
    else
        scanCursor = ((scanCursor - 1) % taskCount) + 1
    end
end

local function updatePressure(dt)
    frameTimeMs = dt * 1000
    if frameTimeMs > worstFrameTimeMs then
        worstFrameTimeMs = frameTimeMs
    else
        worstFrameTimeMs += (frameTimeMs - worstFrameTimeMs) * 0.015
    end

    averageFrameTimeMs += (frameTimeMs - averageFrameTimeMs) * EMA_ALPHA

    local targetFrameMs = 1000 / targetFrameRate
    local frameRatio = averageFrameTimeMs / targetFrameMs
    local callbackRatio = averageCallbackTimeMs / 2.0
    local targetPressure = clamp(math.max(frameRatio, callbackRatio, 1), 1, 6)

    -- Faster reaction to overload, slower recovery to avoid oscillation.
    local alpha = targetPressure > pressure and 0.24 or 0.055
    pressure += (targetPressure - pressure) * alpha
    schedulerInterval = clamp((1 / 30) * pressure, 1 / 60, 0.5)
end

local function canDispatch(now, dt)
    if not enabled or taskCount == 0 then return false end
    if dt * 1000 >= overloadFrameMs then
        totalOverloadFrames += 1
        totalBudgetDeferrals += 1
        return false
    end
    if now - schedulerElapsed < schedulerInterval then return false end
    if runningCount >= maxConcurrentTasks then
        totalSkipped += 1
        return false
    end
    if callbackBudgetWindowMs >= maxBackgroundMsPerSecond then
        totalBudgetDeferrals += 1
        return false
    end
    return true
end

local function dispatch(item, now)
    if not item or not item.active or item.running then
        totalSkipped += 1
        return false
    end

    item.running = true
    item.lastStart = now
    runningCount += 1
    item.nextRun = now + item.interval * pressure * item.backoffMultiplier
    totalDispatches += 1

    task.defer(function()
        local startedAt = os.clock()
        local ok, err = pcall(item.callback)
        local elapsed = math.max(0, (os.clock() - startedAt) * 1000)
        local finishedAt = os.clock()

        item.lastDurationMs = elapsed
        lastCallbackTimeMs = elapsed
        if averageCallbackTimeMs <= 0 then
            averageCallbackTimeMs = elapsed
        else
            averageCallbackTimeMs += (elapsed - averageCallbackTimeMs) * CALLBACK_EMA_ALPHA
        end

        -- Budget is charged after completion; the next scheduler pass observes it.
        callbackBudgetWindowMs += elapsed

        if ok then
            item.runCount += 1
            item.lastRun = finishedAt
            item.consecutiveErrors = 0
            item.backoffMultiplier = math.max(1, item.backoffMultiplier * 0.85)
            item.lastError = nil
        else
            item.errorCount += 1
            item.consecutiveErrors += 1
            item.lastError = tostring(err)
            totalErrors += 1
            item.backoffMultiplier = math.min(16, item.backoffMultiplier * 2)
            item.nextRun = finishedAt + item.interval * item.backoffMultiplier
        end

        item.running = false
        runningCount = math.max(0, runningCount - 1)
    end)
    return true
end

local function runDueTasks(now, dt)
    if not canDispatch(now, dt) then return end
    schedulerElapsed = now

    local dispatched = 0
    local checked = 0
    while checked < taskCount and dispatched < maxDispatchPerFrame do
        if scanCursor > taskCount then scanCursor = 1 end
        local item = tasks[scanCursor]
        scanCursor += 1
        checked += 1

        if item and item.active and not item.running and now >= item.nextRun then
            if dispatch(item, now) then
                dispatched += 1
                -- Dispatch at most one callback per Heartbeat by default.
                if runningCount >= maxConcurrentTasks then break end
            end
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
        budgetWindowElapsed += dt
        if sampleElapsed >= SAMPLE_WINDOW then
            fps = sampleFrames / sampleElapsed
            sampleElapsed = 0
            sampleFrames = 0
        end
        if budgetWindowElapsed >= 1 then
            budgetWindowElapsed = 0
            callbackBudgetWindowMs = 0
        end

        runDueTasks(os.clock(), dt)
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
    if options.targetFrameRate ~= nil then
        targetFrameRate = clamp(tonumber(options.targetFrameRate) or DEFAULT_TARGET_FPS, 30, 240)
    end
    if options.maxDispatchPerFrame ~= nil then
        maxDispatchPerFrame = math.floor(clamp(tonumber(options.maxDispatchPerFrame) or DEFAULT_MAX_DISPATCH, 1, 3))
    end
    if options.maxConcurrentTasks ~= nil then
        maxConcurrentTasks = math.floor(clamp(tonumber(options.maxConcurrentTasks) or DEFAULT_MAX_CONCURRENT, 1, 6))
    end
    if options.maxBackgroundMsPerSecond ~= nil then
        maxBackgroundMsPerSecond = clamp(tonumber(options.maxBackgroundMsPerSecond) or DEFAULT_BUDGET_MS_PER_SECOND, 0.25, 20)
    end
    if options.overloadFrameMs ~= nil then
        overloadFrameMs = clamp(tonumber(options.overloadFrameMs) or DEFAULT_OVERLOAD_FRAME_MS, 12, 100)
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
        lastStart = 0,
        lastDurationMs = 0,
        runCount = 0,
        errorCount = 0,
        consecutiveErrors = 0,
        backoffMultiplier = 1,
        lastError = nil,
        active = true,
        running = false,
    }
    if normalizedPriority == "normal" then
        item.interval = math.max(MIN_TASK_INTERVAL, safeInterval * 0.75)
    end
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
            if item.active then
                item.nextRun = os.clock()
                item.backoffMultiplier = 1
            end
            if not item.active and not item.running then compactTasks() end
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
        worstFrameTimeMs = worstFrameTimeMs,
        callbackTimeMs = lastCallbackTimeMs,
        averageCallbackTimeMs = averageCallbackTimeMs,
        workloadPressure = pressure,
        schedulerInterval = schedulerInterval,
        activeTasks = countActiveTasks(),
        runningTasks = runningCount,
        maxDispatchPerFrame = maxDispatchPerFrame,
        maxConcurrentTasks = maxConcurrentTasks,
        maxBackgroundMsPerSecond = maxBackgroundMsPerSecond,
        callbackBudgetUsedMs = callbackBudgetWindowMs,
        totalDispatches = totalDispatches,
        totalSkipped = totalSkipped,
        totalErrors = totalErrors,
        totalBudgetDeferrals = totalBudgetDeferrals,
        totalOverloadFrames = totalOverloadFrames,
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
                consecutiveErrors = item.consecutiveErrors,
                backoffMultiplier = item.backoffMultiplier,
                lastRun = item.lastRun,
                lastDurationMs = item.lastDurationMs,
                lastError = item.lastError,
            }
        end
    end
    return nil
end

return Core
