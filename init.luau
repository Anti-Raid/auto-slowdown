local discord = require "@antiraid/discord"
local promise = require "@antiraid/promise"
local global = require "@antiraid-ext/global" 
local executors = require "@antiraid-ext/executor" 
local Primitives = require "@antiraid-core/primitives"
local RateStrategy = require "./RateStrategy"
local IntervalStrategy = require "./IntervalStrategy"
local Message = require "@antiraid-ext/events/discord/Message"
local restTypes = require "@discord-types/restTypes"
local discordTypes = require "@discord-types/apiTypes"
local string_splitn = require "@antiraid-ext/strings/splitn"
  
local evt: Primitives.Event, ctx: Primitives.TemplateContext = ...

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function updateSlowMode(ge: executors.GlobalExecutor, channelId: string, seconds: number, reason: string)
    local lastSetSlowmode = global.get(
        "AutoSlowdownLastSet:" .. channelId
    )

    if lastSetSlowmode ~= nil and lastSetSlowmode == seconds then
        return -- We've already set this slow mode
    end

    -- Get the current slowmode
    local current_channel = promise.yield(ge.discord:get_channel({
        channel_id = channelId
    }))

    if current_channel.data.rate_limit_per_user == seconds then
        return
    end

    -- Set the last set slow mode
    ge.kv:set("AutoSlowdown:LastSlowMode_" .. channelId, current_channel.data.rate_limit_per_user)

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

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function revertSlowMode(ge: executors.GlobalExecutor, channelId: string, reason: string)
    -- Get the last set slow mode
    local lastSlowMode = ge.kv:get("AutoSlowdown:LastSlowMode_" .. channelId)

    if type(lastSlowMode) ~= "number" then
        return
    end

    -- Set the new slow mode to last slow mode
    global.set(
        "AutoSlowdownLastSet:" .. channelId,
        lastSlowMode
    )

    local discord_executor = discord.new(ctx);
    promise.yield(discord_executor:edit_channel({
        channel_id = channelId,
        reason = reason,
        data = {
            rate_limit_per_user = lastSlowMode :: number?
        } :: restTypes.ModifyChannelRequest
    }))
end

type ConfigString = {
    Strategy: string,
    Args: string
}

--- Format of strategy string: {strategy}={args} / {strategy}={args} / ...
local function ParseConfigString(config: string): {ConfigString}
    -- Remove whitespace
    config, _ = string.gsub(config, "%s+", "")
    local strategies = {}
    for _, strategy in ipairs(string.split(config, "/")) do
        local parts = string_splitn(strategy, "=", 1)
        if #parts == 2 then
            table.insert(strategies, {parts[1], parts[2]})
        end
    end
    return strategies
end

type Strategy = (channelId: string, ctx: Primitives.TemplateContext, msg: discordTypes.MessageObject, args: string) -> number?

local UseStrategies: {[string]: Strategy} = {
    Rate = RateStrategy,
    Interval = IntervalStrategy
}

Message(evt, function(msg)
    local channelId = msg.channel_id
    
    if channelId == nil then
        return
    end

    local ge = global.update(
        "AutoSlowdownGlobalExecutor",
        function() return executors.NewGlobalExecutor(ctx) end,
        function(v: executors.GlobalExecutor) return v end
    )
  
    local globalSetting = promise.yield(ge.kv:get("AutoSlowdown:Global")) :: string?
    local perChannelSetting = promise.yield(ge.kv:get("AutoSlowdown:" .. channelId)) :: string?

    local configOptions: {ConfigString} = {}

    if globalSetting ~= nil then
        local globalConfig = ParseConfigString(globalSetting)
        for _, config in ipairs(globalConfig) do
            table.insert(configOptions, config)
        end
    end

    if perChannelSetting ~= nil then
        local perChannelConfig = ParseConfigString(perChannelSetting)
        for _, config in ipairs(perChannelConfig) do
            table.insert(configOptions, config)
        end
    end

    local maxSlowdown: number? = nil
    for _, configOption in ipairs(configOptions) do
        local strategy = UseStrategies[configOption.Strategy] 

        if strategy == nil then
            continue
        end

        local slowdown = strategy(channelId, ctx, msg, configOption.Args)
        if slowdown ~= nil then
            if maxSlowdown ~= nil then
                maxSlowdown = math.max(maxSlowdown, slowdown)
            else 
                maxSlowdown = slowdown
            end

            break
        end
    end

    if maxSlowdown ~= nil then
        updateSlowMode(ge, channelId, maxSlowdown, "AutoSlowdown: set slow mode")
    else
        revertSlowMode(ge, channelId, "AutoSlowdown: revert slow mode")
    end
end)     
   