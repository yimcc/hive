local ReliableMsg = import("store/reliable_msg.lua")

local config_mgr  = hive.get("config_mgr")
local thread_mgr  = hive.get("thread_mgr")
local sformat     = string.format
local tjoin       = table_ext.join
local PeriodTime  = enum("PeriodTime")
local RmsgAgent   = singleton()
local prop        = property(RmsgAgent)
prop:accessor("rmsgs", {})

function RmsgAgent:__init()
    self:setup()
end

function RmsgAgent:setup()
    local rmsg_db = config_mgr:init_table("rmsg", "rmsg_type")
    for id, conf in rmsg_db:iterator() do
        self.rmsgs[id] = ReliableMsg(conf.db_name, conf.table_name, conf.due_days)
    end
end

function RmsgAgent:build_index(sharding)
    for _, rmsg in pairs(self.rmsgs or {}) do
        rmsg:build_index(sharding)
    end
end

function RmsgAgent:check_indexes(sharding)
    local success = true
    local miss    = {}
    for _, rmsg in pairs(self.rmsgs or {}) do
        local ok, res = rmsg:check_indexes(sharding)
        if not ok then
            miss    = tjoin(res, miss)
            success = false
        end
    end
    return success, miss
end

function RmsgAgent:lock_msg(rmsg_type, to)
    return thread_mgr:lock(sformat("RMSG:%s:%s", rmsg_type, to))
end

function RmsgAgent:list_message(rmsg_type, to)
    return self.rmsgs[rmsg_type]:list_message(to)
end

function RmsgAgent:safe_do_message(rmsg_type, to, do_func)
    local _lock<close> = self:lock_msg(rmsg_type, to)
    local records      = self:list_message(rmsg_type, to)
    for _, record in ipairs(records) do
        do_func(record)
        self:delete_message_by_uuid(rmsg_type, record.uuid, record.to)
    end
end

function RmsgAgent:send_message(rmsg_type, from, to, body, typ, id)
    return self.rmsgs[rmsg_type]:send_message(from, to, body, typ or rmsg_type, id)
end

function RmsgAgent:safe_send_message(rmsg_type, from, to, body, typ, id)
    local uuid = id or hive.new_guid()
    thread_mgr:success_call(PeriodTime.SECOND_10_MS, function()
        return self:send_message(rmsg_type, from, to, body, typ, uuid)
    end)
end

function RmsgAgent:delete_message(rmsg_type, to, timestamp)
    return self.rmsgs[rmsg_type]:delete_message(to, timestamp)
end

function RmsgAgent:delete_message_by_uuid(rmsg_type, uuid, to)
    return self.rmsgs[rmsg_type]:delete_message_by_uuid(uuid, to)
end

-- export
hive.rmsg_agent = RmsgAgent()

return RmsgAgent
