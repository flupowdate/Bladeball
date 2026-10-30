--[[
    AERIS HD Performance Core
    Version: 1.0.0
    Type: Standalone ModuleScript for Roblox experiences you own or are authorized to develop.

    Goals:
      * Measure frame time and estimated FPS.
      * Schedule explicitly registered, non-critical work.
      * Adapt the cadence of that work when frame time rises.
      * Never delete particles, disable effects, alter textures, lighting, terrain,
        materials, meshes, or other visual content.

    Important:
      * This module does not create hardware capability or guarantee a fixed FPS.
      * Register only optional/background work that is safe to run less often.
      * Do not register gameplay-critical simulation, input, physics, or networking.
]]

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local PerformanceCore = {}
PerformanceCore.__index = PerformanceCore

local DEFAULTS = {
    SampleWindow = 0.5,
    SlowFrameMs = 22.0,
    CriticalFrameMs = 30.0,
    RecoveryFrameMs = 18.0,
    RecoveryHoldSeconds = 3.0,
    MaxTasksPerHeartbeat = 4,
    MemorySampleInterval = 2.0,
}

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function safeMemoryMb()
    local ok, result = pcall(function()
        return Stats:GetTotalMemoryUsageMb()
    end)
    if ok and type(result) == "number" then
        return result
    end
    return nil
end

function PerformanceCore.new(options)
    local self = setmetatable({}, PerformanceCore)
    self.Options = {}
    for key, value in pairs(DEFAULTS) do
        self.Options[key] = value
    end
    if type(options) == "table" then
        for key, value in pairs(options) do
            if self.Options[key] ~= nil then
                self.Options[key] = value
            end
        end
    end

    self._running = false
    self._connection = nil
    self._tasks = {}
    self._taskOrder = {}
    self._frameSamples = {}
    self._sampleElapsed = 0
    self._memoryElapsed = 0
    self._recoveryElapsed = 0
    self._lastMemoryMb = nil
    self._frameTimeMs = 0
    self._fps = 0
    self._qualityTier = "NORMAL"
    self._taskCursor = 1
    self._destroyed = false

    return self
end

-- Register optional work only. interval is the desired minimum cadence in seconds.
-- priority: 1 (highest) through 5 (lowest). callback receives (deltaTime, metrics).
function PerformanceCore:RegisterTask(name, interval, callback, priority)
    assert(not self._destroyed, "PerformanceCore has been destroyed")
    assert(type(name) == "string" and name ~= "", "Task name must be a non-empty string")
    assert(type(interval) == "number" and interval >= 0, "Interval must be >= 0")
    assert(type(callback) == "function", "Callback must be a function")

    priority = clamp(tonumber(priority) or 3, 1, 5)
    self:UnregisterTask(name)

    self._tasks[name] = {
        Name = name,
        BaseInterval = interval,
        CurrentInterval = interval,
        Callback = callback,
        Priority = priority,
        Elapsed = 0,
        Enabled = true,
        Errors = 0,
    }

    table.insert(self._taskOrder, name)
    table.sort(self._taskOrder, function(a, b)
        return self._tasks[a].Priority < self._tasks[b].Priority
    end)
end

function PerformanceCore:UnregisterTask(name)
    self._tasks[name] = nil
    for index = #self._taskOrder, 1, -1 do
        if self._taskOrder[index] == name then
            table.remove(self._taskOrder, index)
        end
    end
    self._taskCursor = 1
end

function PerformanceCore:SetTaskEnabled(name, enabled)
    local task = self._tasks[name]
    if task then
        task.Enabled = enabled == true
        return true
    end
    return false
end

function PerformanceCore:_updateFrameMetrics(dt)
    if dt <= 0 then
        return
    end

    local frameMs = dt * 1000
    table.insert(self._frameSamples, frameMs)
    self._sampleElapsed += dt

    if self._sampleElapsed >= self.Options.SampleWindow then
        local total = 0
        for _, sample in ipairs(self._frameSamples) do
            total += sample
        end

        if #self._frameSamples > 0 then
            self._frameTimeMs = total / #self._frameSamples
            self._fps = self._frameTimeMs > 0 and (1000 / self._frameTimeMs) or 0
        end

        table.clear(self._frameSamples)
        self._sampleElapsed = 0
    end

    self._memoryElapsed += dt
    if self._memoryElapsed >= self.Options.MemorySampleInterval then
        self._lastMemoryMb = safeMemoryMb()
        self._memoryElapsed = 0
    end
end

function PerformanceCore:_updateAdaptiveCadence(dt)
    local averageMs = self._frameTimeMs
    local nextTier = self._qualityTier

    if averageMs >= self.Options.CriticalFrameMs then
        nextTier = "PROTECT"
        self._recoveryElapsed = 0
    elseif averageMs >= self.Options.SlowFrameMs then
        nextTier = "ADAPTIVE"
        self._recoveryElapsed = 0
    elseif averageMs > 0 and averageMs <= self.Options.RecoveryFrameMs then
        self._recoveryElapsed += dt
        if self._recoveryElapsed >= self.Options.RecoveryHoldSeconds then
            nextTier = "NORMAL"
        end
    else
        self._recoveryElapsed = 0
    end

    self._qualityTier = nextTier

    for _, task in pairs(self._tasks) do
        if nextTier == "PROTECT" then
            -- Background work is slowed down, not removed.
            task.CurrentInterval = math.max(task.BaseInterval, 0.75) * (1 + task.Priority * 0.35)
        elseif nextTier == "ADAPTIVE" then
            task.CurrentInterval = math.max(task.BaseInterval, 0.25) * (1 + task.Priority * 0.18)
        else
            task.CurrentInterval = task.BaseInterval
        end
    end
end

function PerformanceCore:GetMetrics()
    return {
        FPS = math.floor(self._fps + 0.5),
        FrameTimeMs = math.floor(self._frameTimeMs * 100 + 0.5) / 100,
        MemoryMB = self._lastMemoryMb,
        Mode = self._qualityTier,
        RegisteredTasks = #self._taskOrder,
    }
end

function PerformanceCore:_runTasks(dt)
    local count = #self._taskOrder
    if count == 0 then
        return
    end

    local executed = 0
    local visited = 0
    while visited < count and executed < self.Options.MaxTasksPerHeartbeat do
        if self._taskCursor > #self._taskOrder then
            self._taskCursor = 1
        end

        local name = self._taskOrder[self._taskCursor]
        self._taskCursor += 1
        visited += 1

        local task = self._tasks[name]
        if task and task.Enabled then
            task.Elapsed += dt
            if task.Elapsed >= task.CurrentInterval then
                local taskDt = task.Elapsed
                task.Elapsed = 0

                local ok = pcall(task.Callback, taskDt, self:GetMetrics())
                if not ok then
                    task.Errors += 1
                    if task.Errors >= 3 then
                        task.Enabled = false
                        warn("[AERIS Performance] Disabled task after 3 errors: " .. task.Name)
                    end
                else
                    task.Errors = 0
                end

                executed += 1
            end
        end
    end
end

function PerformanceCore:Start()
    assert(not self._destroyed, "PerformanceCore has been destroyed")
    if self._running then
        return
    end

    self._running = true
    self._connection = RunService.Heartbeat:Connect(function(dt)
        self:_updateFrameMetrics(dt)
        self:_updateAdaptiveCadence(dt)
        self:_runTasks(dt)
    end)
end

function PerformanceCore:Stop()
    self._running = false
    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end
end

function PerformanceCore:Destroy()
    self:Stop()
    table.clear(self._tasks)
    table.clear(self._taskOrder)
    table.clear(self._frameSamples)
    self._destroyed = true
end

return PerformanceCore
