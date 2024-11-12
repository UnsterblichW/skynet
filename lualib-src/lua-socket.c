#define LUA_LIB

#include "skynet_malloc.h"

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>

#include <lua.h>
#include <lauxlib.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>

#include "skynet.h"
#include "skynet_socket.h"

#define BACKLOG 32	// 默认的 listen 的 backlog 参数
// 2 ** 12 == 4096
#define LARGE_PAGE_NODE 12		// 决定分配缓存数据块的最大数量, 2 的次方
#define POOL_SIZE_WARNING 32
#define BUFFER_LIMIT (256 * 1024)

// 缓存节点, buffer_node 是不会被删除掉的, 除非所在的 lua 虚拟机 close 了, 这时 buffer_node 的内存资源才会被回收.
// 在使用过程中, 都是对 msg 指向的内容做操作.
struct buffer_node {
	char * msg;	// 数据指针
	int sz;	// 数据大小
	struct buffer_node *next;	// 关联的下一个节点
};

/// socket 数据缓存, 队列数据结构, 这里保存的 buffer_node 都是引用可用数据的
struct socket_buffer {
	int size;		// 当前链表存储数据的总大小
	int offset;		// 当前正在读取的 buffer_node 的指针偏移量, 因为可能存在当前的 buffer_node 的数据只读取了部分的情况, 所以需要记录已经被读取的内容
	struct buffer_node *head;	// 指向队列头元素的指针
	struct buffer_node *tail;	// 指向队列尾元素的指针
};

/**
 * 函数作用: 释放一组 buffer_node 资源.
 * lua: 接收 1 个参数, 0 个返回值
 */
static int
lfreepool(lua_State *L) {
	// 获取第一个参数, userdata类型(struct buffer_node, 通过 lnewpool)分配
	struct buffer_node * pool = lua_touserdata(L, 1);

	// 返回给定索引处值的固有“长度”： 
	// 1. 对于字符串，它指字符串的长度； 
	// 2. 对于表；它指不触发元方法的情况下取长度操作（'#'）应得到的值；
	// 3. 对于用户数据，它指为该用户数据分配的内存块的大小；
	// 4. 对于其它值，它为 0。
	int sz = lua_rawlen(L,1) / sizeof(*pool);
	int i;
	for (i=0;i<sz;i++) {
		struct buffer_node *node = &pool[i];
		if (node->msg) {
			skynet_free(node->msg);
			node->msg = NULL;
		}
	}
	return 0;
}

// 分配一组 buffer_node 资源
static int
lnewpool(lua_State *L, int sz) {
	// 分配内存资源, 栈顶元素是 userdata 类型
	struct buffer_node * pool = lua_newuserdatauv(L, sizeof(struct buffer_node) * sz, 0);
	int i;
	// 初始化数据内容
	for (i=0;i<sz;i++) {
		pool[i].msg = NULL;
		pool[i].sz = 0;
		pool[i].next = &pool[i+1];
	}
	// luaL_newmetatable 这时栈顶是一个 table 类型
	pool[sz-1].next = NULL;
	if (luaL_newmetatable(L, "buffer_pool")) {
		// 第一次创建, 设置 gc 函数
		// 给栈顶的表的 __gc 字段关联 lfreepool 函数, 给分配的 userdata 添加终结器, 执行释放内存前的一些操作.
		lua_pushcfunction(L, lfreepool);
		lua_setfield(L, -2, "__gc");
	}
	// 将栈顶的表, 设置为 userdata 的原表
	lua_setmetatable(L, -2);
	return 1;
}

/**
 * 创建一个 socket_buffer, 压入栈
 * lua: 接收 0 个参数, 1 个返回值
 */
static int
lnewbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_newuserdatauv(L, sizeof(*sb), 0);
	sb->size = 0;
	sb->offset = 0;
	sb->head = NULL;
	sb->tail = NULL;
	
	return 1;
}

/*
	userdata send_buffer
	table pool
	lightuserdata msg
	int size

	return size

	Comment: The table pool record all the buffers chunk, 
	and the first index [1] is a lightuserdata : free_node. We can always use this pointer for struct buffer_node .
	The following ([2] ...)  userdatas in table pool is the buffer chunk (for struct buffer_node), 
	we never free them until the VM closed. The size of first chunk ([2]) is 16 struct buffer_node,
	and the second size is 32 ... The largest size of chunk is LARGE_PAGE_NODE (4096)

	lpushbbuffer will get a free struct buffer_node from table pool, and then put the msg/size in it.
	lpopbuffer return the struct buffer_node back to table pool (By calling return_free_node).
	------------------------------------------------------------------------------------

	接收 4 个参数
	userdata socket_buffer
	table pool
	lightuserdata msg
	int size

	1 个返回值, 返回 socket_buffer 的 size
	return size

	注释: pool 表记录所有的缓存数据块, pool 表的第一个索引 [1] 是一个 lightuserdata 类型: free_node. 我们可以一直将这个指针作为 struct buffer_node 指针使用.
	接下来的索引(从 [2] 开始)是 userdata 类型, 它是一个缓存数据块(适用于 struct buffer_node), 我们从来不会释放它们, 直到 VM 被关闭. 第一个数据块([2])的大小
	是 16 个 struct buffer_node, 接着的第二个大小是 32 个, 以此类推. 最大的数据块大小是 LARGE_PAGE_NODE(4096) 个.

	其实 pool[1] 是一个 buffer_node 链表(栈的数据结构), 得到的是当前可用的 buffer_node.
	push 函数是将 buffer_node 从 pool[1] 中弹出到 socket_buffer 中;
	pop 函数是将 buffer_node 从 socket_buffer 弹出, 同时释放 buffer_node.msg 的数据资源, 再添加到 pool[1] 中, 让这个 buffer_node 又可以再次使用.

	lpushbuffer 将从 pool 表中获得一个空闲的 struct buffer_node, 然后设置 msg/size 的值.
	lpopbuffer 返回一个 struct buffer_node 给 pool 表(通过调用 retune_free_node 函数).

	从 pool[1] 中拿出未使用的数据 buffer_node, 使用 buffer_node 存储传入的值, 将已经记录数据的 buffer_node 添加到 socket_buffer 队列中.
	简易流程: data = pool[1] ====>>>> pool[1] = data.next ====>>>> socket_buffer.push(data)
 */
static int
lpushbuffer(lua_State *L) {
	// 获取第 1 个参数, userdata: socket_buffer
	struct socket_buffer *sb = lua_touserdata(L,1);
	if (sb == NULL) {
		return luaL_error(L, "need buffer object at param 1");
	}

	// 获取第 3 个参数, lightuserdata msg
	char * msg = lua_touserdata(L,3);
	if (msg == NULL) {
		return luaL_error(L, "need message block at param 3");
	}

	// 获取第 2 个参数, table pool
	int pool_index = 2;
	luaL_checktype(L,pool_index,LUA_TTABLE);

	// 获取第 4 个参数, int size
	int sz = luaL_checkinteger(L,4);

	// 拿到 table pool 的第 1 个元素 free_node
	lua_rawgeti(L,pool_index,1);
	struct buffer_node * free_node = lua_touserdata(L,-1);	// sb poolt msg size free_node
	lua_pop(L,1);

	// 当没有可用的 buffer_node 时, 分配新的内存空间
	if (free_node == NULL) {
		int tsz = lua_rawlen(L,pool_index);
		if (tsz == 0)
			tsz++;

		// 决定分配
		int size = 8;
		if (tsz <= LARGE_PAGE_NODE-3) {
			size <<= tsz; // 最小分配 16
		} else {
			size <<= LARGE_PAGE_NODE-3; // 最大分配 4096
		}
		lnewpool(L, size);	// 分配内存数据压入到栈顶
		free_node = lua_touserdata(L,-1);

		// pool[tsz + 1] = 栈顶 userdata(free_node), tsz 从 1 开始计数, 所以这里就像上面注释说的, 从 [2] 开始存储连续的数据块.
		lua_rawseti(L, pool_index, tsz+1);
		if (tsz > POOL_SIZE_WARNING) {
			skynet_error(NULL, "Too many socket pool (%d)", tsz);
		}
	}
	lua_pushlightuserdata(L, free_node->next);	// 将当前 free_node 的下一个节点作为 pool[1] 的元素
	lua_rawseti(L, pool_index, 1);	// sb poolt msg size
	
	// 当前的 free_node 记录数据
	free_node->msg = msg;
	free_node->sz = sz;
	free_node->next = NULL;

	// 将 free_node 加入到 socket_buffer
	if (sb->head == NULL) {
		assert(sb->tail == NULL);
		sb->head = sb->tail = free_node;
	} else {
		sb->tail->next = free_node;
		sb->tail = free_node;
	}
	sb->size += sz;

	lua_pushinteger(L, sb->size); // 压入 sb->size 作为返回值

	return 1;
}

static void
return_free_node(lua_State *L, int pool, struct socket_buffer *sb) {
	struct buffer_node *free_node = sb->head;
	sb->offset = 0;
	sb->head = free_node->next;
	if (sb->head == NULL) {
		sb->tail = NULL;
	}
	lua_rawgeti(L,pool,1);
	free_node->next = lua_touserdata(L,-1);
	lua_pop(L,1);
	skynet_free(free_node->msg);
	free_node->msg = NULL;

	free_node->sz = 0;
	lua_pushlightuserdata(L, free_node);
	lua_rawseti(L, pool, 1);
}

static void
pop_lstring(lua_State *L, struct socket_buffer *sb, int sz, int skip) {
	struct buffer_node * current = sb->head;
	if (sz < current->sz - sb->offset) {
		lua_pushlstring(L, current->msg + sb->offset, sz-skip);
		sb->offset+=sz;
		return;
	}
	if (sz == current->sz - sb->offset) {
		lua_pushlstring(L, current->msg + sb->offset, sz-skip);
		return_free_node(L,2,sb);
		return;
	}

	luaL_Buffer b;
	luaL_buffinitsize(L, &b, sz);
	for (;;) {
		int bytes = current->sz - sb->offset;
		if (bytes >= sz) {
			if (sz > skip) {
				luaL_addlstring(&b, current->msg + sb->offset, sz - skip);
			} 
			sb->offset += sz;
			if (bytes == sz) {
				return_free_node(L,2,sb);
			}
			break;
		}
		int real_sz = sz - skip;
		if (real_sz > 0) {
			luaL_addlstring(&b, current->msg + sb->offset, (real_sz < bytes) ? real_sz : bytes);
		}
		return_free_node(L,2,sb);
		sz-=bytes;
		if (sz==0)
			break;
		current = sb->head;
		assert(current);
	}
	luaL_pushresult(&b);
}

static int
lheader(lua_State *L) {
	size_t len;
	const uint8_t * s = (const uint8_t *)luaL_checklstring(L, 1, &len);
	if (len > 4 || len < 1) {
		return luaL_error(L, "Invalid read %s", s);
	}
	int i;
	size_t sz = 0;
	for (i=0;i<(int)len;i++) {
		sz <<= 8;
		sz |= s[i];
	}

	lua_pushinteger(L, (lua_Integer)sz);

	return 1;
}

/*
	userdata send_buffer
	table pool
	integer sz 
 */
static int
lpopbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	int sz = luaL_checkinteger(L,3);
	if (sb->size < sz || sz == 0) {
		lua_pushnil(L);
	} else {
		pop_lstring(L,sb,sz,0);
		sb->size -= sz;
	}
	lua_pushinteger(L, sb->size);

	return 2;
}

/*
	userdata send_buffer
	table pool
 */
static int
lclearbuffer(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		if (lua_isnil(L, 1)) {
			return 0;
		}
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	while(sb->head) {
		return_free_node(L,2,sb);
	}
	sb->size = 0;
	return 0;
}

static int
lreadall(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	luaL_checktype(L,2,LUA_TTABLE);
	luaL_Buffer b;
	luaL_buffinit(L, &b);
	while(sb->head) {
		struct buffer_node *current = sb->head;
		luaL_addlstring(&b, current->msg + sb->offset, current->sz - sb->offset);
		return_free_node(L,2,sb);
	}
	luaL_pushresult(&b);
	sb->size = 0;
	return 1;
}

static int
ldrop(lua_State *L) {
	void * msg = lua_touserdata(L,1);
	luaL_checkinteger(L,2);
	skynet_free(msg);
	return 0;
}

static bool
check_sep(struct buffer_node * node, int from, const char *sep, int seplen) {
	for (;;) {
		int sz = node->sz - from;
		if (sz >= seplen) {
			return memcmp(node->msg+from,sep,seplen) == 0;
		}
		if (sz > 0) {
			if (memcmp(node->msg + from, sep, sz)) {
				return false;
			}
		}
		node = node->next;
		sep += sz;
		seplen -= sz;
		from = 0;
	}
}

/*
	userdata send_buffer
	table pool , nil for check
	string sep
 */
static int
lreadline(lua_State *L) {
	struct socket_buffer * sb = lua_touserdata(L, 1);
	if (sb == NULL) {
		return luaL_error(L, "Need buffer object at param 1");
	}
	// only check
	bool check = !lua_istable(L, 2);
	size_t seplen = 0;
	const char *sep = luaL_checklstring(L,3,&seplen);
	int i;
	struct buffer_node *current = sb->head;
	if (current == NULL)
		return 0;
	int from = sb->offset;
	int bytes = current->sz - from;
	for (i=0;i<=sb->size - (int)seplen;i++) {
		if (check_sep(current, from, sep, seplen)) {
			if (check) {
				lua_pushboolean(L,true);
			} else {
				pop_lstring(L, sb, i+seplen, seplen);
				sb->size -= i+seplen;
			}
			return 1;
		}
		++from;
		--bytes;
		if (bytes == 0) {
			current = current->next;
			from = 0;
			if (current == NULL)
				break;
			bytes = current->sz;
		}
	}
	return 0;
}

static int
lstr2p(lua_State *L) {
	size_t sz = 0;
	const char * str = luaL_checklstring(L,1,&sz);
	void *ptr = skynet_malloc(sz);
	memcpy(ptr, str, sz);
	lua_pushlightuserdata(L, ptr);
	lua_pushinteger(L, (int)sz);
	return 2;
}

// for skynet socket

/*
	lightuserdata msg
	integer size

	return type n1 n2 ptr_or_string
*/
static int
lunpack(lua_State *L) {
	struct skynet_socket_message *message = lua_touserdata(L,1);
	int size = luaL_checkinteger(L,2);

	lua_pushinteger(L, message->type);
	lua_pushinteger(L, message->id);
	lua_pushinteger(L, message->ud);
	if (message->buffer == NULL) {
		lua_pushlstring(L, (char *)(message+1),size - sizeof(*message));
	} else {
		lua_pushlightuserdata(L, message->buffer);
	}
	if (message->type == SKYNET_SOCKET_TYPE_UDP) {
		int addrsz = 0;
		const char * addrstring = skynet_socket_udp_address(message, &addrsz);
		if (addrstring) {
			lua_pushlstring(L, addrstring, addrsz);
			return 5;
		}
	}
	return 4;
}

static const char *
address_port(lua_State *L, char *tmp, const char * addr, int port_index, int *port) {
	const char * host;
	if (lua_isnoneornil(L,port_index)) {
		host = strchr(addr, '[');
		if (host) {
			// is ipv6
			++host;
			const char * sep = strchr(addr,']');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			memcpy(tmp, host, sep-host);
			tmp[sep-host] = '\0';
			host = tmp;
			sep = strchr(sep + 1, ':');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			*port = strtoul(sep+1,NULL,10);
		} else {
			// is ipv4
			const char * sep = strchr(addr,':');
			if (sep == NULL) {
				luaL_error(L, "Invalid address %s.",addr);
			}
			memcpy(tmp, addr, sep-addr);
			tmp[sep-addr] = '\0';
			host = tmp;
			*port = strtoul(sep+1,NULL,10);
		}
	} else {
		host = addr;
		*port = luaL_optinteger(L,port_index, 0);
	}
	return host;
}

static int
lconnect(lua_State *L) {
	size_t sz = 0;
	const char * addr = luaL_checklstring(L,1,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = address_port(L, tmp, addr, 2, &port);
	if (port == 0) {
		return luaL_error(L, "Invalid port");
	}
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = skynet_socket_connect(ctx, host, port);
	lua_pushinteger(L, id);

	return 1;
}

static int
lclose(lua_State *L) {
	int id = luaL_checkinteger(L,1);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	skynet_socket_close(ctx, id);
	return 0;
}

static int
lshutdown(lua_State *L) {
	int id = luaL_checkinteger(L,1);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	skynet_socket_shutdown(ctx, id);
	return 0;
}

/**
 * 侦听指定的端口地址
 * lua: 接收 3 个参数, 参数 1, 主机地址; 参数 2, 端口; 参数 3, backlog, 如果不传此参数, 将使用默认值; 1 个返回值, socket id
 */
static int
llisten(lua_State *L) {
	const char * host = luaL_checkstring(L,1);
	int port = luaL_checkinteger(L,2);
	int backlog = luaL_optinteger(L,3,BACKLOG);
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = skynet_socket_listen(ctx, host,port,backlog);
	if (id < 0) {
		return luaL_error(L, "Listen error");
	}

	lua_pushinteger(L,id);
	return 1;
}

static size_t
count_size(lua_State *L, int index) {
	size_t tlen = 0;
	int i;
	for (i=1;lua_geti(L, index, i) != LUA_TNIL; ++i) {
		size_t len;
		luaL_checklstring(L, -1, &len);
		tlen += len;
		lua_pop(L,1);
	}
	lua_pop(L,1);
	return tlen;
}

static void
concat_table(lua_State *L, int index, void *buffer, size_t tlen) {
	char *ptr = buffer;
	int i;
	for (i=1;lua_geti(L, index, i) != LUA_TNIL; ++i) {
		size_t len;
		const char * str = lua_tolstring(L, -1, &len);
		if (str == NULL || tlen < len) {
			break;
		}
		memcpy(ptr, str, len);
		ptr += len;
		tlen -= len;
		lua_pop(L,1);
	}
	if (tlen != 0) {
		skynet_free(buffer);
		luaL_error(L, "Invalid strings table");
	}
	lua_pop(L,1);
}

static void
get_buffer(lua_State *L, int index, struct socket_sendbuffer *buf) {
	void *buffer;
	switch(lua_type(L, index)) {
		size_t len;
	case LUA_TUSERDATA:
		// lua full useobject must be a raw pointer, it can't be a socket object or a memory object.
		buf->type = SOCKET_BUFFER_RAWPOINTER;
		buf->buffer = lua_touserdata(L, index);
		if (lua_isinteger(L, index+1)) {
			buf->sz = lua_tointeger(L, index+1);
		} else {
			buf->sz = lua_rawlen(L, index);
		}
		break;
	case LUA_TLIGHTUSERDATA: {
		int sz = -1;
		if (lua_isinteger(L, index+1)) {
			sz = lua_tointeger(L,index+1);
		}
		if (sz < 0) {
			buf->type = SOCKET_BUFFER_OBJECT;
		} else {
			buf->type = SOCKET_BUFFER_MEMORY;
		}
		buf->buffer = lua_touserdata(L,index);
		buf->sz = (size_t)sz;
		break;
		}
	case LUA_TTABLE:
		// concat the table as a string
		len = count_size(L, index);
		buffer = skynet_malloc(len);
		concat_table(L, index, buffer, len);
		buf->type = SOCKET_BUFFER_MEMORY;
		buf->buffer = buffer;
		buf->sz = len;
		break;
	default:
		buf->type = SOCKET_BUFFER_RAWPOINTER;
		buf->buffer = luaL_checklstring(L, index, &buf->sz);
		break;
	}
}

/**
 * 使用高优先级队列发送数据
 * lua: 接收 2 或者 3 个参数, 参数 1, socket id; 参数 2, 如果是 string, 那么无需传入参数 3, 如果是 lightuserdata 那么需要参数 3, 表示数据的大小.
 * 1 个返回值, boolean 类型, true 表示成功.
 */
static int
lsend(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	struct socket_sendbuffer buf;
	buf.id = id;
	get_buffer(L, 2, &buf);
	int err = skynet_socket_sendbuffer(ctx, &buf);
	lua_pushboolean(L, !err);
	return 1;
}

/**
 * 使用低优先级队列发送数据
 * lua: 接收 2 或者 3 个参数, 参数 1, socket id; 参数 2, 如果是 string, 那么无需传入参数 3, 如果是 lightuserdata 那么需要参数 3, 表示数据的大小.
 * 0 个返回值.
 */
static int
lsendlow(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	struct socket_sendbuffer buf;
	buf.id = id;
	get_buffer(L, 2, &buf);
	int err = skynet_socket_sendbuffer_lowpriority(ctx, &buf);
	lua_pushboolean(L, !err);
	return 1;
}

static int
lbind(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int fd = luaL_checkinteger(L, 1);
	int id = skynet_socket_bind(ctx,fd);
	lua_pushinteger(L,id);
	return 1;
}

static int
lstart(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	skynet_socket_start(ctx,id);
	return 0;
}

static int
lpause(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	skynet_socket_pause(ctx,id);
	return 0;
}

static int
lnodelay(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	skynet_socket_nodelay(ctx,id);
	return 0;
}

static int
ludp(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	size_t sz = 0;
	const char * addr = lua_tolstring(L,1,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = NULL;
	if (addr) {
		host = address_port(L, tmp, addr, 2, &port);
	}

	int id = skynet_socket_udp(ctx, host, port);
	if (id < 0) {
		return luaL_error(L, "udp init failed");
	}
	lua_pushinteger(L, id);
	return 1;
}

static int
ludp_connect(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	size_t sz = 0;
	const char * addr = luaL_checklstring(L,2,&sz);
	char tmp[sz];
	int port = 0;
	const char * host = NULL;
	if (addr) {
		host = address_port(L, tmp, addr, 3, &port);
	}

	if (skynet_socket_udp_connect(ctx, id, host, port)) {
		return luaL_error(L, "udp connect failed");
	}

	return 0;
}

static int
ludp_dial(lua_State *L){
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	size_t sz = 0;
	const char * addr = luaL_checklstring(L, 1, &sz);
	char tmp[sz];
	int port = 0;
	const char * host =  address_port(L, tmp, addr, 2, &port);

	int id = skynet_socket_udp_dial(ctx, host, port);
	if (id < 0){
		return luaL_error(L, "udp dial host failed");
	}

	lua_pushinteger(L, id);
	return 1;
}

static int
ludp_listen(lua_State *L){
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	size_t sz = 0;
	const char * addr = luaL_checklstring(L, 1, &sz);
	char tmp[sz];

	int port = 0;
	const char * host = address_port(L, tmp, addr, 2, &port);

	int id = skynet_socket_udp_listen(ctx, host, port);
	if (id < 0){
		return luaL_error(L, "udp listen host failed");
	}

	lua_pushinteger(L, id);
	return 1;
}


static int
ludp_send(lua_State *L) {
	struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
	int id = luaL_checkinteger(L, 1);
	const char * address = luaL_checkstring(L, 2);
	struct socket_sendbuffer buf;
	buf.id = id;
	get_buffer(L, 3, &buf);
	int err = skynet_socket_udp_sendbuffer(ctx, address, &buf);

	lua_pushboolean(L, !err);

	return 1;
}

static int
ludp_address(lua_State *L) {
	size_t sz = 0;
	const uint8_t * addr = (const uint8_t *)luaL_checklstring(L, 1, &sz);
	uint16_t port = 0;
	memcpy(&port, addr+1, sizeof(uint16_t));
	port = ntohs(port);
	const void * src = addr+3;
	char tmp[256];
	int family;
	if (sz == 1+2+4) {
		family = AF_INET;
	} else {
		if (sz != 1+2+16) {
			return luaL_error(L, "Invalid udp address");
		}
		family = AF_INET6;
	}
	if (inet_ntop(family, src, tmp, sizeof(tmp)) == NULL) {
		return luaL_error(L, "Invalid udp address");
	}
	lua_pushstring(L, tmp);
	lua_pushinteger(L, port);
	return 2;
}

static void
getinfo(lua_State *L, struct socket_info *si) {
	lua_newtable(L);
	lua_pushinteger(L, si->id);
	lua_setfield(L, -2, "id");
	lua_pushinteger(L, si->opaque);
	lua_setfield(L, -2, "address");
	switch(si->type) {
	case SOCKET_INFO_LISTEN:
		lua_pushstring(L, "LISTEN");
		lua_setfield(L, -2, "type");
		lua_pushinteger(L, si->read);
		lua_setfield(L, -2, "accept");
		lua_pushinteger(L, si->rtime);
		lua_setfield(L, -2, "rtime");
		if (si->name[0]) {
			lua_pushstring(L, si->name);
			lua_setfield(L, -2, "sock");
		}
		return;
	case SOCKET_INFO_TCP:
		lua_pushstring(L, "TCP");
		break;
	case SOCKET_INFO_UDP:
		lua_pushstring(L, "UDP");
		break;
	case SOCKET_INFO_BIND:
		lua_pushstring(L, "BIND");
		break;
	case SOCKET_INFO_CLOSING:
		lua_pushstring(L, "CLOSING");
		break;
	default:
		lua_pushstring(L, "UNKNOWN");
		lua_setfield(L, -2, "type");
		return;
	}
	lua_setfield(L, -2, "type");
	lua_pushinteger(L, si->read);
	lua_setfield(L, -2, "read");
	lua_pushinteger(L, si->write);
	lua_setfield(L, -2, "write");
	lua_pushinteger(L, si->wbuffer);
	lua_setfield(L, -2, "wbuffer");
	lua_pushinteger(L, si->rtime);
	lua_setfield(L, -2, "rtime");
	lua_pushinteger(L, si->wtime);
	lua_setfield(L, -2, "wtime");
	lua_pushboolean(L, si->reading);
	lua_setfield(L, -2, "reading");
	lua_pushboolean(L, si->writing);
	lua_setfield(L, -2, "writing");
	if (si->name[0]) {
		lua_pushstring(L, si->name);
		lua_setfield(L, -2, "peer");
	}
}

static int
linfo(lua_State *L) {
	lua_newtable(L);
	struct socket_info * si = skynet_socket_info();
	struct socket_info * temp = si;
	int n = 0;
	while (temp) {
		getinfo(L, temp);
		lua_seti(L, -2, ++n);
		temp = temp->next;
	}
	socket_info_release(si);
	return 1;
}

static int
lresolve(lua_State *L) {
	const char * host = luaL_checkstring(L, 1);
	int status;
	struct addrinfo ai_hints;
	struct addrinfo *ai_list = NULL;
	struct addrinfo *ai_ptr = NULL;
	memset( &ai_hints, 0, sizeof( ai_hints ) );
	status = getaddrinfo( host, NULL, &ai_hints, &ai_list);
	if ( status != 0 ) {
		return luaL_error(L, gai_strerror(status));
	}
	lua_newtable(L);
	int idx = 1;
	char tmp[128];
	for (ai_ptr = ai_list; ai_ptr != NULL; ai_ptr = ai_ptr->ai_next ) {
		struct sockaddr * addr = ai_ptr->ai_addr;
		void * sin_addr = (ai_ptr->ai_family == AF_INET) ? (void*)&((struct sockaddr_in *)addr)->sin_addr : (void*)&((struct sockaddr_in6 *)addr)->sin6_addr;
		if (inet_ntop(ai_ptr->ai_family, sin_addr, tmp, sizeof(tmp))) {
			lua_pushstring(L, tmp);
			lua_rawseti(L, -2, idx++);
		}
	}

	freeaddrinfo(ai_list);
	return 1;
}

/// 注册 socket 模块到 lua 中
LUAMOD_API int
luaopen_skynet_socketdriver(lua_State *L) {
	// 检查调用它的内核是否是创建这个 Lua 状态机的内核。 以及调用它的代码是否使用了相同的 Lua 版本。 
	// 同时也检查调用它的内核与创建该 Lua 状态机的内核 是否使用了同一片地址空间。
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "buffer", lnewbuffer },
		{ "push", lpushbuffer },
		{ "pop", lpopbuffer },
		{ "drop", ldrop },
		{ "readall", lreadall },
		{ "clear", lclearbuffer },
		{ "readline", lreadline },
		{ "str2p", lstr2p },
		{ "header", lheader },
		{ "info", linfo },

		{ "unpack", lunpack },
		{ NULL, NULL },
	};
	luaL_newlib(L,l); // 创建一张新的表，并把列表 l 中的函数注册进去。  这时栈顶是 table

	luaL_Reg l2[] = {
		{ "connect", lconnect },
		{ "close", lclose },
		{ "shutdown", lshutdown },
		{ "listen", llisten },
		{ "send", lsend },
		{ "lsend", lsendlow },
		{ "bind", lbind },
		{ "start", lstart },
		{ "pause", lpause },
		{ "nodelay", lnodelay },
		{ "udp", ludp },
		{ "udp_connect", ludp_connect },
		{ "udp_dial", ludp_dial},
		{ "udp_listen", ludp_listen},
		{ "udp_send", ludp_send },
		{ "udp_address", ludp_address },
		{ "resolve", lresolve },
		{ NULL, NULL },
	};
	// 将注册表的 "skynet_context" 的值压入到栈顶, 在 service_snlua.c 的 _init 函数中在注册表中添加了 "skynet_context" 这个域的值.
	lua_getfield(L, LUA_REGISTRYINDEX, "skynet_context");
	struct skynet_context *ctx = lua_touserdata(L,-1);
	if (ctx == NULL) {
		return luaL_error(L, "Init skynet context first");
	}
	// void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup);
	// 把数组 l 中的所有函数注册到栈顶的表中(该表在可选的 upvalue 之下, 见下面的解说).
	// 若 nup 不为零， 所有的函数都共享 nup 个 upvalue。 这些值必须在调用之前，压在表之上。 这些值在注册完毕后都会从栈弹出。
	// 根据上面对 luaL_setfuncs 的描述, 当前共享的 upvalue 就是 userdata(skynet_context).
	luaL_setfuncs(L,l2,1);

	return 1;
}
