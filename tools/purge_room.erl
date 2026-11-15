%% 赫尔墨斯 运维工具：按 subject 前缀清空 JetStream 流里的残留消息。
%%
%% 用途：e2e 测试数据误入生产房间后，把那个房间的历史清掉
%%（新设备 cursor=0 入房会从头重放，残留会被播给真实用户）。
%%
%% 用法：
%%   erl -pa server/build/dev/erlang/*/ebin -noshell -run purge_room main "hermes.rooms.lobby.general" -s init stop
%%
%% 原理：$JS.API.STREAM.PURGE.<stream> 请求带 {"filter": "<subject>"}，
%% 只删匹配该 subject 的消息，不动流配置与其他房间。

-module(purge_room).
-export([main/1]).

main([Subject]) ->
    OnMsg = fun(_S, _R, _P) -> ok end,
    case hermes_ffi:connect(<<"127.0.0.1">>, 4222, OnMsg) of
        {error, Reason} ->
            io:format("NATS 连接失败: ~p~n", [Reason]),
            halt(1);
        {ok, Conn} ->
            Payload = jsx_ok(Subject),
            case hermes_ffi:request(Conn, <<"$JS.API.STREAM.PURGE.hermes_chat">>, Payload, 5000) of
                {error, Reason2} ->
                    io:format("PURGE 请求失败: ~p~n", [Reason2]),
                    halt(1);
                {ok, Resp} ->
                    io:format("purge ~s -> ~s~n", [Subject, Resp]),
                    hermes_ffi:close(Conn)
            end
    end;
main(_) ->
    io:format("用法: purge_room <subject 前缀>~n例: purge_room \"hermes.rooms.lobby.general\"~n"),
    halt(1).

%% hermes_ffi 的 payload 是 binary；用 OTP 自带 json（OTP 27+）免依赖
jsx_ok(Subject) ->
    Bin = unicode:characters_to_binary(Subject),
    <<"\"filter\":\"", Bin/binary, "\"">>.
