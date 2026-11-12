# 赫尔墨斯 v0 server 启动脚本（WMI 脱离父进程启动时用）
@echo off
set PATH=D:\programs\gleam;D:\programs\Erlang\bin;D:\programs\rebar3;%PATH%
cd /d D:\projects\hermes\server
gleam run > ..\infra\server.log 2>&1
