--channel.lua
local lclock_ms    = timer.clock_ms
local tinsert      = table.insert
local check_failed = hive.failed
local log_warn     = logger.warn
local log_err      = logger.err
local thread_mgr   = hive.get("thread_mgr")

local RPC_TIMEOUT  = hive.enum("NetwkTime", "RPC_CALL_TIMEOUT")

local Channel      = class()
local prop         = property(Channel)
prop:reader("title", "")
prop:reader("timeout", nil)
prop:reader("executers", {})    --执行器列表
prop:reader("status", false)

function Channel:__init(title, timeout)
    self.title   = title or "channel"
    self.timeout = timeout
end

function Channel:clear()
    self.executers = {}
end

function Channel:empty()
    return #self.executers == 0
end

--添加执行器
-- executer失败返回 false, err
-- executer成功返回 true, code, data
function Channel:push(executer)
    tinsert(self.executers, executer)
end

--执行
function Channel:execute(all_back)
    if self.status then
        log_err("[Channel][execute] repeat execute!!!", self.title)
        return
    end
    self.status     = true
    local btime     = lclock_ms()
    local all_datas = {}
    local count     = #self.executers
    if count == 0 then
        return true, all_datas
    end
    local success    = true
    local session_id = thread_mgr:build_session_id()
    for i, executer in ipairs(self.executers) do
        local efailed, code = false, 0
        thread_mgr:fork(function()
            local ok, corerr, data = executer()
            all_datas[i]           = data
            if not thread_mgr:try_response(session_id, ok, corerr) then
                efailed, code = check_failed(corerr, ok)
                count         = count - 1
                if efailed then
                    success = false
                end
            end
        end)
        if efailed and (not all_back) then
            log_err("[Channel][execute] failed:{},code:{}", self.title, code)
            return false, code
        end
    end
    while count > 0 do
        local sok, corerr   = thread_mgr:yield(session_id, self.title, RPC_TIMEOUT)
        local efailed, code = check_failed(corerr, sok)
        count               = count - 1
        if efailed then
            success = false
            if not all_back then
                log_err("[Channel][execute] async failed:{},code:{},{}", self.title, sok, corerr)
                return false, code
            end
        end
    end
    local cost_time = lclock_ms() - btime
    if self.timeout and cost_time > self.timeout then
        log_warn("[Channel][execute] timeout [{}] count:{},timeout:{} --> {}", self.title, #self.executers, self.timeout, cost_time)
    end
    return success, all_datas
end

return Channel
