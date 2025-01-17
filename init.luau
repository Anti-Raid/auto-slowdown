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

type CachedData = {
    CurrentlySetSlowMode: number?,
    PreviouslySetSlowMode: number?
}

-- Format: {CurrentlySetSlowMode},{PreviouslySetSlowMode}
local function _getCachedData(ge: executors.GlobalExecutor, channelId: string): CachedData
    local cachedData = promise.yield(ge.kv:get("AutoSlowdownCache:" .. channelId)) :: string?

    if cachedData == nil then
        return {
            CurrentlySetSlowMode = nil,
            PreviouslySetSlowMode = nil
        }
    end

    local parts = string.split(cachedData, ",")
    if #parts ~= 2 then
        return {
            CurrentlySetSlowMode = nil,
            PreviouslySetSlowMode = nil
        }
    end

    local currentlySetSlowMode = tonumber(parts[1]) :: number?
    local previouslySetSlowMode = tonumber(parts[2]) :: number?

    if currentlySetSlowMode == -1 then
        currentlySetSlowMode = nil
    end

    if previouslySetSlowMode == -1 then
        previouslySetSlowMode = nil
    end

    return {
        CurrentlySetSlowMode = currentlySetSlowMode,
        PreviouslySetSlowMode = previouslySetSlowMode
    }
end

local function _setCachedData(ge: executors.GlobalExecutor, channelId: string, ce: CachedData)
    promise.yield(ge.kv:set("AutoSlowdownCache:" .. channelId, tostring(ce.CurrentlySetSlowMode or -1) .. "," .. tostring(ce.PreviouslySetSlowMode or -1)))
end

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function updateSlowMode(ge: executors.GlobalExecutor, channelId: string, seconds: number, reason: string)
    -- Get autoslowmode cached data
    local cachedData = _getCachedData(ge, channelId)
    
    if cachedData.CurrentlySetSlowMode == seconds then
        return -- The currently set slow mode is the same as the current slow mode thats being requested to be set
    end

    -- Get the current slowmode
    local current_channel = promise.yield(ge.discord:get_channel({
        channel_id = channelId
    }))

    cachedData.PreviouslySetSlowMode = current_channel.data.rate_limit_per_user or 0
    cachedData.CurrentlySetSlowMode = seconds

    -- Check if the channel is same as the slowmode, if so, set cached data and exit
    if current_channel.data.rate_limit_per_user == seconds then
        _setCachedData(ge, channelId, cachedData) -- Update the cached data in this case before exiting
        return
    end

    local discord_executor = discord.new(ctx);
    promise.yield(discord_executor:edit_channel({
        channel_id = channelId,
        reason = reason,
        data = {
            rate_limit_per_user = seconds :: number?
        } :: restTypes.ModifyChannelRequest
    }))

    _setCachedData(ge, channelId, cachedData) -- Update the cached data
end

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function revertSlowMode(ge: executors.GlobalExecutor, channelId: string, reason: string)
    -- Get autoslowmode cached data
    local cachedData = _getCachedData(ge, channelId)

    if cachedData.CurrentlySetSlowMode == nil then
        return -- We don't have any currently set slowmode to revert to?
    end

    cachedData.CurrentlySetSlowMode = -1; -- -1 is internally seen as nil for the cache stuff

    local discord_executor = discord.new(ctx);
    promise.yield(discord_executor:edit_channel({
        channel_id = channelId,
        reason = reason,
        data = {
            rate_limit_per_user = cachedData.PreviouslySetSlowMode or 0
        } :: restTypes.ModifyChannelRequest
    }))

    _setCachedData(ge, channelId, cachedData) -- Update the cached data
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
            table.insert(strategies, {Strategy = parts[1], Args = parts[2]})
        end
    end
    return strategies
end

type Strategy = (channelId: string, ctx: Primitives.TemplateContext, msg: discordTypes.MessageObject, args: string) -> (number?, any)

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

    if msg.content == "AutoSlowdown:Debug" then
        local serde = require"@lune/serde" 
        local interop = require"@antiraid/interop"
        local strategyResults = {} :: { { Strategy: string, Args: string, Result: number? } }

        for _, configOption in ipairs(configOptions) do
            local strategy = UseStrategies[configOption.Strategy] 

            if strategy == nil then
                continue
            end

            local slowdown, output = strategy(channelId, ctx, msg, configOption.Args)
            table.insert(strategyResults, {
                Strategy = configOption.Strategy,
                Args = configOption.Args,
                Result = slowdown or interop.null,
                Output = output or interop.null,
                Now = os.time()
            })
        end

        promise.yield(ge.discord:create_message({
            channel_id = channelId,
            data = {
                content = ("AutoSlowdown:Debug\n" .. "Global: " .. tostring(globalSetting) .. "\nPerChannel: " .. tostring(perChannelSetting) .. "\nConfigOptions: " .. serde.encode("json", configOptions) .. "\nResults: " .. serde.encode("json", strategyResults)) :: string?
            }
        }))
        return
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
        end
    end

    if maxSlowdown ~= nil then
        updateSlowMode(ge, channelId, maxSlowdown, "AutoSlowdown: set slow mode")
    else
        revertSlowMode(ge, channelId, "AutoSlowdown: revert slow mode")
    end
end)     
   