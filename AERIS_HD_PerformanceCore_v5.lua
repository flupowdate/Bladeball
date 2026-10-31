--[[
    AERIS HD Performance Core v5.0
    Crash-resilient, visual-preserving background workload scheduler.

    BASE: AERIS_HD_PerformanceCore_v4.lua

    IMPORTANT
      This module schedules NON-CRITICAL background callbacks only.
      Do not register input, parry, physics, animation, networking, or
      render-critical work. Callbacks must be short and must not yield.

    VISUAL GUARANTEE BY DESIGN
      This module does not modify particles, Lighting, materials, textures,
      meshes, rendering settings, camera, graphics quality, or visual effects.

    BACKWARD-COMPATIBLE API
      Core.Start()
      local token = Core.RegisterTask("StatsRefresh", callback, 0.25, "low")
      Core.SetEnabled(true)
      Core.UnregisterTask(token)
      Core.Stop()

    OPTIONS
      Core.Configure({
          targetFrameRate = 60,
          maxDispatchPerFrame = 1,
          maxConcurrentTasks = 1,
          maxBackgroundMsPerSecond = 2.5,
          overloadFrameMs = 24,
          maxRegisteredTasks = 128,
      })

    OTHER
      Core.SetTaskEnabled(token, false)
      Core.GetStats()
      Core.GetTaskStats(token)
      Core.ResetStats()
]]

local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = "5.0.0"

local enabled = false
local started = false
local heartbeatConnection = nil

-- Dense task array. Disabled tasks remain registered so they can be re-enabled.
local tasks = {}
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

-- Token bucket: callback time is charged against a rolling per-second budget.
local budgetTokensMs = 2.5
local budgetCapacityMs = 2.5

local totalDispatches = 0
local totalSkipped = 0
local totalErrors = 0
local totalBudgetDeferrals = 0
local totalOverloadFrames = 0
local totalInternalErrors = 0
local totalRemovedTasks = 0

local SAMPLE_WINDOW = 0.5
local MIN_TASK_INTERVAL = 1 / 60
local MAX_TASK_INTERVAL = 60
local EMA_ALPHA = 0.08
local CALLBACK_EMA_ALPHA = 0.15

local DEFAULT_TARGET_FPS = 60
local DEFAULT_MAX_DISPATCH = 1
local DEFAULT_MAX_CONCURRENT = 1
local DEFAULT_BUDGET_MS_PER_SECOND = 2.5
local DEFAULT_OVERLOAD_FRAME_MS = 24
local DEFAULT_MAX_TASKS = 128

local targetFrameRate = DEFAULT_TARGET_FPS
local maxDispatchPerFrame = DEFAULT_MAX_DISPATCH
local maxConcurrentTasks = DEFAULT_MAX_CONCURRENT
local maxBackgroundMsPerSecond = DEFAULT_MAX_BUDGET_MS_PER_SECOND
local overloadFrameMs = DEFAULT_OVERLOAD_FRAME_MS
local maxRegisteredTasks = DEFAULT_MAX_TASKS

local PRIORITY_RANK = {
    high = 3,
    normal = 2,
    low = 1,
}

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
        if item and item.active and not item.removed then
            count += 1
        end
    end
    return count
end

local function compactRemovedTasks()
    local write = 1
    for read = 1, #tasks do
        local item = tasks[read]
        if item and not (item.removed and not item.running) then
            tasks[write] = item
            write += 1
        elseif item then
            totalRemovedTasks += 1
        end
    end

    for i = write, #tasks do
        tasks[i] = nil
    end

    if write <= 1 then
        scanCursor = 1
    else
        scanCursor = ((scanCursor - 1) % (write - 1)) + 1
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

    -- React quickly to overload and recover gradually to avoid oscillation.
    local alpha = targetPressure > pressure and 0.24 or 0.055
    pressure += (targetPressure - pressure) * alpha
    schedulerInterval = clamp((1 / 30) * pressure, 1 / 60, 0.5)

    -- Refill gradually; unused time does not accumulate beyond one second.
    budgetTokensMs = clamp(
        budgetTokensMs + dt * maxBackgroundMsPerSecond,
        0,
        budgetCapacityMs
    )
end

local function finishCallback(item, reservedMs, ok, err, elapsed, finishedAt)
    item.lastDurationMs = elapsed
    lastCallbackTimeMs = elapsed

    if averageCallbackTimeMs <= 0 then
        averageCallbackTimeMs = elapsed
    else
        averageCallbackTimeMs += (elapsed - averageCallbackTimeMs) * CALLBACK_EMA_ALPHA
    end

    -- Refund the reservation if the callback was cheaper; charge overrun otherwise.
    budgetTokensMs = clamp(
        budgetTokensMs + reservedMs - elapsed,
        0,
        budgetCapacityMs
    )

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

    if item.removed then
        compactRemovedTasks()
    end
end

local function dispatch(item, now)
    if not item or not item.active or item.removed or item.running then
        totalSkipped += 1
        return false
    end

    -- Reserve an estimated cost before dispatch so multiple tasks cannot all
    -- spend the same uncommitted budget in one frame.
    local estimateMs = math.max(item.lastDurationMs, averageCallbackTimeMs, 0.10)
    local reservationMs = math.min(estimateMs, maxBackgroundMsPerSecond)
    if budgetTokensMs < reservationMs then
        totalBudgetDeferrals += 1
        return false
    end

    budgetTokensMs = math.max(0, budgetTokensMs - reservationMs)
    item.running = true
    item.lastStart = now
    item.nextRun = now + item.interval * pressure * item.backoffMultiplier
    runningCount += 1
    totalDispatches += 1

    task.defer(function()
        local startedAt = os.clock()
        local ok, err = pcall(item.callback)
        local finishedAt = os.clock()
        local elapsed = math.max(0, (finishedAt - startedAt) * 1000)
        finishCallback(item, reservationMs, ok, err, elapsed, finishedAt)
    end)

    return true
end

local function canDispatch(now, dt)
    if not enabled or #tasks == 0 then
        return false
    end

    if dt * 1000 >= overloadFrameMs then
        totalOverloadFrames += 1
        totalBudgetDeferrals += 1
        return false
    end

    if now - schedulerElapsed < schedulerInterval then
        return false
    end

    if runningCount >= maxConcurrentTasks then
        totalSkipped += 1
        return false
    end

    if budgetTokensMs <= 0 then
        totalBudgetDeferrals += 1
        return false
    end

    return true
end

local function runDueTasks(now, dt)
    if not canDispatch(now, dt) then
        return
    end

    schedulerElapsed = now

    local taskLength = #tasks
    if taskLength == 0 then
        return
    end

    local dispatched = 0
    while dispatched < maxDispatchPerFrame and runningCount < maxConcurrentTasks do
        local bestItem = nil
        local bestIndex = nil
        local bestRank = -1
        local checked = 0

        -- Scan from the cursor and select the highest-priority due task.
        -- Move the cursor after the selected task so equal-priority tasks
        -- receive round-robin service rather than repeatedly favoring index 1.
        while checked < taskLength do
            local index = ((scanCursor + checked - 2) % taskLength) + 1
            local item = tasks[index]
            checked += 1

            if item and item.active and not item.removed and not item.running and now >= item.nextRun then
                local rank = PRIORITY_RANK[item.priority] or 1
                if rank > bestRank then
                    bestItem = item
                    bestIndex = index
                    bestRank = rank
                end
            end
        end

        if not bestItem then
            break
        end

        scanCursor = (bestIndex % taskLength) + 1
        if dispatch(bestItem, now) then
            dispatched += 1
        else
            -- Avoid repeatedly selecting the same task if its cost reservation
            -- cannot be afforded in the current budget window.
            break
        end
    end
end

local function heartbeatStep(dt)
    if dt <= 0 then
        return
    end

    updatePressure(dt)

    sampleElapsed += dt
    sampleFrames += 1
    if sampleElapsed >= SAMPLE_WINDOW then
        fps = sampleFrames / sampleElapsed
        sampleElapsed = 0
        sampleFrames = 0
    end

    runDueTasks(os.clock(), dt)
end

function Core.Start()
    if started then
        return false, "already_started"
    end

    local ok, connectionOrError = pcall(function()
        return RunService.Heartbeat:Connect(function(dt)
            local stepOk = pcall(heartbeatStep, dt)
            if not stepOk then
                totalInternalErrors += 1
            end
        end)
    end)

    if not ok or not connectionOrError then
        totalInternalErrors += 1
        return false, "heartbeat_connection_failed"
    end

    heartbeatConnection = connectionOrError
    started = true
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
    if type(options) ~= "table" then
        return false, "options_must_be_table"
    end

    local value

    if options.targetFrameRate ~= nil then
        value = finiteNumber(options.targetFrameRate)
        if not value then return false, "invalid_targetFrameRate" end
        targetFrameRate = clamp(value, 30, 240)
    end

    if options.maxDispatchPerFrame ~= nil then
        value = finiteNumber(options.maxDispatchPerFrame)
        if not value then return false, "invalid_maxDispatchPerFrame" end
        maxDispatchPerFrame = math.floor(clamp(value, 1, 3))
    end

    if options.maxConcurrentTasks ~= nil then
        value = finiteNumber(options.maxConcurrentTasks)
        if not value then return false, "invalid_maxConcurrentTasks" end
        maxConcurrentTasks = math.floor(clamp(value, 1, 6))
    end

    if options.maxBackgroundMsPerSecond ~= nil then
        value = finiteNumber(options.maxBackgroundMsPerSecond)
        if not value then return false, "invalid_maxBackgroundMsPerSecond" end
        maxBackgroundMsPerSecond = clamp(value, 0.25, 20)
        budgetCapacityMs = maxBackgroundMsPerSecond
        budgetTokensMs = math.min(budgetTokensMs, budgetCapacityMs)
    end

    if options.overloadFrameMs ~= nil then
        value = finiteNumber(options.overloadFrameMs)
        if not value then return false, "invalid_overloadFrameMs" end
        overloadFrameMs = clamp(value, 12, 100)
    end

    if options.maxRegisteredTasks ~= nil then
        value = finiteNumber(options.maxRegisteredTasks)
        if not value then return false, "invalid_maxRegisteredTasks" end
        maxRegisteredTasks = math.floor(clamp(value, 1, 512))
    end

    return true
end

function Core.RegisterTask(name, callback, interval, priority)
    if type(callback) ~= "function" then
        return nil, "callback_must_be_function"
    end

    if #tasks >= maxRegisteredTasks then
        return nil, "task_limit_reached"
    end

    local safeInterval = finiteNumber(interval) or 0.25
    safeInterval = clamp(safeInterval, MIN_TASK_INTERVAL, MAX_TASK_INTERVAL)

    local normalizedPriority = "low"
    if priority == "high" or priority == "normal" or priority == "low" then
        normalizedPriority = priority
    end

    nextTaskId += 1
    local id = nextTaskId
    local safeName = tostring(name or ("Task_" .. id))

    local item = {
        id = id,
        name = string.sub(safeName, 1, 64),
        callback = callback,
        interval = safeInterval,
        priority = normalizedPriority,
        nextRun = os.clock() + safeInterval,
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
        removed = false,
    }

    tasks[#tasks + 1] = item
    return id
end

function Core.UnregisterTask(token)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token and not item.removed then
            item.active = false
            item.removed = true
            if not item.running then
                compactRemovedTasks()
            end
            return true
        end
    end

    return false
end

function Core.SetTaskEnabled(token, value)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token and not item.removed then
            item.active = value == true
            if item.active then
                item.nextRun = os.clock() + item.interval
                item.backoffMultiplier = 1
                item.consecutiveErrors = 0
            end
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
        registeredTasks = #tasks,
        runningTasks = runningCount,
        maxDispatchPerFrame = maxDispatchPerFrame,
        maxConcurrentTasks = maxConcurrentTasks,
        maxBackgroundMsPerSecond = maxBackgroundMsPerSecond,
        callbackBudgetRemainingMs = budgetTokensMs,
        totalDispatches = totalDispatches,
        totalSkipped = totalSkipped,
        totalErrors = totalErrors,
        totalBudgetDeferrals = totalBudgetDeferrals,
        totalOverloadFrames = totalOverloadFrames,
        totalInternalErrors = totalInternalErrors,
        totalRemovedTasks = totalRemovedTasks,
    }
end

function Core.GetTaskStats(token)
    for i = 1, #tasks do
        local item = tasks[i]
        if item and item.id == token and not item.removed then
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

function Core.ResetStats()
    fps = 0
    frameTimeMs = 0
    averageFrameTimeMs = 16.67
    worstFrameTimeMs = 0
    averageCallbackTimeMs = 0
    lastCallbackTimeMs = 0
    pressure = 1
    sampleElapsed = 0
    sampleFrames = 0
    totalDispatches = 0
    totalSkipped = 0
    totalErrors = 0
    totalBudgetDeferrals = 0
    totalOverloadFrames = 0
    totalInternalErrors = 0
    totalRemovedTasks = 0
    budgetTokensMs = budgetCapacityMs
    return true
end

return Core
