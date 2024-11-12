local skynet = require "skynet"
local core = require "skynet.core"
require "skynet.manager"	-- import manager apis
local string = string

local services = {} -- 记录当前节点启动的服务, 键是服务地址(整型), 值是启动时的参数字符串
local command = {}
local instance = {} -- for confirm (function command.LAUNCH / command.ERROR / command.LAUNCHOK)
local launch_session = {} -- for command.QUERY, service_address -> session

-- 将 :12345 格式字符串转换成整型
local function handle_to_address(handle)
	return tonumber("0x" .. string.sub(handle , 2))
end

local NORET = {}

-- 返回当前已经启动的服务器列表, 键是服务器地址, 值是启动参数; 相当于 services 的一个副本
function command.LIST()
	local list = {}
	for k,v in pairs(services) do
		list[skynet.address(k)] = v
	end
	return list
end

local function list_srv(ti, fmt_func, ...)
	local list = {}
	local sessions = {}
	local req = skynet.request()
	for addr in pairs(services) do
		local r = { addr, "debug", ... }
		req:add(r)
		sessions[r] = addr
	end
	for req, resp in req:select(ti) do
		local addr = req[1]
		if resp then
			local stat = resp[1]
			list[skynet.address(addr)] = fmt_func(stat, addr)
		else
			list[skynet.address(addr)] = fmt_func("ERROR", addr)
		end
		sessions[req] = nil
	end
	for session, addr in pairs(sessions) do
		list[skynet.address(addr)] = fmt_func("TIMEOUT", addr)
	end
	return list
end

-- 得到各个服务的状态列表, 键是服务地址, 值是状态的 table
function command.STAT(addr, ti)
	return list_srv(ti, function(v) return v end, "STAT")
end

-- 关闭掉某个服务, 返回关闭服务的 table, 键是服务地址, 值是服务和其启动参数
function command.KILL(_, handle)
	skynet.kill(handle)
	local ret = { [skynet.address(handle)] = tostring(services[handle]) }
	services[handle] = nil
	return ret
end

-- 获得每个服务的内存信息, 返回 table 类型, 键是服务地址, 值是内存描述字符串
function command.MEM(addr, ti)
	return list_srv(ti, function(kb, addr)
		local v = services[addr]
		if type(kb) == "string" then
			return string.format("%s (%s)", kb, v)
		else
			return string.format("%.2f Kb (%s)",kb,v)
		end
	end, "MEM")
end

-- 执行垃圾回收, 返回 command.MEM() 的结果
function command.GC(addr, ti)
	for k,v in pairs(services) do
		skynet.send(k,"debug","GC")
	end
	return command.MEM(addr, ti)
end

-- 移除服务
function command.REMOVE(_, handle, kill)
	services[handle] = nil
	local response = instance[handle]
	if response then -- 这种情况是当在初始化未完成的时候会出现
		-- instance is dead
		response(not kill)	-- return nil to caller of newservice, when kill == false
		instance[handle] = nil
		launch_session[handle] = nil
	end

	-- don't return (skynet.ret) because the handle may exit
	return NORET
end

-- 启动服务, 返回启动的 handle
local function launch_service(service, ...)
	local param = table.concat({...}, " ")
	local inst = skynet.launch(service, param) -- 这个接口在 manager.lua 里面
	local session = skynet.context()
	local response = skynet.response()
	if inst then
		services[inst] = service .. " " .. param
		instance[inst] = response
		launch_session[inst] = session
	else
		response(false)
		return
	end
	return inst
end

function command.LAUNCH(_, service, ...)
	launch_service(service, ...)
	return NORET
end

-- 启动服务, 并且同时打开服务的日志文件
function command.LOGLAUNCH(_, service, ...)
	local inst = launch_service(service, ...)
	if inst then
		core.command("LOGON", skynet.address(inst))
	end
	return NORET
end

-- 错误处理, 一般会在 skynet.init_service 中调用
function command.ERROR(address)
	-- see serivce-src/service_lua.c
	-- init failed
	local response = instance[address]
	if response then
		response(false)
		launch_session[address] = nil
		instance[address] = nil
	end
	services[address] = nil
	return NORET
end

-- 创建服务成功, 一般会在 skynet.init_service 中调用
function command.LAUNCHOK(address)
	-- init notice
	local response = instance[address]
	if response then
		response(true, address)
		instance[address] = nil
		launch_session[address] = nil
	end

	return NORET
end

function command.QUERY(_, request_session)
	for address, session in pairs(launch_session) do
		if session == request_session then
			return address
		end
	end
end

-- for historical reasons, launcher support text command (for C service)

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	unpack = skynet.tostring,
	dispatch = function(session, address , cmd)
		if cmd == "" then
			command.LAUNCHOK(address)
		elseif cmd == "ERROR" then
			command.ERROR(address)
		else
			error ("Invalid text command " .. cmd)
		end
	end,
}

-- 注册 "lua" 类型消息的处理函数
skynet.dispatch("lua", function(session, address, cmd , ...)
	cmd = string.upper(cmd)
	-- skynet.newservice 中 调用了 skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
	-- 这里接收的cmd将会是 "LAUNCH" ，也就是会调用 command.LAUNCH
	local f = command[cmd]
	if f then
		local ret = f(address, ...)
		if ret ~= NORET then
			skynet.ret(skynet.pack(ret))
		end
	else
		skynet.ret(skynet.pack {"Unknown command"} )
	end
end)

skynet.start(function() end)
