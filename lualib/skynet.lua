-- read https://github.com/cloudwu/skynet/wiki/FAQ for the module "skynet.core"
local c = require "skynet.core"
local skynet_require = require "skynet.require"
local tostring = tostring
local coroutine = coroutine
local assert = assert
local error = error
local pairs = pairs
local pcall = pcall
local table = table
local next = next
local tremove = table.remove
local tinsert = table.insert
local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback

local cresume = coroutine.resume
local running_thread = nil  -- 当前正在运行的协程（一个Lua虚拟机中，只会有1个协程处在 正在运行状态）
local init_thread = nil

-- 唤醒 co 这个协程，然后会把 running_thread 置为 co
local function coroutine_resume(co, ...)
	running_thread = co
	return cresume(co, ...)
end
local coroutine_yield = coroutine.yield
local coroutine_create = coroutine.create

local proto = {}
local skynet = {
	-- read skynet.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use skynet.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
	PTYPE_TRACE = 12,	-- use for debug trace
}

-- code cache , 在 service_snlua.c 中初始化
skynet.cache = require "skynet.codecache"
skynet._proto = proto

--[[
例如你可以注册一个以文本方式编码消息的消息类别。通常用 C 编写的服务更容易解析文本消息。
skynet 已经定义了这种消息类别为 skynet.PTYPE_TEXT，但默认并没有注册到 lua 中使用。

class = {
  name = "text",
  id = skynet.PTYPE_TEXT,
  pack = function(m) return tostring(m) end,
  unpack = skynet.tostring,
  dispatch = dispatch,	-- 下面说到的 dispatch 函数.
}

新的类别必须提供 pack 和 unpack 函数，用于消息的编码和解码。

pack 函数必须返回一个 string 或是一个 userdata 和 size。
在 Lua 脚本中，推荐你返回 string 类型，而用后一种形式需要对 skynet 底层有足够的了解（采用它多半是因为性能考虑，可以减少一些数据拷贝）。

unpack 函数接收一个 lightuserdata 和一个整数 。即上面提到的 message 和 size。
lua 无法直接处理 C 指针，所以必须使用额外的 C 库导入函数来解码。skynet.tostring 就是这样的一个函数，它将这个 C 指针和长度翻译成 lua 的 string。

接下来你可以使用 skynet.dispatch 注册 text 类别的处理方法了。当然，直接在 skynet.register_protocol 时传入 dispatch 函数也可以。
--]]

-- 在 skynet 中注册新的消息类别.
-- @param class 里面的字段参考上面的注释
-- @return nil
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil and proto[id] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

-- session 和 coroutine 的映射关系表, 键是 session, 值是 coroutine
-- 存在一种特殊情况, 当 wakeup 的时候, 存储的值是字符串 "BREAK"
-- 这个表用于一般需要等待其他服务回应信息的情况, 因为当其他服务回应信息的时候, 可以通过返回的 session 找到 coroutine, 然后恢复 coroutine 的执行.
local session_id_coroutine = {}

-- coroutine 和 session 的映射关系表, 键是 coroutine, 值是 session
-- 每次接收到非 response 类型消息的时候都会记录这个值.
local session_coroutine_id = {}

-- coroutine 和 address 的映射关系表, 键是 coroutine, 值是 address(整型)
-- 每次接收到非 response 类型消息的时候都会记录这个值.
local session_coroutine_address = {}

local session_coroutine_tracetag = {}

local unresponse = {}  -- 用来记录所有延迟的响应 在 "RESPONSE" 时, 存储还未发送响应数据的函数. 键是 response 函数, 值为 true

local wakeup_queue = {} -- 记录需要唤醒的 coroutine, 键是 coroutine, 值是 true
local sleep_session = {} -- 当前因 "SLEEP" 挂起的协程, 键是当前被阻塞的 coroutine, 值是 session

-- 监控的 session, 键是 session, 值是服务地址(整型)
-- 存储的 session 是需要回应的 session, 地址就是请求的服务器地址.
local watching_session = {}

-- 错误队列, 存放的是 session 的数组, 产生错误的 session 都放在此数组里面
local error_queue = {}

-- 通过 skynet.fork() 创建的 coroutine 的集合
-- h 表示 head， t 表示 tail 
local fork_queue = { h = 1, t = 0 } 

local auxsend, auxtimeout, auxwait
do ---- avoid session rewind conflict
	local csend = c.send
	local cintcommand = c.intcommand
	local dangerzone
	local dangerzone_size = 0x1000
	local dangerzone_low = 0x70000000
	local dangerzone_up	= dangerzone_low + dangerzone_size

	local set_checkrewind	-- set auxsend and auxtimeout for safezone
	local set_checkconflict -- set auxsend and auxtimeout for dangerzone

	local function reset_dangerzone(session)
		dangerzone_up = session
		dangerzone_low = session
		dangerzone = { [session] = true }
		for s in pairs(session_id_coroutine) do
			if s < dangerzone_low then
				dangerzone_low = s
			elseif s > dangerzone_up then
				dangerzone_up = s
			end
			dangerzone[s] = true
		end
		dangerzone_low = dangerzone_low - dangerzone_size
	end

	-- in dangerzone, we should check if the next session already exist.
	local function checkconflict(session)
		if session == nil then
			return
		end
		local next_session = session + 1
		if next_session > dangerzone_up then
			-- leave dangerzone
			reset_dangerzone(session)
			assert(next_session > dangerzone_up)
			set_checkrewind()
		else
			while true do
				if not dangerzone[next_session] then
					break
				end
				if not session_id_coroutine[next_session] then
					reset_dangerzone(session)
					break
				end
				-- skip the session already exist.
				next_session = c.genid() + 1
			end
		end
		-- session will rewind after 0x7fffffff
		if next_session == 0x80000000 and dangerzone[1] then
			assert(c.genid() == 1)
			return checkconflict(1)
		end
	end

	local function auxsend_checkconflict(addr, proto, msg, sz)
		local session = csend(addr, proto, nil, msg, sz)
		checkconflict(session)
		return session
	end

	local function auxtimeout_checkconflict(timeout)
		local session = cintcommand("TIMEOUT", timeout)
		checkconflict(session)
		return session
	end

	local function auxwait_checkconflict()
		local session = c.genid()
		checkconflict(session)
		return session
	end

	local function auxsend_checkrewind(addr, proto, msg, sz)
		local session = csend(addr, proto, nil, msg, sz)
		if session and session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	local function auxtimeout_checkrewind(timeout)
		local session = cintcommand("TIMEOUT", timeout)
		if session and session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	local function auxwait_checkrewind()
		local session = c.genid()
		if session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	set_checkrewind = function()
		auxsend = auxsend_checkrewind
		auxtimeout = auxtimeout_checkrewind
		auxwait = auxwait_checkrewind
	end

	set_checkconflict = function(session)
		reset_dangerzone(session)
		auxsend = auxsend_checkconflict
		auxtimeout = auxtimeout_checkconflict
		auxwait = auxwait_checkconflict
	end

	-- in safezone at the beginning
	set_checkrewind()
end

do ---- request/select
	local function send_requests(self)
		local sessions = {}
		self._sessions = sessions
		local request_n = 0
		local err
		for i = 1, #self do
			local req = self[i]
			local addr = req[1]
			local p = proto[req[2]]
			assert(p.unpack)
			local tag = session_coroutine_tracetag[running_thread]
			if tag then
				c.trace(tag, "call", 4)
				c.send(addr, skynet.PTYPE_TRACE, 0, tag)
			end
			local session = auxsend(addr, p.id , p.pack(tunpack(req, 3, req.n)))
			if session == nil then
				err = err or {}
				err[#err+1] = req
			else
				sessions[session] = req
				watching_session[session] = addr
				session_id_coroutine[session] = self._thread
				request_n = request_n + 1
			end
		end
		self._request = request_n
		return err
	end

	local function request_thread(self)
		while true do
			local succ, msg, sz, session = coroutine_yield "SUSPEND"
			if session == self._timeout then
				self._timeout = nil
				self.timeout = true
			else
				watching_session[session] = nil
				local req = self._sessions[session]
				local p = proto[req[2]]
				if succ then
					self._resp[session] = tpack( p.unpack(msg, sz) )
				else
					self._resp[session] = false
				end
			end
			skynet.wakeup(self)
		end
	end

	local function request_iter(self)
		return function()
			if self._error then
				-- invalid address
				local e = tremove(self._error)
				if e then
					return e
				end
				self._error = nil
			end
			local session, resp = next(self._resp)
			if session == nil then
				if self._request == 0 then
					return
				end
				if self.timeout then
					return
				end
				skynet.wait(self)
				if self.timeout then
					return
				end
				session, resp = next(self._resp)
			end

			self._request = self._request - 1
			local req = self._sessions[session]
			self._resp[session] = nil
			self._sessions[session] = nil
			return req, resp
		end
	end

	local request_meta = {}	; request_meta.__index = request_meta

	function request_meta:add(obj)
		assert(type(obj) == "table" and not self._thread)
		self[#self+1] = obj
		return self
	end

	request_meta.__call = request_meta.add

	function request_meta:close()
		if self._request > 0 then
			local resp = self._resp
			for session, req in pairs(self._sessions) do
				if not resp[session] then
					session_id_coroutine[session] = "BREAK"
					watching_session[session] = nil
				end
			end
			self._request = 0
		end
		if self._timeout then
			session_id_coroutine[self._timeout] = "BREAK"
			self._timeout = nil
		end
	end

	request_meta.__close = request_meta.close

	function request_meta:select(timeout)
		assert(self._thread == nil)
		self._thread = coroutine_create(request_thread)
		self._error = send_requests(self)
		self._resp = {}
		if timeout then
			self._timeout = auxtimeout(timeout)
			session_id_coroutine[self._timeout] = self._thread
		end

		local running = running_thread
		coroutine_resume(self._thread, self)
		running_thread = running
		return request_iter(self), nil, nil, self
	end

	function skynet.request(obj)
		local ret = setmetatable({}, request_meta)
		if obj then
			return ret(obj)
		end
		return ret
	end
end

-- suspend is function
local suspend

----- monitor exit

local function dispatch_error_queue()
	local session = tremove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false, nil, nil, session))
	end
end

local function _error_dispatch(error_session, error_source)
	skynet.ignoreret()	-- don't return for error
	if error_session == 0 then
		-- error_source is down, clear unreponse set
		for resp, address in pairs(unresponse) do
			if error_source == address then
				unresponse[resp] = nil
			end
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				tinsert(error_queue, session)
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			tinsert(error_queue, error_session)
		end
	end
end

-- coroutine reuse

local coroutine_pool = setmetatable({}, { __mode = "kv" })

--为了进一步提高性能，skynet对协程做了缓存，也就是说，一个协程在使用完以后，并不是让他结束掉，
--而是把上一次使用的dispatch函数清掉，并且挂起协程，放入一个协程池中，供下一次调用
--这个函数只是在创建协程、找到一个可用的协程，然后把任务函数 f 设置给这个协程来在未来执行，并没有直接执行任务函数f
local function co_create(f)
	local co = tremove(coroutine_pool)
	if co == nil then -- 协程池中，再也找不到可以用的协程时，将重新创建一个
		co = coroutine_create(function(...)
			-- 执行回调函数，创建协程时，并不会立即执行，
			-- 只有调用 coroutine.resume 时，才会执行内部逻辑，这行代码，只有在首次创建时会被调用
			f(...)

			-- 回调函数执行完，协程本次调用的使命就完成了，但是为了实现复用，这里不能让协程退出，
            -- 而是将upvalue回调函数f赋值为空，再放入协程缓存池中，并且挂起，以便下次使用
			while true do
				local session = session_coroutine_id[co]
				if session and session ~= 0 then
					local source = debug.getinfo(f,"S")
					skynet.error(string.format("Maybe forgot response session %s from %s : %s:%d",
						session,
						skynet.address(session_coroutine_address[co]),
						source.source, source.linedefined))
				end
				-- coroutine exit
				local tag = session_coroutine_tracetag[co]
				if tag ~= nil then
					if tag then c.trace(tag, "end")	end
					session_coroutine_tracetag[co] = nil
				end
				local address = session_coroutine_address[co]
				if address then
					session_coroutine_id[co] = nil
					session_coroutine_address[co] = nil
				end

				-- recycle co into pool
				f = nil  -- 上面调用f(...)的时候已经把任务处理完了，这里为了回收这个协程，所以需要把f置空
				coroutine_pool[#coroutine_pool+1] = co
				-- recv new main function f
				f = coroutine_yield "SUSPEND" -- 挂起当前协程，当协程再次被唤醒时，把传递进来的参数赋值给f
				f(coroutine_yield()) -- 可用的协程接收了新的任务函数f后，继续挂起，等待未来的某个时刻被 resume 唤醒
				-- 等到未来某个时刻被某个 resume 唤醒后， coroutine_yield() 会返回 resume 传经来的参数
				-- 也就类似于变成了 f(...) ，于是便可以执行任务了
			end
		end)
	else
		-- 发现协程池中有可用的协程
		-- pass the main function f to coroutine, and restore running thread
		local running = running_thread -- 保存调用co_create所在的协程
		-- 给这个从协程池中取出来的协程，重新设置新的任务函数，
		-- 也就是将会走到上面的分支 f = coroutine_yield "SUSPEND" 中
		-- 等号左边的 f 将会因协程被唤醒，而接收下面这句 coroutine_resume(co, f) 传入的新的f
		coroutine_resume(co, f)
		running_thread = running -- 已经给任务函数f找到了一个协程了，回到了调用co_create的所在的协程，这里需要重新恢复running_thread的值
	end
	return co
end

-- dispatch_wakeup主要的处理过程是这样:
-- 1.如果唤醒队列中有协程，转2; 如果没有转4
-- 2.取出一个，并唤醒执行。
-- 3.唤醒执行挂起后回到1
-- 4.dispatch_error_queue
-- 总而言之，会把 wakeup_queue 和 error_queue 里面的协程都取完之后才真正走完流程
local function dispatch_wakeup()
	while true do
		local token = tremove(wakeup_queue,1) --从唤醒队列中不断取出协程
		if token then
			local session = sleep_session[token]
			if session then
				local co = session_id_coroutine[session]
				local tag = session_coroutine_tracetag[co]
				if tag then c.trace(tag, "resume") end
				session_id_coroutine[session] = "BREAK"
				return suspend(co, coroutine_resume(co, false, "BREAK", nil, session))
			end
		else
			break
		end
	end
	return dispatch_error_queue()
end

-- suspend is local function
function suspend(co, result, command)
	if not result then
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				local tag = session_coroutine_tracetag[co]
				if tag then c.trace(tag, "error") end
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
		end
		session_coroutine_address[co] = nil
		session_coroutine_tracetag[co] = nil
		skynet.fork(function() end)	-- trigger command "SUSPEND"
		local tb = traceback(co,tostring(command))
		coroutine.close(co)
		error(tb)
	end
	if command == "SUSPEND" then  -- suspend这个函数一般是走到这里分支
		return dispatch_wakeup()
	elseif command == "QUIT" then
		coroutine.close(co)
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. traceback(co))
	end
end

local co_create_for_timeout
local timeout_traceback

function skynet.trace_timeout(on)
	local function trace_coroutine(func, ti)
		local co
		co = co_create(function()
			timeout_traceback[co] = nil
			func()
		end)
		local info = string.format("TIMER %d+%d : ", skynet.now(), ti)
		timeout_traceback[co] = traceback(info, 3)
		return co
	end
	if on then
		timeout_traceback = timeout_traceback or {}
		co_create_for_timeout = trace_coroutine
	else
		timeout_traceback = nil
		co_create_for_timeout = co_create
	end
end

skynet.trace_timeout(false)	-- turn off by default

-- 实际上是请求定时器线程往自己的队列添加一个消息。
-- 首先会向系统注册一个定时器，然后获取一个协程。
-- 当定时器触发时，通过定时器的session找到对应的协程，并执行这个协程。
function skynet.timeout(ti, func)
	local session = auxtimeout(ti) -- 会调用 skynet-src/skynet_server.c c层的函数 cmd_timeout
	assert(session)
	local co = co_create_for_timeout(func, ti)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
	return co	-- for debug
end

local function suspend_sleep(session, token)
	local tag = session_coroutine_tracetag[running_thread]
	if tag then c.trace(tag, "sleep", 2) end
	session_id_coroutine[session] = running_thread
	assert(sleep_session[token] == nil, "token duplicative")
	sleep_session[token] = session

	return coroutine_yield "SUSPEND"
end

function skynet.sleep(ti, token)
	local session = auxtimeout(ti)
	assert(session)
	token = token or coroutine.running()
	local succ, ret = suspend_sleep(session, token)
	sleep_session[token] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function skynet.yield()
	return skynet.sleep(0)
end

function skynet.wait(token)
	local session = auxwait()
	token = token or coroutine.running()
	suspend_sleep(session, token)
	sleep_session[token] = nil
	session_id_coroutine[session] = nil
end

function skynet.killthread(thread)
	local session
	-- find session
	if type(thread) == "string" then
		for k,v in pairs(session_id_coroutine) do
			local thread_string = tostring(v)
			if thread_string:find(thread) then
				session = k
				break
			end
		end
	else
		local t = fork_queue.t
		for i = fork_queue.h, t do
			if fork_queue[i] == thread then
				table.move(fork_queue, i+1, t, i)
				fork_queue[t] = nil
				fork_queue.t = t - 1
				return thread
			end
		end
		for k,v in pairs(session_id_coroutine) do
			if v == thread then
				session = k
				break
			end
		end
	end
	local co = session_id_coroutine[session]
	if co == nil then
		return
	end
	local addr = session_coroutine_address[co]
	if addr then
		session_coroutine_address[co] = nil
		session_coroutine_tracetag[co] = nil
		local session = session_coroutine_id[co]
		if session > 0 then
			c.send(addr, skynet.PTYPE_ERROR, session, "")
		end
		session_coroutine_id[co] = nil
	end
	if watching_session[session] then
		session_id_coroutine[session] = "BREAK"
		watching_session[session] = nil
	else
		session_id_coroutine[session] = nil
	end
	for k,v in pairs(sleep_session) do
		if v == session then
			sleep_session[k] = nil
			break
		end
	end
	coroutine.close(co)
	return co
end

function skynet.self()
	return c.addresscommand "REG"
end

function skynet.localname(name)
	return c.addresscommand("QUERY", name)
end

skynet.now = c.now
skynet.hpc = c.hpc	-- high performance counter

local traceid = 0
function skynet.trace(info)
	skynet.error("TRACE", session_coroutine_tracetag[running_thread])
	if session_coroutine_tracetag[running_thread] == false then
		-- force off trace log
		return
	end
	traceid = traceid + 1

	local tag = string.format(":%08x-%d",skynet.self(), traceid)
	session_coroutine_tracetag[running_thread] = tag
	if info then
		c.trace(tag, "trace " .. info)
	else
		c.trace(tag, "trace")
	end
end

function skynet.tracetag()
	return session_coroutine_tracetag[running_thread]
end

local starttime

function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

function skynet.exit()
	fork_queue = { h = 1, t = 0 }	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do
		local address = session_coroutine_address[co]
		if session~=0 and address then
			c.send(address, skynet.PTYPE_ERROR, session, "")
		end
	end
	for session, co in pairs(session_id_coroutine) do
		if type(co) == "thread" and co ~= running_thread then
			coroutine.close(co)
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.send(address, skynet.PTYPE_ERROR, 0, "")
	end
	c.callback(function(prototype, msg, sz, session, source)
		if session ~= 0 and source ~= 0 then
			c.send(source, skynet.PTYPE_ERROR, session, "")
		end
	end)
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

function skynet.getenv(key)
	return (c.command("GETENV",key))
end

function skynet.setenv(key, value)
	assert(c.command("GETENV",key) == nil, "Can't setenv exist key : " .. key)
	c.command("SETENV",key .. " " ..value)
end

-- 向其它服务发送消息
function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

function skynet.rawsend(addr, typename, msg, sz)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , msg, sz)
end

skynet.genid = assert(c.genid)

skynet.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack)
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

local function yield_call(service, session)
	watching_session[session] = service
	session_id_coroutine[session] = running_thread
	local succ, msg, sz = coroutine_yield "SUSPEND"
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

-- 同步发送消息 并阻塞等待回应	
function skynet.call(addr, typename, ...)
	local tag = session_coroutine_tracetag[running_thread]
	if tag then
		c.trace(tag, "call", 2)
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end

	local p = proto[typename]
	local session = auxsend(addr, p.id , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

function skynet.rawcall(addr, typename, msg, sz)
	local tag = session_coroutine_tracetag[running_thread]
	if tag then
		c.trace(tag, "call", 2)
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end
	local p = proto[typename]
	local session = assert(auxsend(addr, p.id , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

function skynet.tracecall(tag, addr, typename, msg, sz)
	c.trace(tag, "tracecall begin")
	c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	local p = proto[typename]
	local session = assert(auxsend(addr, p.id , msg, sz), "call to invalid address")
	local msg, sz = yield_call(addr, session)
	c.trace(tag, "tracecall end")
	return msg, sz
end

function skynet.ret(msg, sz)
	msg = msg or ""
	local tag = session_coroutine_tracetag[running_thread]
	if tag then c.trace(tag, "response") end
	local co_session = session_coroutine_id[running_thread]
	if co_session == nil then
		error "No session"
	end
	session_coroutine_id[running_thread] = nil
	if co_session == 0 then
		if sz ~= nil then
			c.trash(msg, sz)
		end
		return false	-- send don't need ret
	end
	local co_address = session_coroutine_address[running_thread]
	local ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, msg, sz)
	if ret then
		return true
	elseif ret == false then
		-- If the package is too large, returns false. so we should report error back
		c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
	end
	return false
end

function skynet.context()
	local co_session = session_coroutine_id[running_thread]
	local co_address = session_coroutine_address[running_thread]
	return co_session, co_address
end

function skynet.ignoreret()
	-- We use session for other uses
	session_coroutine_id[running_thread] = nil
end

-- 包装一个延迟响应
function skynet.response(pack)
	pack = pack or skynet.pack

	local co_session = assert(session_coroutine_id[running_thread], "no session")
	session_coroutine_id[running_thread] = nil
	local co_address = session_coroutine_address[running_thread]
	if co_session == 0 then
		--  do not response when session == 0 (send)
		return function() end
	end
	local function response(ok, ...)
		if ok == "TEST" then
			return unresponse[response] ~= nil
		end
		if not pack then
			error "Can't response more than once"
		end

		local ret
		if unresponse[response] then
			if ok then
				ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, pack(...))
				if ret == false then
					-- If the package is too large, returns false. so we should report error back
					c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
				end
			else
				ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
			unresponse[response] = nil
			ret = ret ~= nil
		else
			ret = false
		end
		pack = nil
		return ret
	end
	unresponse[response] = co_address

	return response
end

function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

function skynet.wakeup(token)
	if sleep_session[token] then
		tinsert(wakeup_queue, token)
		return true
	end
end

-- 注册特定类型消息的处理函数
function skynet.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

-- 从功能上，它等价于 skynet.timeout(0, function() func(...) end) 但是比 timeout 高效一点。因为它并不需要向框架注册一个定时器。
-- 这里有个小细节, 每次只有在接收到消息的时候才能执行 lua 代码, 而自定义的逻辑处理在 skynet.dispatch 时注册, 
-- 所以我们自己的代码只有在 skynet.dispatch 注册的函数内才会运行, 而在 dispatch 的代码执行结束后, 才会执行 fork 的相关代码, 不必担心 fork 协程会无法启动.
function skynet.fork(func,...)
	local n = select("#", ...)
	local co
	if n == 0 then
		co = co_create(func)
	else
		local args = { ... }
		co = co_create(function() func(table.unpack(args,1,n)) end)
	end
	local t = fork_queue.t + 1
	fork_queue.t = t
	fork_queue[t] = co
	return co
end

local trace_source = {}


-- 每个 skynet 服务，最重要的职责就是处理别的服务发送过来的消息，以及向别的服务发送消息。每条 skynet 消息由五个元素构成。
-- session ：大部分消息工作在请求回应模式下。即，一个服务向另一个服务发起一个请求，而后收到请求的服务在处理完请求消息后，回复一条消息。
-- 			 session 是由发起请求的服务生成的，对它自己唯一的消息标识。回应方在回应时，将 session 带回。这样发送方才能识别出哪条消息是针对哪条的回应。
--			 session 是一个非负整数，当一条消息不需要回应时，按惯例，使用 0 这个特殊的 session 号。session 由 skynet 框架生成管理，通常不需要使用者关心。
-- source ：消息源。每个服务都由一个 32bit 整数标识。这个整数可以看成是服务在 skynet 系统中的地址。
--			即使在服务退出后，新启动的服务通常也不会使用已用过的地址（除非发生回绕，但一般间隔时间非常长）。
--			每条收到的消息都携带有 source ，方便在回应的时候可以指定地址。但地址的管理通常由框架完成，用户不用关心。
-- type ：消息类别。每个服务可以接收 256 种不同类别的消息。每种类别可以有不同的消息编码格式。
--		  有十几种类别是框架保留的，通常也不建议用户定义新的消息类别。因为用户完全可以利用已有的类别，而用具体的消息内容来区分每条具体的含义。框架把这些 type 映射为字符串便于记忆。
--		  最常用的消息类别名为 "lua" 广泛用于用 lua 编写的 skynet 服务间的通讯。
-- message ：消息的 C 指针，在 Lua 层看来是一个 lightuserdata 。框架会隐藏这个细节，最终用户处理的是经过解码过的 lua 对象。只有极少情况，你才需要在 lua 层直接操作这个指针。
-- size ：消息的长度。通常和 message 一起结合起来使用。

-- 对于每个消息(非 response 类型)都会创建 1 协程, 用来专门的处理消息;
-- 对于 response 类型的消息, 会通过之前记录的 session 找到之前创建的协程, 然后恢复该协程的运行.
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then  --处理响应请求 别的服务响应当前服务
		local co = session_id_coroutine[session]
		if co == "BREAK" then -- 已经被强制 wakeup
			session_id_coroutine[session] = nil
		elseif co == nil then -- 无效的响应类型
			unknown_response(session, source, msg, sz)
		else
			local tag = session_coroutine_tracetag[co]
			if tag then c.trace(tag, "resume") end
			session_id_coroutine[session] = nil
			-- 开始或者继续挂起的协程(请求), 既然这里处理的是响应信息, 那么就可以理解为, 之前此服务的请求挂起了. 
			-- 使用计时器来举例: 这时才会运行之前注册的计时器处理函数, 这也就是为什么 "而 func 将来会在新的 coroutine 中执行" 的意思.
			-- 其实对于每个接收到的消息, 都会创建 1 个 coroutine 来处理.
			suspend(co, coroutine_resume(co, true, msg, sz, session))
		end
	else
		-- prototype 最常用的是 PTYPE_LUA
		local p = proto[prototype]
		if p == nil then -- 如果没有注册该类型
			if prototype == skynet.PTYPE_TRACE then
				-- trace next request
				trace_source[source] = c.tostring(msg,sz)
			elseif session ~= 0 then -- 如果需要回应, 则告诉请求服务发生错误
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else -- 如果不需要回应, 当前服务报告未知的请求类型
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end

		local f = p.dispatch
		if f then
			local co = co_create(f) -- 创建协程用来处理这次服务消息
			session_coroutine_id[co] = session -- 保存session以便找到回去的路，注意这里的session是其他服务独立产生的，所以不同的请求者，发来的session可以是相同的
			session_coroutine_address[co] = source -- 记录下当前的请求者是谁
			local traceflag = p.trace
			if traceflag == false then
				-- force off
				trace_source[source] = nil
				session_coroutine_tracetag[co] = false
			else
				local tag = trace_source[source]
				if tag then
					trace_source[source] = nil
					c.trace(tag, "request")
					session_coroutine_tracetag[co] = tag
				elseif traceflag then
					-- set running_thread for trace
					running_thread = co
					skynet.trace()
				end
			end
			-- 开始处理消息, f(session, source, p.unpack(msg, sz, ...))
			-- 开启 1 个新的协程去处理消息, 这样就不会导致当前接收消息这个主线程被阻塞
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))
		else
			-- 无效的请求
			trace_source[source] = nil
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, proto[prototype].name)
			end
		end
	end
end

function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do
		if fork_queue.h > fork_queue.t then
			-- queue is empty
			fork_queue.h = 1
			fork_queue.t = 0
			break
		end
		-- pop queue
		local h = fork_queue.h
		local co = fork_queue[h]
		fork_queue[h] = nil
		fork_queue.h = h + 1

		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
end

-- 启动一个lua服务，name为lua脚本名字,返回服务地址
-- 只有被启动的脚本的 start 函数返回后，这个 API 才会返回启动的服务的地址，这是一个阻塞 API 。
-- 如果被启动的脚本在初始化环节抛出异常，或在初始化完成前就调用 skynet.exit 退出，｀skynet.newservice` 都会抛出异常。
-- 如果被启动的脚本的 start 函数是一个永不结束的循环，那么 newservice 也会被永远阻塞住。
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

-- skynet.uniqueservice 和 skynet.newservice 的输入参数相同，都可以以一个脚本名称找到一段 lua 脚本并启动它，返回这个服务的地址。
-- 但和 newservice 不同，每个名字的脚本在同一个 skynet 节点只会启动一次。如果已有同名服务启动或启动中，后调用的人获得的是前一次启动的服务的地址。
-- 默认情况下，uniqueservice 是不跨节点的。也就是说，不同节点上调用 uniqueservice 即使服务脚本名相同，服务也会独立启动起来。
-- 如果你需要整个网络有唯一的服务，那么可以在调用 uniqueservice 的参数前加一个 true ，表示这是一个全局服务。
-- uniqueservice 采用的是惰性初始化的策略。整个系统中第一次调用时，服务才会被启动起来。
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

-- 来查询已有服务。如果这个服务不存在，这个 api 会一直阻塞到它启动好为止。
-- 对应的，查询服务 queryservice 也支持第一个参数为 true 的情况。
-- 这种全局服务，queryservice 更加有用。往往你需要明确知道一个全局服务部署在哪个节点上，以便于合理的架构。
function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

--  用于把一个地址数字转换为一个可用于阅读的字符串。
function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

-- 用于获得服务所属的节点。
function skynet.harbor(addr)
	return c.harbor(addr)
end

skynet.error = c.error
skynet.tracelog = c.trace

-- true: force on
-- false: force off
-- nil: optional (use skynet.trace() to trace one message)
function skynet.traceproto(prototype, flag)
	local p = assert(proto[prototype])
	p.trace = flag
end

----- register protocol
do
	local REG = skynet.register_protocol

	REG {
		name = "lua",
		id = skynet.PTYPE_LUA,
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

skynet.init = skynet_require.init
-- skynet.pcall is deprecated, use pcall directly
skynet.pcall = pcall

function skynet.init_service(start)
	local function main()
		skynet_require.init_all()
		start()
	end
	local ok, err = xpcall(main, traceback)
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK") --任何服务完成start后，都会发送 LAUNCHOK 消息 给到 launcher 服务
	end
end

--这个函数，首先lua服务注册了一个lua层的消息回调函数，
--前面已经讨论过，一个c服务在消费次级消息队列的消息时，最终会调用callback函数，
--而这里做的工作则是，通过这个c层的callback函数，再转调lua层消息回调函数skynet.dispatch_message

-- 注册一个函数为这个服务的启动函数。当然你还是可以在脚本中随意写一个 Lua 代码，它们会先于 start 函数执行。
-- 但是，不要在外面调用 skynet 的阻塞 API ，因为框架将无法唤醒它们。
function skynet.start(start_func)
	c.callback(skynet.dispatch_message) --c层的函数，就是 lualib-src/lua-skynet.c   static int lcallback(lua_State *L)
	init_thread = skynet.timeout(0, function()
		skynet.init_service(start_func)
		init_thread = nil
	end)
end

function skynet.endless()
	return (c.intcommand("STAT", "endless") == 1)
end

function skynet.mqlen()
	return c.intcommand("STAT", "mqlen")
end

function skynet.stat(what)
	return c.intcommand("STAT", what)
end

local function task_traceback(co)
	if co == "BREAK" then
		return co
	elseif timeout_traceback and timeout_traceback[co] then
		return timeout_traceback[co]
	else
		return traceback(co)
	end
end

function skynet.task(ret)
	if ret == nil then
		local t = 0
		for _,co in pairs(session_id_coroutine) do
			if co ~= "BREAK" then
				t = t + 1
			end
		end
		return t
	end
	if ret == "init" then
		if init_thread then
			return traceback(init_thread)
		else
			return
		end
	end
	local tt = type(ret)
	if tt == "table" then
		for session,co in pairs(session_id_coroutine) do
			local key = string.format("%s session: %d", tostring(co), session)
			ret[key] = task_traceback(co)
		end
		return
	elseif tt == "number" then
		local co = session_id_coroutine[ret]
		if co then
			return task_traceback(co)
		else
			return "No session"
		end
	elseif tt == "thread" then
		for session, co in pairs(session_id_coroutine) do
			if co == ret then
				return session
			end
		end
		return
	end
end

function skynet.uniqtask()
	local stacks = {}
	for session, co in pairs(session_id_coroutine) do
		local stack = task_traceback(co)
		local info = stacks[stack] or {count = 0, sessions = {}}
		info.count = info.count + 1
		if info.count < 10 then
			info.sessions[#info.sessions+1] = session
		end
		stacks[stack] = info
	end
	local ret = {}
	for stack, info in pairs(stacks) do
		local count = info.count
		local sessions = table.concat(info.sessions, ",")
		if count > 10 then
			sessions = sessions .. "..."
		end
		local head_line = string.format("%d\tsessions:[%s]\n", count, sessions)
		ret[head_line] = stack
	end
	return ret
end

function skynet.term(service)
	return _error_dispatch(0, service)
end

function skynet.memlimit(bytes)
	debug.getregistry().memlimit = bytes
	skynet.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "skynet.debug"
debug.init(skynet, {
	dispatch = skynet.dispatch_message,
	suspend = suspend,
	resume = coroutine_resume,
})

return skynet
