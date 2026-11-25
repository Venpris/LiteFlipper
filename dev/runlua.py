# Runs a Lua 5.1 script through the LuaJIT DLL that ships with OBS Studio.
# Usage: python -I runlua.py <script.lua> [KEY=VALUE ...]   (KEY=VALUE become Lua globals)
import ctypes
import os
import sys

DLL_DIR = r"C:\Program Files\obs-studio\bin\64bit"
os.add_dll_directory(DLL_DIR)
lua = ctypes.CDLL(os.path.join(DLL_DIR, "lua51.dll"))

lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
LUA_GLOBALSINDEX = -10002

L = ctypes.c_void_p(lua.luaL_newstate())
lua.luaL_openlibs(L)
for arg in sys.argv[2:]:
    key, _, value = arg.partition("=")
    lua.lua_pushstring(L, value.encode("utf-8"))
    lua.lua_setfield(L, LUA_GLOBALSINDEX, key.encode("utf-8"))

sys.stdout.flush()
status = lua.luaL_loadfile(L, sys.argv[1].encode("utf-8"))
if status == 0:
    status = lua.lua_pcall(L, 0, 0, 0)
if status != 0:
    msg = lua.lua_tolstring(L, -1, None)
    print("LUA ERROR:", msg.decode("utf-8", "replace") if msg else "?")
    sys.exit(1)
