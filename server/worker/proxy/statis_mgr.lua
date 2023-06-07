--statis_mgr.lua
local LinuxStatis = import("kernel/object/linux.lua")
local InfluxDB    = import("driver/influx.lua")

local tsort       = table.sort
local tremove_out = table_ext.tremove_out
local tkvarray    = table_ext.kvarray
local log_warn    = logger.warn

local env_get     = environ.get
local env_addr    = environ.addr
local event_mgr   = hive.get("event_mgr")
local update_mgr  = hive.get("update_mgr")

local StatisMgr   = singleton()
local prop        = property(StatisMgr)
prop:reader("influx", nil)              --influx
prop:reader("statis", {})               --statis
prop:reader("statis_status", false)     --统计开关
prop:reader("linux_statis", nil)
prop:reader("local_counts", {})         --本地计数

function StatisMgr:__init()
    local statis_status = environ.status("HIVE_STATIS")
    if statis_status then
        self.statis_status = statis_status
        --事件监听
        event_mgr:add_listener(self, "on_rpc_send")
        event_mgr:add_listener(self, "on_rpc_recv")
        event_mgr:add_listener(self, "on_perfeval")
        event_mgr:add_listener(self, "on_proto_recv")
        event_mgr:add_listener(self, "on_proto_send")
        event_mgr:add_listener(self, "on_conn_update")
        --定时处理
        update_mgr:attach_second(self)
        update_mgr:attach_minute(self)
        update_mgr:attach_hour(self)

        --系统监控
        if hive.is_linux() then
            self.linux_statis = LinuxStatis()
        end
        --influx
        self:init_influx()
    end
    self.local_counts = { recv_msg = {}, send_msg = {}, recv_rpc = {}, send_rpc = {} }
end

function StatisMgr:init_influx()
    --初始化参数
    if not environ.status("HIVE_INFLUX_OPEN") then
        return
    end
    local org      = env_get("HIVE_INFLUX_ORG")
    local token    = env_get("HIVE_INFLUX_TOKEN")
    local bucket   = env_get("HIVE_INFLUX_BUCKET")
    local ip, port = env_addr("HIVE_INFLUX_ADDR")
    if ip and port then
        self.influx = InfluxDB(ip, port, org, bucket, token)
    end
end

-- 发送给influx
function StatisMgr:flush()
    local statis = self.statis
    self.statis  = {}
    if self.influx and next(statis) then
        self.influx:batch(statis)
    end
end

-- 发送给influx
function StatisMgr:write(measurement, name, type, fields)
    local measure = self.statis[measurement]
    if not measure then
        measure                  = {
            tags       = {
                name    = name,
                type    = type,
                index   = hive.index,
                service = hive.service_name
            },
            field_list = {}
        }
        self.statis[measurement] = measure
    end
    measure.field_list[#measure.field_list + 1] = fields
end

-- 统计proto协议发送(KB)
function StatisMgr:on_proto_recv(cmd_id, recv_len)
    if self.statis_status then
        local fields = { count = recv_len }
        self:write("network", cmd_id, "proto_recv", fields)
    end
    self:add_local_count("recv_msg", cmd_id, recv_len)
end

-- 统计proto协议接收(KB)
function StatisMgr:on_proto_send(cmd_id, send_len)
    if self.statis_status then
        local fields = { count = send_len }
        self:write("network", cmd_id, "proto_send", fields)
    end
    self:add_local_count("send_msg", cmd_id, send_len)
end

-- 统计rpc协议发送(KB)
function StatisMgr:on_rpc_send(rpc, send_len)
    if self.statis_status then
        local fields = { count = send_len }
        self:write("network", rpc, "rpc_send", fields)
    end
    self:add_local_count("send_rpc", rpc, send_len)
end

-- 统计rpc协议接收(KB)
function StatisMgr:on_rpc_recv(rpc, recv_len)
    if self.statis_status then
        local fields = { count = recv_len }
        self:write("network", rpc, "rpc_recv", fields)
    end
    self:add_local_count("recv_rpc", rpc, recv_len)
end

-- 统计cmd协议连接
function StatisMgr:on_conn_update(conn_type, conn_count)
    if self.statis_status then
        local fields = { count = conn_count }
        self:write("network", conn_type, "conn", fields)
    end
end

-- 统计性能
function StatisMgr:on_perfeval(eval_name, fields)
    if self.statis_status then
        if fields.total_time > 1 then
            self:write("perfeval", eval_name, nil, fields)
        end
    end
end

function StatisMgr:on_second()
    self:flush()
end

-- 统计系统信息
function StatisMgr:on_minute()
    if self.statis_status then
        local fields = {
            all_mem  = self:_calc_mem_use(),
            lua_mem  = self:_calc_lua_mem(),
            cpu_rate = self:_calc_cpu_rate(),
        }
        self:write("system", nil, nil, fields)
        self:flush()
    end
end

function StatisMgr:on_hour()
    self:report_msg_count()
end

-- 计算lua内存信息(KB)
function StatisMgr:_calc_lua_mem()
    return collectgarbage("count")
end

-- 计算内存信息(KB)
function StatisMgr:_calc_mem_use()
    if hive.is_linux() then
        return self.linux_statis:calc_memory()
    end
    return 0
end

-- 计算cpu使用率
function StatisMgr:_calc_cpu_rate()
    if hive.is_linux() then
        return self.linux_statis:calc_cpu_rate()
    end
    return 0.1
end

-- 添加本地计数
function StatisMgr:add_local_count(name, cmd, len)
    local recv_msg = self.local_counts[name][cmd]
    if not recv_msg then
        self.local_counts[name][cmd] = { count = 1, len = len }
    else
        recv_msg.count = recv_msg.count + 1
        recv_msg.len   = recv_msg.len + len
    end
end

-- 打印分析日志
function StatisMgr:report_msg_count()
    for k, v in pairs(self.local_counts) do
        local msgs = tkvarray(v)
        tsort(msgs, function(a, b)
            if a[2].len == b[2].len then
                return a[2].count > b[2].count
            end
            return a[2].len > b[2].len
        end)
        tremove_out(msgs, 10, true)
        if #msgs > 0 then
            log_warn("top msg:%s,%s", k, msgs)
        end
    end
end

hive.statis_mgr = StatisMgr()

return StatisMgr
