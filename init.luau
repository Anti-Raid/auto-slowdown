local discord = require "@antiraid/discord"
local promise = require "@antiraid/promise"
local global = require "@antiraid-ext/global" 
local Primitives = require "@antiraid-core/primitives"
local kv = require "@antiraid/kv"
local gcra = require "@antiraid-ext/gcra"
local Message = require "@antiraid-ext/events/discord/Message"
local restTypes = require "@discord-types/restTypes"
  
local evt: Primitives.Event, ctx: Primitives.TemplateContext = ...

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function updateSlowMode(channelId: string, seconds: number, reason: string)
    local lastSetSlowmode = global.get(
        "AutoSlowdownLastSet:" .. channelId
    )

    if lastSetSlowmode ~= nil and lastSetSlowmode == seconds then
        return -- We've already set this slow mode
    end

    -- Set the last set slow mode
    global.set(
        "AutoSlowdownLastSet:" .. channelId,
        seconds
    )

    local discord_executor = discord.new(ctx);
    promise.yield(discord_executor:edit_channel({
        channel_id = channelId,
        reason = reason,
        data = {
            rate_limit_per_user = seconds :: number?
        } :: restTypes.ModifyChannelRequest
    }))
end

type AutoSlowdownSetting = {
    --- At what minimum message count should the slow mode be updated at
    MessageCount: number,
    --- What rate does this minimum message count have to be at
    Time: number,
    --- The new slow mode to set
    Slowdown: number
}

local function settingToId(setting: AutoSlowdownSetting): string
    return tostring(setting.MessageCount) .. "," .. tostring(setting.Time) .. "," .. tostring(setting.Slowdown)
end

--- Default set of settings if not configured
local DefaultSettings: {AutoSlowdownSetting} = {
    {MessageCount = 5, Time = 10, Slowdown = 5},
    {MessageCount = 10, Time = 10, Slowdown = 10},
    {MessageCount = 20, Time = 10, Slowdown = 30},
    {MessageCount = 50, Time = 10, Slowdown = 60},
    {MessageCount = 100, Time = 10, Slowdown = 120}
}

--- Parses a AutoSlowdown setting
---
--- Format: {MessageCount},{Time},{Slowdown}|{MessageCount},{Slowdown}...
local function parseAutoslowdownSetting(setting: string): {AutoSlowdownSetting}
    local settings = {}
    for _, setting in ipairs(string.split(setting, "|")) do
        local parts = string.split(setting, ",")
        if #parts == 3 then
            table.insert(settings, {
                MessageCount = tonumber(parts[1]) or 0,
                Time = tonumber(parts[2]) or 1,
                Slowdown = tonumber(parts[2]) or 0
            })
        end
    end
    return settings
end

Message(evt, function(msg)
    local channelId = msg.channel_id
    if channelId == nil 
    then
        return
    end

    local CachedKvExecutor = global.update(
        "AutoSlowdownKv",
        function() return kv.new(ctx) end, 
        function(v: kv.KvExecutor) return v end
    )
  
    local globalSetting = promise.yield(CachedKvExecutor:get("AutoSlowdownGlobal")) :: string?

    local settingsToUse = DefaultSettings
    if globalSetting ~= nil
    then
        settingsToUse = parseAutoslowdownSetting(globalSetting)
    end
    
    local reject: AutoSlowdownSetting? = nil;
    for _, setting in ipairs(settingsToUse) do
        -- Check for a bucket, creating it if it does not exist
        local ratelimiter = global.update(
            "AutoSlowdown:" .. settingToId(setting),
            function() return gcra.new(setting.MessageCount, setting.Time) :: gcra.RateLimiter<string>  end, 
            function(v: gcra.RateLimiter<string>) return v end
        )

        if ratelimiter:attemptAction(channelId) then
            if reject == nil or reject.Slowdown < setting.Slowdown then
                reject = setting
            end
        end
    end

    if reject ~= nil then
        updateSlowMode(channelId, reject.Slowdown, "AutoSlowdown")
    end
end)     
  