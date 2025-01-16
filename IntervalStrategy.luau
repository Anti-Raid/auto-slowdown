local kv = require "@antiraid/kv"
local datetime = require "@antiraid/datetime"
local global = require "@antiraid-ext/global" 
local discord = require "@discord-types/apiTypes"
local Primitives = require "@antiraid-core/primitives"
local promise = require "@antiraid/promise"

type Interval = {
    --- At what interval to start the slow mode at
    Start: number,
    --- At what interval to stop the slow mode at
    Stop: number,
    --- The slowdown to set
    Slowdown: number
}

--- Parses a Interval
---
--- Format: {SingleInterval}|{SingleInterval}...
--- SingleInterval: {Mode},{Mode.Opts}
---
--- Modes:
--- 
--- Absolute: Absolute,{StartUnixTime},{StopUnixTime},{Slowdown}
--- TimePerDay: TimePerDay,{StartHours}[:]{StartMinutes}[:]{StartSeconds},{StopHours}[:]{StopMinutes}[:]{StopSeconds},{Timezone},{Slowdown}
--- (ex: TimePerDay,12:00:00,13:00:00,UTC,5 [start slowmode of 5 seconds at 12:00:00 UTC and end it at 13:00:00 UTC] or TimePerDay,73340,46800,UTC,5 [start slowmode at 73340 seconds and end it at 46800 seconds])
local function parseInterval(setting: string): {Interval}
    -- Remove whitespace
    setting, _ = string.gsub(setting, "%s+", "")
    local settings = {}
    for _, setting in ipairs(string.split(setting, "|")) do
        local parts = string.split(setting, ",")
        local mode = parts[1]

        if mode == "Absolute" then
            if #parts ~= 4 then continue end
            local start = tonumber(parts[2])
            if start == nil then continue end
            local stop = tonumber(parts[3])
            if stop == nil then continue end
            local slowdown = tonumber(parts[4])
            if slowdown == nil then continue end

            table.insert(settings, {
                Start = start,
                Stop = stop,
                Slowdown = slowdown
            })
        elseif mode == "TimePerDay" then
            if #parts ~= 5 then continue end
            local start = string.split(parts[2], ":")
            local startHours = tonumber(start[1]) or 0
            local startMinutes = tonumber(start[2]) or 0
            local startSeconds = tonumber(start[3]) or 0

            local stop = string.split(parts[3], ":")
            local stopHours = tonumber(stop[1]) or 0
            local stopMinutes = tonumber(stop[2]) or 0
            local stopSeconds = tonumber(stop[3]) or 0

            local timezone = parts[4]

            local tz = datetime.new(timezone)
            local utcStartTime = tz.timeTzToUtc(startHours, startMinutes, startSeconds)
            local utcStopTime = tz.timeTzToUtc(stopHours, stopMinutes, stopSeconds)

            local slowdown = tonumber(parts[5])
            if slowdown == nil then continue end

            table.insert(settings, {
                Start = utcStartTime.timestamp_seconds,
                Stop = utcStopTime.timestamp_seconds,
                Slowdown = slowdown
            })
        end
    end
    return settings
end

return function(channelId: string, ctx: Primitives.TemplateContext, msg: discord.MessageObject): number?
    local CachedKvExecutor = global.update(
        "AutoSlowdownKv",
        function() return kv.new(ctx) end, 
        function(v: kv.KvExecutor) return v end
    )
  
    local globalSetting = promise.yield(CachedKvExecutor:get("AutoSlowdownIntervals:Global")) :: string?
    local perChannelSetting = promise.yield(CachedKvExecutor:get("AutoSlowdownIntervals:" .. channelId)) :: string?

    local settingsToUse: {Interval} = {}
    if globalSetting ~= nil
    then
        settingsToUse = parseInterval(globalSetting)
    end

    if perChannelSetting ~= nil
    then
        local perChannelSettings = parseInterval(perChannelSetting)
        for _, setting in ipairs(perChannelSettings) do
            table.insert(settingsToUse, setting)
        end
    end
    
    local reject: Interval? = nil;

    local now = os.clock()
    for _, setting in ipairs(settingsToUse) do
        -- Check if we are in the interval
        if now >= setting.Start and now <= setting.Stop then
            if reject ~= nil then
                -- Pick the interval with greater slowdown
                if setting.Slowdown > reject.Slowdown then
                    reject = setting
                end
            else
                -- Set reject
                reject = setting
            end
        end
    end

    if reject ~= nil then
        return reject.Slowdown
    end
 
    return nil
end    
   