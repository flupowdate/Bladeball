--[[
    AERIS HD Performance Core v4.4
    Visual-preserving adaptive scheduler for Roblox Luau.

    BASE: AERIS_HD_PerformanceCore_v4.lua (all V4 defaults and public APIs retained)

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
      -- cooperating host scripts may also use:
      Core.GetLoadState()
      Core.ShouldDeferOptionalWork()
      Core.GetRecommendedInterval(0.25)

    V4.1 FIXES retained
      - Protect Heartbeat connection and scheduler-step failures.
      - Recover scheduler state if task.defer itself fails.
      - Compact tasks unregistered while callbacks are running.
      - Validate Configure options atomically; reject NaN/infinity.
      - Preserve V4 dispatch/concurrency/budget defaults and immediate first run.

    V4.2 FIX
      - Bound each scheduler scan to 64 tasks per pass with round-robin continuation.

    V4.3 FIX
      - Estimate the next callback cost and defer work before the remaining
        background-time budget is likely to be exceeded.
      - Detect callbacks that exceed the configured background budget and apply
        a gradual per-task cooldown, without changing callback behavior or APIs.
      - Expose budget headroom and slow-callback counters for real-device tuning.

    V4.4 EXTERNAL-INTEGRATION FIX
      - Expose NORMAL / BUSY / CRITICAL load state for cooperating host scripts.
      - Expose ShouldDeferOptionalWork() and GetRecommendedInterval() so a host
        can throttle only its own non-critical polling without source-level
        access to unrelated scripts.
      - Add load-state transition telemetry.
      - Fix duplicate error counting for a failed callback.
      - Keep defaults and existing APIs; no visual or rendering settings change.
]]

local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = "4.4.0"

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
local totalInternalErrors = 0
local totalScannedTasks = 0
local totalSlowCallbacks = 0
local totalCallbackOverruns = 0
local lastCallbackOverrunMs = 0
local lastSlowCallbackName = nil
local loadState = "normal"
local totalLoadStateChanges = 0
local lastLoadStateChangeAt = 0

local SAMPLE_WINDOW = 0.5
local MIN_TASK_INTERVAL = 1 / 60
local MAX_TASK_INTERVAL = 60
-- Bound scheduler scanning so a large registry cannot monopolize one Heartbeat.
-- The round-robin cursor carries unfinished scanning into later passes.
local MAX_TASK_SCAN_PER_PASS = 64
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

local function finiteNumber(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
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

local function calculateLoadState()
    if frameTimeMs >= overloadFrameMs or pressure >= 4 then
        return "critical"
    elseif pressure >= 2 or averageFrameTimeMs >= (1000 / targetFrameRate) * 1.5 then
        return "busy"
    end
    return "normal"
end

local function updateLoadState(now)
    local nextState = calculateLoadState()
    if nextState ~= loadState then
        loadState = nextState
        totalLoadStateChanges += 1
        lastLoadStateChangeAt = now or os.clock()
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
    updateLoadState(os.clock())
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
    -- Reserve the recent average callback cost before dispatch. This cannot
    -- preempt a callback already running, but avoids knowingly spending the
    -- remaining budget on work that is likely to exceed it.
    local estimatedCostMs = averageCallbackTimeMs > 0 and averageCallbackTimeMs or 0.25
    if callbackBudgetWindowMs + estimatedCostMs > maxBackgroundMsPerSecond then
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

    local scheduled, scheduleError = pcall(function()
        task.defer(function()
            local startedAt = os.clock()
            local ok, err = pcall(item.callback)
            local finishedAt = os.clock()
            local elapsed = math.max(0, (finishedAt - startedAt) * 1000)

            item.lastDurationMs = elapsed
            lastCallbackTimeMs = elapsed
            if averageCallbackTimeMs <= 0 then
                averageCallbackTimeMs = elapsed
            else
                averageCallbackTimeMs += (elapsed - averageCallbackTimeMs) * CALLBACK_EMA_ALPHA
            end

            -- Budget is charged after completion; the next scheduler pass observes it.
            callbackBudgetWindowMs += elapsed

            local slowThresholdMs = math.max(1.0, maxBackgroundMsPerSecond * 0.5)
            local callbackWasSlow = elapsed > slowThresholdMs
            if callbackWasSlow then
                totalSlowCallbacks += 1
                lastSlowCallbackName = item.name
                lastCallbackOverrunMs = elapsed
                if elapsed > maxBackgroundMsPerSecond then
                    totalCallbackOverruns += 1
                end
            end

            if ok then
                item.runCount += 1
                item.lastRun = finishedAt
                item.consecutiveErrors = 0
                if callbackWasSlow then
                    -- Back off expensive background work gradually. Successful
                    -- callbacks still complete normally and remain registered.
                    item.backoffMultiplier = math.min(16, item.backoffMultiplier * 1.25)
                    item.nextRun = math.max(item.nextRun, finishedAt + item.interval * item.backoffMultiplier)
                else
                    item.backoffMultiplier = math.max(1, item.backoffMultiplier * 0.85)
                end
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

            if not item.active then
                compactTasks()
            end
        end)
    end)

    if not scheduled then
        item.running = false
        runningCount = math.max(0, runningCount - 1)
        item.errorCount += 1
        item.consecutiveErrors += 1
        item.lastError = tostring(scheduleError)
        item.backoffMultiplier = math.min(16, item.backoffMultiplier * 2)
        item.nextRun = os.clock() + item.interval * item.backoffMultiplier
        totalErrors += 1
        totalInternalErrors += 1
        return false
    end
    return true
end

local function runDueTasks(now, dt)
    if not canDispatch(now, dt) then return end
    schedulerElapsed = now

    local dispatched = 0
    local checked = 0
    local scanLimit = math.min(taskCount, MAX_TASK_SCAN_PER_PASS)
    while checked < scanLimit and dispatched < maxDispatchPerFrame do
        if scanCursor > taskCount then scanCursor = 1 end
        local item = tasks[scanCursor]
        scanCursor += 1
        checked += 1
        totalScannedTasks += 1

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
    local ok, connectionOrError = pcall(function()
        return RunService.Heartbeat:Connect(function(dt)
            local stepOk = pcall(function()
                if type(dt) ~= "number" or dt <= 0 then return end
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
            if not stepOk then
                totalInternalErrors += 1
            end
        end)
    end)
    if not ok or not connectionOrError then
        totalInternalErrors += 1
        started = false
        heartbeatConnection = nil
        return false, "heartbeat_connection_failed"
    end
    heartbeatConnection = connectionOrError
    return true
end

function Core.Stop()
    enabled = false
    if heartbeatConnection then
        pcall(function()
            heartbeatConnection:Disconnect()
        end)
        heartbeatConnection = nil
    end
    started = false
    return true
end

function Core.SetEnabled(value)
    enabled = value == true
    if enabled and not started then
        local ok, reason = Core.Start()
        if not ok then
            enabled = false
            return false, reason
        end
    end
    return enabled
end

function Core.Configure(options)
    if type(options) ~= "table" then return false, "options_must_be_table" end

    -- Validate all supplied values before changing anything, so a bad option
    -- cannot leave the scheduler half-configured.
    local values = {}
    local ranges = {
        targetFrameRate = {30, 240, DEFAULT_TARGET_FPS},
        maxDispatchPerFrame = {1, 3, DEFAULT_MAX_DISPATCH},
        maxConcurrentTasks = {1, 6, DEFAULT_MAX_CONCURRENT},
        maxBackgroundMsPerSecond = {0.25, 20, DEFAULT_BUDGET_MS_PER_SECOND},
        overloadFrameMs = {12, 100, DEFAULT_OVERLOAD_FRAME_MS},
    }
    for key, range in pairs(ranges) do
        if options[key] ~= nil then
            local value = finiteNumber(options[key])
            if not value then return false, "invalid_" .. key end
            values[key] = clamp(value, range[1], range[2])
        end
    end

    if values.targetFrameRate then targetFrameRate = values.targetFrameRate end
    if values.maxDispatchPerFrame then maxDispatchPerFrame = math.floor(values.maxDispatchPerFrame) end
    if values.maxConcurrentTasks then maxConcurrentTasks = math.floor(values.maxConcurrentTasks) end
    if values.maxBackgroundMsPerSecond then maxBackgroundMsPerSecond = values.maxBackgroundMsPerSecond end
    if values.overloadFrameMs then overloadFrameMs = values.overloadFrameMs end
    return true
end

function Core.RegisterTask(name, callback, interval, priority)
    assert(type(callback) == "function", "callback must be a function")
    nextTaskId += 1
    local id = nextTaskId
    local safeInterval = clamp(finiteNumber(interval) or 0.25, MIN_TASK_INTERVAL, MAX_TASK_INTERVAL)
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

-- Host-integration helpers. These do not control unrelated scripts by
-- themselves; a cooperating host should consult them before optional work.
function Core.GetLoadState()
    return loadState
end

function Core.ShouldDeferOptionalWork()
    return loadState == "critical" or pressure >= 3.5 or frameTimeMs >= overloadFrameMs
end

function Core.GetRecommendedInterval(baseInterval)
    local base = finiteNumber(baseInterval)
    if not base or base <= 0 then
        return nil, "base_interval_must_be_positive_number"
    end
    local multiplier = math.max(1, pressure)
    if loadState == "critical" then
        multiplier = math.max(multiplier, 4)
    elseif loadState == "busy" then
        multiplier = math.max(multiplier, 2)
    end
    return clamp(base * multiplier, MIN_TASK_INTERVAL, MAX_TASK_INTERVAL)
end

function Core.GetStats()
    return {
        version = Core.VERSION,
        enabled = enabled,
        loadState = loadState,
        shouldDeferOptionalWork = Core.ShouldDeferOptionalWork(),
        recommendedBackgroundScale = math.max(1, pressure),
        totalLoadStateChanges = totalLoadStateChanges,
        lastLoadStateChangeAt = lastLoadStateChangeAt,
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
        totalInternalErrors = totalInternalErrors,
        totalScannedTasks = totalScannedTasks,
        maxTaskScanPerPass = MAX_TASK_SCAN_PER_PASS,
        estimatedNextCallbackMs = averageCallbackTimeMs > 0 and averageCallbackTimeMs or 0.25,
        remainingCallbackBudgetMs = math.max(0, maxBackgroundMsPerSecond - callbackBudgetWindowMs),
        callbackBudgetUtilization = clamp(callbackBudgetWindowMs / maxBackgroundMsPerSecond, 0, 1),
        totalSlowCallbacks = totalSlowCallbacks,
        totalCallbackOverruns = totalCallbackOverruns,
        lastCallbackOverrunMs = lastCallbackOverrunMs,
        lastSlowCallbackName = lastSlowCallbackName,
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
