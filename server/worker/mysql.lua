import("feature/worker.lua")

--启动worker
hive.startup(function()
    import("store/mysql_mgr.lua")
end)