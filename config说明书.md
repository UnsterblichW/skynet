启动 skynet 服务器需要提供一个配置文件，配置文件的编写可以参考 examples/config ，下面是一个简单的配置文件范例：

```lua
root = "./"
thread = 8
logger = nil
harbor = 1
address = "127.0.0.1:2526"
master = "127.0.0.1:2013"
start = "main"	-- main script
bootstrap = "snlua bootstrap"	-- The service for bootstrap
standalone = "0.0.0.0:2013"
luaservice = root.."service/?.lua;"..root.."test/?.lua;"..root.."examples/?.lua"
lualoader = "lualib/loader.lua"
snax = root.."examples/?.lua;"..root.."test/?.lua"
cpath = root.."cservice/?.so"
```

这个配置文件实际上就是一段 lua 代码，通常，我们以 key = value 的形式对配置项赋值。skynet 在启动时，会读取里面必要的配置项，并将暂时用不到的配置项以字符串形式保存在 skynet 内部的 env 表中。这些配置项可以通过 `skynet.getenv` 获取。

## 配置项
必要的配置项有：

* **thread** 启动多少个工作线程。通常不要将它配置超过你实际拥有的 CPU 核心数。
* **bootstrap** skynet 启动的第一个服务以及其启动参数。默认配置为 snlua bootstrap ，即启动一个名为 bootstrap 的 lua 服务。通常指的是 service/bootstrap.lua 这段代码。
* **cpath** 用 C 编写的服务模块的位置，通常指 cservice 下那些 .so 文件。如果你的系统的动态库不是以 .so 为后缀，需要做相应的修改。这个路径可以配置多项，以 ; 分割。

在默认的 bootstrap 代码中还会进一步用到一些配置项：

* **logger** 它决定了 skynet 内建的 `skynet_error` 这个 C API 将信息输出到什么文件中。如果 logger 配置为 nil ，将输出到标准输出。你可以配置一个文件名来将信息记录在特定文件中。
* **logservice** 默认为 "logger" ，你可以配置为你定制的 log 服务（比如加上时间戳等更多信息）。可以参考 `service_logger.c` 来实现它。注：如果你希望用 lua 来编写这个服务，可以在这里填写 snlua ，然后在 **logger** 配置具体的 lua 服务的名字。在 examples 目录下，有 config.userlog 这个范例可供参考。
* **logpath** 配置一个路径，当你运行时为一个服务打开 log 时，这个服务所有的输入消息都会被记录在这个目录下，文件名为服务地址。
* **standalone** 如果把这个 skynet 进程作为主进程启动（skynet 可以由分布在多台机器上的多个进程构成网络），那么需要配置standalone 这一项，表示这个进程是主节点，它需要开启一个控制中心，监听一个端口，让其它节点接入。
* **master** 指定 skynet 控制中心的地址和端口，如果你配置了 standalone 项，那么这一项通常和 standalone 相同。
* **address** 当前 skynet 节点的地址和端口，方便其它节点和它组网。注：即使你只使用一个节点，也需要开启控制中心，并额外配置这个节点的地址和端口。
* **harbor** 可以是 1-255 间的任意整数。一个 skynet 网络最多支持 255 个节点。每个节点有必须有一个唯一的编号。
* 如果 harbor 为 0 ，skynet 工作在单节点模式下。此时 **master** 和 **address** 以及 **standalone** 都不必设置。
* **start** 这是 bootstrap 最后一个环节将启动的 lua 服务，也就是你定制的 skynet 节点的主程序。默认为 main ，即启动 main.lua 这个脚本。这个 lua 服务的路径由下面的 **luaservice** 指定。
* **enablessl** 默认为空。如果需要通过 ltls 模块支持 https ，那么需要设置为 true 。

集群服务用到的配置项：

* **cluster** 它决定了集群配置文件的路径。

lua 服务由 snlua 提供，它会查找一些配置项以加载 lua 代码：

* **lualoader** 用哪一段 lua 代码加载 lua 服务。通常配置为 lualib/loader.lua ，再由这段代码解析服务名称，进一步加载 lua 代码。snlua 会将下面几个配置项取出，放在初始化好的 lua 虚拟机的全局变量中。具体可参考实现。
* **SERVICE_NAME** 第一个参数，通常是服务名。
* **LUA_PATH** config 文件中配置的 lua_path 。
* **LUA_CPATH** config 文件中配置的 lua_cpath 。
* **LUA_PRELOAD** config 文件中配置的 preload 。
* **LUA_SERVICE** config 文件中配置的 luaservice 。
* **luaservice** lua 服务代码所在的位置。可以配置多项，以 ; 分割。如果在创建 lua 服务时，以一个目录而不是单个文件提供，最终找到的路径还会被添加到 package.path 中。比如，在编写 lua 服务时，有时候会希望把该服务用到的库也放到同一个目录下。
* **lua_path** 将添加到 package.path 中的路径，供 require 调用。
* **lua_cpath** 将添加到 package.cpath 中的路径，供 require 调用。
* **preload** 在设置完 package 中的路径后，加载 lua 服务代码前，loader 会尝试先运行一个 preload 制定的脚本，默认为空。
* **snax** 用 snax 框架编写的服务的查找路径。
* **profile** 默认为 true, 可以用来统计每个服务使用了多少 cpu 时间。在 DebugConsole 中可以查看。会对性能造成微弱的影响，设置为 false 可以关闭这个统计。

另外，你也可以把一些配置选项配置在环境变量中。比如，你可以把 thread 配置在 `SKYNET_THREAD` 这个环境变量里。你可以在 config 文件中写：

```
thread=$SKYNET_THREAD
```
这样，在 skynet 启动时，就会用 `SKYNET_THREAD` 这个环境变量的值替换掉 config 中的 `$SKYNET_THREAD` 了。

## 后台模式

**daemon** 配置 daemon = "./skynet.pid" 可以以后台模式启动 skynet 。注意，同时请配置 logger 项输出 log 。