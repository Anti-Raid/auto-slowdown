local discord = require "@antiraid/discord"
local promise = require "@antiraid/promise"
local global = require "@antiraid-ext/global" 
local Primitives = require "@antiraid-core/primitives"
local RateStrategy = require "./RateStrategy"
local IntervalStrategy = require "./IntervalStrategy"
local Message = require "@antiraid-ext/events/discord/Message"
local restTypes = require "@discord-types/restTypes"
local discordTypes = require "@discord-types/apiTypes"
  
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

type Strategy = (channelId: string, ctx: Primitives.TemplateContext, msg: discordTypes.MessageObject) -> number?

local UseStrategies: {Strategy} = {
    RateStrategy,
    IntervalStrategy
}

Message(evt, function(msg)
    local channelId = msg.channel_id
    
    if channelId == nil then
        return
    end

    local maxSlowdown: number = 0
    for _, strategy in ipairs(UseStrategies) do
        local slowdown = strategy(channelId, ctx, msg)
        if slowdown ~= nil then
            maxSlowdown = math.max(maxSlowdown, slowdown)
            break
        end
    end

    if maxSlowdown > 0 then
        updateSlowMode(channelId, maxSlowdown, "AutoSlowdown template")
    end
end)     
  