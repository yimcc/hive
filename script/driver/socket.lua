--socket.lua
local ssub            = string.sub
local log_err         = logger.err
local log_info        = logger.info
local hxpcall         = hive.xpcall

local proto_text      = luabus.eproto_type.text
local thread_mgr      = hive.get("thread_mgr")

local CONNECT_TIMEOUT = hive.enum("NetwkTime", "CONNECT_TIMEOUT")
local NETWORK_TIMEOUT = hive.enum("NetwkTime", "NETWORK_TIMEOUT")

local Socket          = class()
local prop            = property(Socket)
prop:reader("ip", nil)
prop:reader("port", 0)
prop:reader("host", nil)
prop:reader("codec", nil)
prop:reader("token", nil)
prop:reader("alive", false)
prop:reader("session", nil)          --连接成功对象
prop:reader("listener", nil)
prop:reader("recvbuf", "")
prop:accessor("timeout", NETWORK_TIMEOUT)
prop:accessor("id", 0)

function Socket:__init(host, ip, port)
    self.host = host
    self.port = port
    self.ip   = ip
end

function Socket:__release()
    self:close()
end

function Socket:close()
    if self.session then
        self.session.close()
        self.alive   = false
        self.session = nil
        self.codec   = nil
        self.token   = nil
    end
end

function Socket:listen(ip, port, ptype)
    if self.listener then
        return true
    end
    self.listener = luabus.listen(ip, port, ptype or proto_text)
    if not self.listener then
        log_err("[Socket][listen] failed to listen: {}:{} type={}", ip, port, ptype)
        return false
    end
    self.ip, self.port = ip, port
    log_info("[Socket][listen] start listen at: {}:{} type={}", ip, port, ptype)
    self.listener.on_accept = function(session)
        hxpcall(self.on_socket_accept, "on_socket_accept: %s", self, session, ip, port)
    end
    return true
end

function Socket:set_codec(codec)
    if self.session then
        self.codec = codec
        self.session.set_codec(codec)
    end
    if self.listener then
        self.codec = codec
        self.listener.set_codec(codec)
    end
end

function Socket:connect(ip, port, ptype)
    if self.session then
        if self.alive then
            return true
        end
        return false, "socket in connecting"
    end
    local session, cerr = luabus.connect(ip, port, CONNECT_TIMEOUT, ptype or proto_text)
    if not session then
        log_err("[Socket][connect] failed to connect: {}:{} type={}, err={}", ip, port, ptype, cerr)
        return false, cerr
    end
    --设置阻塞id
    local block_id       = thread_mgr:build_session_id()
    session.on_connect   = function(res)
        local success = res == "ok"
        self.alive    = success
        if not success then
            self.token   = nil
            self.session = nil
        end
        thread_mgr:response(block_id, success, res)
    end
    session.on_call_data = function(recv_len, ...)
        self:on_socket_recv(session, ...)
    end
    session.on_error     = function(token, err)
        self:on_socket_error(token, err)
    end
    self.session         = session
    self.token           = session.token
    self.ip, self.port   = ip, port
    --阻塞模式挂起
    return thread_mgr:yield(block_id, "connect", CONNECT_TIMEOUT)
end

function Socket:on_socket_accept(session)
    local socket = Socket(self.host)
    socket:set_timeout(self.timeout)
    socket:accept(session, session.ip, self.port)
end

function Socket:on_socket_recv(session, ...)
    thread_mgr:fork(function(...)
        self.host:on_socket_recv(self, ...)
    end, ...)
end

function Socket:on_socket_error(token, err)
    thread_mgr:fork(function()
        if self.session then
            self.session = nil
            self.alive   = false
            self.host:on_socket_error(self, token, err)
            self.token = nil
        end
    end)
end

function Socket:accept(session, ip, port)
    session.set_timeout(self.timeout)
    session.on_call_data = function(recv_len, ...)
        self:on_socket_recv(session, ...)
    end
    session.on_error     = function(token, err)
        self:on_socket_error(token, err)
    end
    self.alive           = true
    self.session         = session
    self.token           = session.token
    self.ip, self.port   = ip, port
    self.host:on_socket_accept(self, self.token)
end

function Socket:peek(len, offset)
    offset = offset or 0
    if offset + len <= #self.recvbuf then
        return ssub(self.recvbuf, offset + 1, offset + len)
    end
end

function Socket:pop(len)
    if len > 0 then
        if #self.recvbuf > len then
            self.recvbuf = ssub(self.recvbuf, len + 1)
        else
            self.recvbuf = ""
        end
    end
end

function Socket:send(data)
    if self.alive and data then
        return self.session.call_text(data) > 0
    end
    log_err("[Socket][send] the socket not alive, can't send")
    return false
end

function Socket:send_data(...)
    if self.alive then
        local send_len = self.session.call_data(...)
        return send_len > 0
    end
    log_err("[Socket][send_data] the socket not alive, can't send")
    return false, "socket not alive"
end

return Socket
