-- MSI MAG 322UPF + m1ddc + Hammerspoon.
-- PageDown returns to Windows; Ctrl+Shift+F11 is a backup.
local M = { busy = false, tasks = {}, timers = {}, autoConnect = false }
local log = hs.logger.new('MSI DeskSwitch', 'info')
hs.autoLaunch(true)
local candidates = {
    hs.configdir .. '/desk-switch-bin/m1ddc',
    '/opt/homebrew/bin/m1ddc',
    '/usr/local/bin/m1ddc'
}
local function executable()
    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path, 'mode') == 'file' then return path end
    end
end
local function notify(message)
    log.e(message)
    hs.alert.show(message)
end
local function run(args, callback)
    local binary = executable()
    if not binary then callback(127, '', 'Установи m1ddc: см. инструкцию DeskSwitch'); return end
    local task, timer
    task = hs.task.new(binary, function(code, out, err)
        if timer then timer:stop(); M.timers[timer] = nil end
        M.tasks[task] = nil
        callback(code, out, err)
    end, args)
    if not task then callback(127, '', 'Не удалось запустить m1ddc'); return end
    M.tasks[task] = true
    if not task:start() then
        M.tasks[task] = nil
        callback(127, '', 'Не удалось запустить m1ddc')
        return
    end
    timer = hs.timer.doAfter(8, function()
        if task:isRunning() then task:terminate() end
    end)
    M.timers[timer] = true
end
function M.switch(input)
    if M.busy then return end
    if input ~= 15 and input ~= 16 then return end
    M.busy = true
    if input == 15 then M.suppressAutoUntil = hs.timer.secondsSinceEpoch() + 30 end
    run({'display', 'list'}, function(code, out, err)
        if code ~= 0 then M.busy = false; notify('MSI: ' .. (err ~= '' and err or out)); return end
        local matches = {}
        for line in out:gmatch('[^\r\n]+') do
            local name, uuid = line:match('^%[%d+%]%s+(.+)%s+%(([%x%-]+)%)%s*$')
            if name and name:upper():gsub('%s+', ''):match('MAG322UPF') then
                matches[#matches + 1] = uuid
            end
        end
        if #matches ~= 1 then
            M.busy = false
            notify('Не найден единственный MSI MAG 322UPF. Подключи USB-C и разбуди Mac.')
            return
        end
        run({'display', matches[1], 'set', 'input', tostring(input)}, function(setCode, setOut, setErr)
            M.busy = false
            if setCode ~= 0 then notify('MSI: команда не прошла. ' .. setErr .. setOut)
            else log.i('Input command accepted: ' .. input) end
        end)
    end)
end
M.hotkey = hs.hotkey.bind({'ctrl', 'shift'}, 'F11', function() M.switch(15) end)
-- Switch on release to prevent a held key from reaching the other host.
M.pageDown = hs.hotkey.bind({}, 'pagedown', function() end, function() M.switch(15) end)
M.menu = hs.menubar.new()
M.menu:setTitle('Mac ↔ PC')
M.menu:setMenu(function()
    return {
        {title = 'Windows — PageDown', fn = function() M.switch(15) end},
        {title = 'Показать MacBook на MSI', fn = function() M.switch(16) end},
        {title = '-'},
        {title = 'Автовыбор Mac при подключении (после проверки)', checked = M.autoConnect,
         fn = function() M.autoConnect = not M.autoConnect end}
    }
end)
local function monitorPresent()
    for _, screen in ipairs(hs.screen.allScreens()) do
        if screen:name():upper():gsub('%s+', ''):match('MAG322UPF') then return true end
    end
    return false
end
M.present = monitorPresent()
M.screenWatcher = hs.screen.watcher.new(function()
    if M.debounce then M.debounce:stop() end
    M.debounce = hs.timer.doAfter(2, function()
        local present = monitorPresent()
        local arrived = present and not M.present
        M.present = present
        if arrived and M.autoConnect and hs.timer.secondsSinceEpoch() > (M.suppressAutoUntil or 0) then
            M.switch(16)
        end
    end)
end):start()
return M
