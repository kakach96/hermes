%% 赫尔墨斯 v0 —— fjall 存储 sidecar 的 Erlang port 驱动。
%%
%% {packet, 4}：4 字节大端长度帧（与 Rust 侧对齐）。
%% port 的所有者是调用进程（store Actor 的 initialiser），
%% 交互全部同步（store Actor 顺序处理，天然单飞行请求）。
%% port 崩溃 → exit 信号带走 owner（store Actor）→ 监督树重启重建 port，
%% fjall 数据在磁盘上，天然恢复。
-module(hermes_store_ffi).

-export([open/2, call/2]).

open(Exe, DataDir) ->
    case filelib:is_regular(Exe) of
        false ->
            {error, <<"sidecar 不存在: ", Exe/binary>>};
        true ->
            case catch open_port({spawn_executable, Exe},
                                 [binary, {packet, 4}, {args, [DataDir]}, hide]) of
                {'EXIT', Reason} -> {error, reason_to_binary(Reason)};
                Port -> {ok, Port}
            end
    end.

call(Port, ReqBin) ->
    Port ! {self(), {command, ReqBin}},
    receive
        {Port, {data, RespBin}} -> {ok, RespBin};
        %% port 进程死了：报错给调用方，owner 随后也会收到 exit 信号走重启
        {'EXIT', Port, Reason} -> {error, reason_to_binary(Reason)}
    after 5000 -> {error, <<"timeout">>}
    end.

reason_to_binary(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
