# auto-slowdown

A plugin to automatically start and stop discord slowmode in a channel based on conditions. 

A condition can be set via AntiRaid templating key-value pairs using ``AutoSlowdown:Global`` for global conditions and ``AutoSlowdown:{channel_id}`` for channel specific conditions. Whitespace is ignored to allow for easier configuration.

## Configuration

**Format of strategy string: {strategy}={args} / {strategy}={args} / ...**

Strategy is:
- ``Interval`` for interval based slowdowns
- ``Rate`` for rate based slowdowns

### Interval

**Format: {SingleInterval}|{SingleInterval}...**

``SingleInterval: {Mode},{Mode.Opts}``

Modes: 

- ``Absolute: Absolute,{StartUnixTime},{StopUnixTime},{Slowdown}``
- ``TimePerDay: TimePerDay,{StartHours}[:]{StartMinutes}[:]{StartSeconds},{StopHours}[:]{StopMinutes}[:]{StopSeconds},{Timezone},{Slowdown}``

For example:

``TimePerDay,12:00:00,13:00:00,UTC,5`` will start slowmode every day of 5 seconds at 12:00:00 UTC and end it at 13:00:00 UTC

``TimePerDay,12:00:00,13:00:00,IST,10`` will start slowmode every day of 10 seconds at 12:00:00 IST and end it at 13:00:00 IST

``Absolute,1609459200,1609462800,5`` will start slowmode at Unix epoch 1609459200 and end it at Unix epoch 1609462800

### Rate

**Format: {Rate},{Rate}...**

``Rate: {MessageCount},{Time},{Slowdown}``

For example:

``5,10,7|10,10,5`` will start slowmode of 7 seconds at 5 messages per 10 seconds and 5 seconds at 10 messages per 10 seconds