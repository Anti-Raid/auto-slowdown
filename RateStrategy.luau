local global = require "@antiraid-ext/global" 
local gcra = require "@antiraid-ext/gcra"
local discord = require "@discord-types/apiTypes"
local Primitives = require "@antiraid-core/primitives"

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

--- Parses a AutoSlowdown setting
---
--- Format: {MessageCount},{Time},{Slowdown}|{MessageCount},{Time},{Slowdown}...
local function parseAutoslowdownSetting(setting: string): {AutoSlowdownSetting}
    local settings = {}
    for _, setting in ipairs(string.split(setting, "|")) do
        local parts = string.split(setting, ",")
        if #parts == 3 then
            table.insert(settings, {
                MessageCount = tonumber(parts[1]) or 0,
                Time = tonumber(parts[2]) or 1,
                Slowdown = tonumber(parts[3]) or 0
            })
        end
    end
    return settings
end

return function(channelId: string, ctx: Primitives.TemplateContext, msg: discord.MessageObject, args: string): (number?, any)
    local settingsToUse = parseAutoslowdownSetting(args)
    
    local reject: AutoSlowdownSetting? = nil;
    for _, setting in ipairs(settingsToUse) do
        -- Check for a bucket, creating it if it does not exist
        local ratelimiter = global.update(
            "AutoSlowdown:" .. settingToId(setting),
            function() return gcra.new(setting.MessageCount, setting.Time) :: gcra.RateLimiter<string>  end, 
            function(v: gcra.RateLimiter<string>) return v end
        )

        if ratelimiter:attempt_action(channelId) then
            if reject == nil or reject.Slowdown < setting.Slowdown then
                reject = setting
            end
        end
    end

    if reject ~= nil then
        return reject.Slowdown, settingsToUse
    end

    return nil, settingsToUse
end    
  