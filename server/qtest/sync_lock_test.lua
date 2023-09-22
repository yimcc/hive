local log_debug  = logger.debug

local thread_mgr = hive.get("thread_mgr")

function test_a(index, sync)
    local _lock<close> = thread_mgr:lock("sync_lock_test")
    if sync then
        thread_mgr:sleep(10)
    end
    log_debug("test_a:{}", index)
end

function test_b(index, sync)
    local _lock<close> = thread_mgr:lock("sync_lock_test")
    if sync then
        thread_mgr:sleep(10)
    end
    test_a(index, sync)
    log_debug("test_b:{}", index)
end

function test_c(index, sync)
    local _lock<close> = thread_mgr:lock("sync_lock_test")
    if sync then
        thread_mgr:sleep(10)
    end
    test_b(index, sync)
    log_debug("test_c:{}", index)
end

function test_loop_lock(index)
    log_debug("lock:{}", index)
    local _lock<close> = thread_mgr:lock("test_loop")
    if 1 == index then
        --模拟高并发阻塞下,协程锁队列唤醒
        thread_mgr:sleep(10)
    end
    log_debug("unlock:{}", index)
end

thread_mgr:fork(function()
    for i = 1, 10 do
        thread_mgr:fork(function()
            test_c(i)
        end)
    end
    thread_mgr:sleep(1000)
    for i = 1, 10 do
        thread_mgr:fork(function()
            test_c(i, true)
        end)
    end
    thread_mgr:fork(function()
        test_no_reentry(1)
    end)
    thread_mgr:fork(function()
        test_no_reentry(2)
    end)
--[[    for i = 1, 1000 do
        thread_mgr:fork(function()
            test_loop_lock(i)
        end)
    end]]
end)






