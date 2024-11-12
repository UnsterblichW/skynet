local service = require "skynet.service"
local skynet = require "skynet.manager"	-- import skynet.launch, ...

skynet.start(function()
	local standalone = skynet.getenv "standalone"
	--`skynet.launch(servicename, ...)` 用于启动一个 C 模块的服务。主要意思是 第一个参数是 c 模块的名字 可以是snlua logger 这种
	--snlua的创建分为两步 1.push一个启动消息给自己 2.处理启动消息并执行对应lua文件 属于异步
	local launcher = assert(skynet.launch("snlua","launcher"))
	skynet.name(".launcher", launcher)

	-- harbor 为 0, 表示就是启动 1 个单节点模式
	local harbor_id = tonumber(skynet.getenv "harbor" or 0)
	if harbor_id == 0 then
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")

		-- 单节点模式下，是不需要通过内置的 harbor 机制做节点中通讯的。
		-- 但为了兼容（因为你还是有可能注册全局名字），需要启动一个叫做 cdummy 的服务，它负责拦截对外广播的全局名字变更。
		local ok, slave = pcall(skynet.newservice, "cdummy")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)

	else
		-- 如果是多节点模式，对于 master 节点，需要启动 cmaster 服务作节点调度用。
		-- 对于 master 节点必须要配置 standalone 参数.
		if standalone then
			if not pcall(skynet.newservice,"cmaster") then
				skynet.abort()
			end
		end

		-- 此外，每个节点（包括 master 节点自己）都需要启动 cslave 服务，用于节点间的消息转发，以及同步全局名字。
		local ok, slave = pcall(skynet.newservice, "cslave")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	-- 如果当前包含 master, 则启动 DataCenter 服务
	-- datacenter 可用来在整个 skynet 网络做跨节点的数据共享。
	if standalone then
		local datacenter = skynet.newservice "datacenterd"
		skynet.name("DATACENTER", datacenter)
	end
	-- 启动用于 UniqueService 管理的 service_mgr, 启动这个服务的时候已经加载了 snax 模块
	skynet.newservice "service_mgr"

	local enablessl = skynet.getenv "enablessl"
	if enablessl == "true" then
		service.new("ltls_holder", function ()
			local c = require "ltls.init.c"
			c.constructor()
		end)
	end

	-- 启动用户定义的服务
	pcall(skynet.newservice,skynet.getenv "start" or "main")
	skynet.exit()
end)
