local discord = require "@antiraid/discord"
local promise = require "@antiraid/promise"
local global = require "@antiraid-ext/global" 
local executors = require "@antiraid-ext/executor" 
local Primitives = require "@antiraid-core/primitives"
local RateStrategy = require "./RateStrategy"
local IntervalStrategy = require "./IntervalStrategy"
local Message = require "@antiraid-ext/events/discord/Message"
local ExternalKeyUpdate = require "@antiraid-ext/events/antiraid/ExternalKeyUpdate"
local restTypes = require "@discord-types/restTypes"
local discordTypes = require "@discord-types/apiTypes"
local string_splitn = require "@antiraid-ext/strings/splitn"
  
local evt: Primitives.Event, ctx: Primitives.TemplateContext = ...

type CachedData = {
    CurrentlySetSlowMode: number,
    PreviouslySetSlowMode: number
}

-- Format: {CurrentlySetSlowMode},{PreviouslySetSlowMode}
local function _getCachedData(ge: executors.GlobalExecutor, channelId: string): CachedData
    -- Check globals
    local globalCachedData: {[string]: CachedData} = global.get("AutoSlowdownCache")

    if globalCachedData ~= nil then
        local tab = globalCachedData[channelId]

        if tab == nil then
            tab = {
                CurrentlySetSlowMode = -1,
                PreviouslySetSlowMode = -1
            } :: CachedData
            globalCachedData[channelId] = tab
        end

        return tab
    end

    -- Fetch from KV
    local cachedData = promise.yield(ge.kv:get("AutoSlowdownCache")) :: {[string]: CachedData}?

    if cachedData == nil then
        local tab = {
            CurrentlySetSlowMode = -1,
            PreviouslySetSlowMode = -1
        }
        global.set("AutoSlowdownCache", {
            [channelId] = tab
        })
        return tab
    end

    local tab = cachedData[channelId]

    if tab == nil then
        tab = {
            CurrentlySetSlowMode = -1,
            PreviouslySetSlowMode = -1
        } :: CachedData
        cachedData[channelId] = tab
    end

    global.set("AutoSlowdownCache", cachedData) -- Save the data back to globals

    return tab
end

local function _setCachedData(ge: executors.GlobalExecutor)
    local cachedData = global.get("AutoSlowdownCache") :: {[string]: CachedData}

    if cachedData == nil then
        return
    end

    promise.yield(ge.kv:set("AutoSlowdownCache", cachedData))
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
        _setCachedData(ge) -- Update the cached data in this case before exiting
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

    _setCachedData(ge) -- Update the cached data
end

--- Update the slow mode of a channel. Seconds must be between 0 and 21600
---
--- @param channelId The ID of the channel to update
local function revertSlowMode(ge: executors.GlobalExecutor, channelId: string, reason: string)
    -- Get autoslowmode cached data
    local cachedData = _getCachedData(ge, channelId)

    if cachedData.CurrentlySetSlowMode == -1 then
        return -- We don't have any currently set slowmode to revert to?
    end

    cachedData.CurrentlySetSlowMode = -1; -- -1 is internally seen as nil for the cache stuff

    local prevSlowMode = cachedData.PreviouslySetSlowMode
    if prevSlowMode == -1 then
        prevSlowMode = 0
    end

    local discord_executor = discord.new(ctx);
    promise.yield(discord_executor:edit_channel({
        channel_id = channelId,
        reason = reason,
        data = {
            rate_limit_per_user = prevSlowMode
        } :: restTypes.ModifyChannelRequest
    }))

    _setCachedData(ge) -- Update the cached data
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

--- Returns the config string for a given key, while handling caching
local function _getConfigString(ge: executors.GlobalExecutor, key: string): (string?, boolean)
    local cachedValueStore = global.update("AutoSlowdownConfigCache", function() return {} end, function(v: {[string]: { Args: string? }}) return v end)
    
    local cachedValue = cachedValueStore[key]

    if cachedValue ~= nil then
        return cachedValue.Args, true -- This may be nil but we know its cached
    end

    local value = promise.yield(ge.kv:get(key)) :: string?

    cachedValueStore[key] = { Args = value }
    return value, false
end

ExternalKeyUpdate(evt, function(data) 
    -- Drop the key if it matches the prefix
    if string.sub(data.key_modified, 1, 13) == "AutoSlowdown:" then
        local cachedValueStore = global.update("AutoSlowdownConfigCache", function() return {} end, function(v: {[string]: { Args: string? }}) return v end)
        cachedValueStore[data.key_modified] = nil -- Nil out the cache
        return
    end
end)

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

    local globalSetting, isGlobalSettingCached = _getConfigString(ge, "AutoSlowdown:Global")
    local perChannelSetting, isPerChannelSettingCached = _getConfigString(ge, "AutoSlowdown:" .. channelId)
  
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

        local cachedValueStore = global.update("AutoSlowdownConfigCache", function() return {} end, function(v: {[string]: { Args: string? }}) return v end)
        promise.yield(ge.discord:create_message({
            channel_id = channelId,
            data = {
                content = ("AutoSlowdown:Debug\n" .. "Global: " .. tostring(globalSetting) .. "\nPerChannel: " .. tostring(perChannelSetting) .. "\nConfigOptions: " .. serde.encode("json", configOptions) .. "\nResults: " .. serde.encode("json", strategyResults) .. "\nCachedData: " .. serde.encode("json", cachedValueStore) .. "\nCacheStatus: " .. serde.encode("json", { global = isGlobalSettingCached, [channelId] = isPerChannelSettingCached})) :: string?
            }
        }))

        -- Clear the cache too
        --table.clear(cachedValueStore :: any)
        return
    end

    local maxSlowdown: number? = nil
    for _, configOption in ipairs(configOptions) do
        local strategy = UseStrategies[configOption.Strategy] 

        if strategy == nil then
            continue
        end

        local slowdown, _ = strategy(channelId, ctx, msg, configOption.Args)
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
   