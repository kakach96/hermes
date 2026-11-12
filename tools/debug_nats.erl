%% FFI 裸测：绕过 Gleam，直接验证 hermes_ffi 的连接/订阅/发布/应答
-module(debug_nats).
-export([main/0]).

main() ->
    OnMsg = fun(Subject, Reply, Payload) ->
        io:format("[MSG] subject=~p reply=~p payload=~p~n", [Subject, Reply, Payload])
    end,
    case hermes_ffi:connect(<<"127.0.0.1">>, 4222, OnMsg) of
        {error, Reason} ->
            io:format("connect 失败: ~p~n", [Reason]);
        {ok, Conn} ->
            io:format("connect ok: ~p~n", [Conn]),
            Ref = erlang:monitor(process, Conn),
            receive
                {'DOWN', Ref, process, Conn, Why} ->
                    io:format("conn 死亡: ~p~n", [Why])
            after 300 -> ok
            end,
            io:format("conn alive=~p~n", [erlang:is_process_alive(Conn)]),
            case hermes_ffi:subscribe(Conn, <<"debug.topic">>) of
                {ok, Sid} -> io:format("subscribe ok sid=~p~n", [Sid]);
                Other -> io:format("subscribe 失败: ~p~n", [Other])
            end,
            hermes_ffi:publish(Conn, <<"debug.topic">>, <<"hello-hermes">>),
            timer:sleep(1000),
            case hermes_ffi:request(Conn, <<"$JS.API.STREAM.INFO.hermes_test">>, <<"{}">>, 3000) of
                {ok, Data} -> io:format("stream info: ~s~n", [Data]);
                {error, Err} -> io:format("stream info 失败: ~p~n", [Err])
            end,
            %% 建 consumer（复刻 bus 的 Attach 流程）
            {ok, Sid2} = hermes_ffi:subscribe(Conn, <<"debug.inbox.1">>),
            Cfg = <<"{\"stream_name\":\"hermes_test\",\"config\":{\"filter_subject\":\"debug.room\",\"deliver_subject\":\"debug.inbox.1\",\"ack_policy\":\"none\",\"deliver_policy\":\"all\"}}">>,
            case hermes_ffi:request(Conn, <<"$JS.API.CONSUMER.CREATE.hermes_test">>, Cfg, 3000) of
                {ok, Info} -> io:format("consumer info: ~s~n", [Info]);
                {error, Err2} -> io:format("consumer create 失败: ~p~n", [Err2])
            end,
            hermes_ffi:publish(Conn, <<"debug.room">>, <<"payload-1">>),
            timer:sleep(1000),
            io:format("done~n")
    end,
    erlang:halt(0).
