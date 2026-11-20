%% 赫尔墨斯 v0 —— 最小 NATS 客户端（Erlang FFI）。
%%
%% 设计：
%% - 一个连接 = 一个 Erlang 进程，独占 socket，顺序处理收发（单写者，无需锁）
%% - PUB/SUB 走 cast（不阻塞调用方）；subscribe/request 走同步应答
%% - conn 进程拥有的订阅：MSG 投递给 OnMsg 回调（Gleam 侧的总线 Actor）
%% - 其他进程拥有的订阅（内部 request 用）：MSG 投递给 {nats_msg, ...} 消息
%% - 自动应答服务端 PING；-ERR 视为致命，退出连接交给监督树重启
-module(hermes_ffi).

-export([connect/3, close/1, conn_pid/1, subscribe/2, unsubscribe/2,
         publish/3, request/4, unique_inbox/1, getenv/1,
         pbkdf2_sha256/4, strong_rand_bytes/1, rand_hex/1, const_eq/2]).

%% --- 连接管理 ---------------------------------------------------------------

connect(Host, Port, OnMsg) ->
    %% passive 建连：交接 controlling process 前保证不会有 {tcp,...} 乱投
    Opts = [binary, {active, false}, {nodelay, true}, {keepalive, true}],
    case gen_tcp:connect(binary_to_list(Host), Port, Opts, 5000) of
        {ok, Sock} ->
            %% spawn 而非 spawn_link：调用方（bus Actor）用 monitor 感知死亡
            Pid = spawn(fun() -> conn_boot(Sock, OnMsg) end),
            %% socket 的 controlling process 默认是创建者（bus Actor），
            %% 必须显式交接给连接进程，否则 {tcp,...} 会投错信箱
            ok = gen_tcp:controlling_process(Sock, Pid),
            ok = gen_tcp:send(Sock, connect_frame()),
            Pid ! go,
            {ok, Pid};
        {error, Reason} ->
            {error, reason_to_binary(Reason)}
    end.

%% 等 go 再进主循环：交接完成后才打开 active-once 开始收数据
conn_boot(Sock, OnMsg) ->
    receive
        go ->
            inet:setopts(Sock, [{active, once}]),
            conn_loop(Sock, OnMsg, <<>>, 0, #{})
    end.

conn_pid(Conn) -> Conn.

close(Conn) ->
    Conn ! stop,
    ok.

reason_to_binary(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).

connect_frame() ->
    Body = <<"{\"verbose\":false,\"pedantic\":false,\"tls_required\":false,"
             "\"name\":\"hermes\",\"lang\":\"gleam\",\"version\":\"0.1.0\","
             "\"protocol\":1,\"echo\":true,\"headers\":false}">>,
    <<"CONNECT ", Body/binary, "\r\n">>.

%% --- 连接进程 ---------------------------------------------------------------

conn_loop(Sock, OnMsg, Buf, NextSid, Subs) ->
    receive
        {tcp, Sock, Data} ->
            case consume_frames(Sock, OnMsg, <<Buf/binary, Data/binary>>, Subs) of
                {ok, Buf2} ->
                    inet:setopts(Sock, [{active, once}]),
                    conn_loop(Sock, OnMsg, Buf2, NextSid, Subs);
                {stop, Reason} ->
                    gen_tcp:close(Sock),
                    exit({nats_conn, Reason})
            end;
        {tcp_error, Sock, Reason} ->
            gen_tcp:close(Sock),
            exit({nats_conn, Reason});
        {tcp_closed, Sock} ->
            exit({nats_conn, closed});
        {pub, Subject, Payload} ->
            ok = gen_tcp:send(Sock, pub_frame(Subject, none, Payload)),
            conn_loop(Sock, OnMsg, Buf, NextSid, Subs);
        {pub, Subject, Reply, Payload} ->
            ok = gen_tcp:send(Sock, pub_frame(Subject, Reply, Payload)),
            conn_loop(Sock, OnMsg, Buf, NextSid, Subs);
        {sub, ReplyTo, Owner, Subject} ->
            Sid = NextSid,
            ok = gen_tcp:send(Sock, sub_frame(Subject, Sid)),
            ReplyTo ! {sid, Sid},
            conn_loop(Sock, OnMsg, Buf, NextSid + 1, Subs#{Sid => {Subject, Owner}});
        {unsub, Sid} ->
            ok = gen_tcp:send(Sock, unsub_frame(Sid)),
            conn_loop(Sock, OnMsg, Buf, NextSid, maps:remove(Sid, Subs));
        stop ->
            gen_tcp:close(Sock),
            ok
    end.

%% 尽可能多地消化完整帧；不完整时把残余留在缓冲区
consume_frames(Sock, OnMsg, Buf, Subs) ->
    case split_line(Buf) of
        none ->
            {ok, Buf};
        {ok, Line, Rest} ->
            case dispatch_frame(Sock, OnMsg, Line, Rest, Subs) of
                {ok, Rest2} ->
                    consume_frames(Sock, OnMsg, Rest2, Subs);
                {more, Buf2} ->
                    {ok, Buf2};
                {stop, Reason} ->
                    {stop, Reason}
            end
    end.

split_line(Buf) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Line, Rest] -> {ok, Line, Rest};
        [_] -> none
    end.

dispatch_frame(Sock, OnMsg, Line, Rest, Subs) ->
    case Line of
        <<"PING">> ->
            ok = gen_tcp:send(Sock, <<"PONG\r\n">>),
            {ok, Rest};
        <<"INFO ", _/binary>> ->
            {ok, Rest};
        <<"PONG">> ->
            {ok, Rest};
        <<"+OK">> ->
            {ok, Rest};
        <<"-ERR ", Why/binary>> ->
            {stop, Why};
        <<"MSG ", Fields/binary>> ->
            handle_msg_frame(Fields, OnMsg, Line, Rest, Subs);
        <<"HMSG ", _/binary>> ->
            %% v0 不支持 headers 消息，跳过
            {ok, Rest};
        _ ->
            {ok, Rest}
    end.

handle_msg_frame(Fields, OnMsg, Line, Rest, Subs) ->
    Tokens = binary:split(Fields, <<" ">>, [global, trim_all]),
    case Tokens of
        %% MSG <subject> <sid> <size>
        [Subject, SidBin, SizeBin] ->
            take_and_deliver(Subject, SidBin, <<>>, SizeBin, OnMsg, Line, Rest, Subs);
        %% MSG <subject> <sid> <reply> <size>
        [Subject, SidBin, Reply, SizeBin] ->
            take_and_deliver(Subject, SidBin, Reply, SizeBin, OnMsg, Line, Rest, Subs);
        _ ->
            {ok, Rest}
    end.

take_and_deliver(Subject, SidBin, Reply, SizeBin, OnMsg, Line, Rest, Subs) ->
    Size = binary_to_integer(SizeBin),
    case Rest of
        <<Payload:Size/binary, "\r\n", Rest2/binary>> ->
            deliver(binary_to_integer(SidBin), Subject, Reply, Payload, OnMsg, Subs),
            {ok, Rest2};
        _ ->
            %% 载荷还没到齐：整帧（含 MSG 行）放回缓冲
            {more, <<Line/binary, "\r\n", Rest/binary>>}
    end.

%% 路由按订阅的 Sid 走，而不是 MSG 的 subject ——
%% JetStream push 投递的 MSG subject 是消息的原始 subject（如房间），
%% 不是 deliver_subject；同一房间多个消费者时只有 sid 能区分归属。
%% OnMsg(route_subject, msg_subject, reply, payload)：
%% route_subject = 订阅时的 subject（inbox），msg_subject = 原始 subject。
deliver(Sid, Subject, Reply, Payload, OnMsg, Subs) ->
    case maps:find(Sid, Subs) of
        {ok, {Subscribed, on_msg}} ->
            OnMsg(Subscribed, Subject, Reply, Payload);
        {ok, {Subscribed, Owner}} ->
            Owner ! {nats_msg, Subscribed, Subject, Reply, Payload};
        error ->
            ok
    end.
%% --- 帧构造 ------------------------------------------------------------------

pub_frame(Subject, none, Payload) ->
    [<<"PUB ">>, Subject, <<" ">>, integer_to_binary(byte_size(Payload)),
     <<"\r\n">>, Payload, <<"\r\n">>];
pub_frame(Subject, Reply, Payload) ->
    [<<"PUB ">>, Subject, <<" ">>, Reply, <<" ">>,
     integer_to_binary(byte_size(Payload)), <<"\r\n">>, Payload, <<"\r\n">>].

sub_frame(Subject, Sid) ->
    [<<"SUB ">>, Subject, <<" ">>, integer_to_binary(Sid), <<"\r\n">>].

unsub_frame(Sid) ->
    [<<"UNSUB ">>, integer_to_binary(Sid), <<"\r\n">>].

%% --- Gleam 侧 API ------------------------------------------------------------

%% 总线型订阅：MSG 走 OnMsg 回调
subscribe(Conn, Subject) ->
    Conn ! {sub, self(), on_msg, Subject},
    receive
        {sid, Sid} -> {ok, Sid}
    after 2000 -> {error, nil}
    end.

unsubscribe(Conn, Sid) ->
    Conn ! {unsub, Sid},
    ok.

publish(Conn, Subject, Payload) ->
    Conn ! {pub, Subject, none, Payload},
    ok.

%% 同步 request-reply：自带临时 INBOX，等一条应答
request(Conn, Subject, Payload, Timeout) ->
    ReplySubject = unique_inbox(<<"_REQ.">>),
    Conn ! {sub, self(), self(), ReplySubject},
    Sid = receive
        {sid, S} -> S
    after 2000 -> exit(nats_sub_timeout)
    end,
    Conn ! {pub, Subject, ReplySubject, Payload},
    Result = receive
        {nats_msg, ReplySubject, _MsgSubject, _Reply, Data} -> {ok, Data}
    after Timeout -> {error, <<"timeout">>}
    end,
    Conn ! {unsub, Sid},
    Result.

%% 给 Gleam 用的唯一字符串（不烧原子表）。
%% 注意：unique_integer 是 per-VM 计数器，两个 VM 各自从 1 开始数，
%% 直接用它当 subject 会跨进程撞号（NATS 按 subject 投递，谁都能收到）。
%% 所以每次调用混入 48bit 随机分量，同 VM 内再靠 unique_integer 兜底。
unique_inbox(Prefix) ->
    Rand = binary:encode_hex(crypto:strong_rand_bytes(6)),
    <<Prefix/binary, Rand/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

%% Env var lookup (deploy overrides: sidecar path / data dir / NATS address).
%% Unset -> error; the Gleam side falls back to compile-time defaults.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% ---- password primitives (OTP crypto BIFs, NOT a home-rolled scheme) ----

%% PBKDF2-HMAC-SHA256. OWASP-recommended KDF; the BIF is NIF-accelerated.
pbkdf2_sha256(Password, Salt, Iterations, OutLen) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, OutLen).

strong_rand_bytes(N) ->
    crypto:strong_rand_bytes(N).

%% hex(CSPRNG(N)) as an ascii string (tokens; gleam String = utf8 binary)
rand_hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N)).

%% Constant-time equality (XOR-fold; short-circuits only on length mismatch,
%% which leaks nothing of the digest).
const_eq(A, B) when byte_size(A) =:= byte_size(B) ->
    const_eq(A, B, 0);
const_eq(_, _) ->
    false.

const_eq(<<X, RestA/binary>>, <<Y, RestB/binary>>, Acc) ->
    const_eq(RestA, RestB, Acc bor (X bxor Y));
const_eq(<<>>, <<>>, Acc) ->
    Acc =:= 0.
