%%--------------------------------------------------------------------
%% Copyright (c) 2018-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% MQTT/TCP|TLS Connection
-module(emqx_connection).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include("logger.hrl").
-include("types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-elvis([{elvis_style, invalid_dynamic_call, #{ignore => [emqx_connection]}}]).

%% API
-export([ start_link/3
        , stop/1
        ]).

-export([ info/1
        , stats/1
        ]).

-export([ async_set_keepalive/3
        , async_set_keepalive/4
        , async_set_socket_options/2
        ]).

-export([ call/2
        , call/3
        , cast/2
        ]).

%% Callback
-export([init/4]).

%% Sys callbacks
-export([ system_continue/3
        , system_terminate/4
        , system_code_change/4
        , system_get_state/1
        ]).

%% Internal callback
-export([wakeup_from_hib/2, recvloop/2, get_state/1]).

%% Export for CT
-export([set_field/3]).

-import(emqx_misc,
        [ maybe_apply/2
        , start_timer/2
        ]).

-record(state, {
          %% TCP/TLS Transport
          transport :: esockd:transport(),
          %% TCP/TLS Socket
          socket :: esockd:socket(),
          %% Peername of the connection
          peername :: emqx_types:peername(),
          %% Sockname of the connection
          sockname :: emqx_types:peername(),
          %% Sock State
          sockstate :: emqx_types:sockstate(),
          %% Limiter
          limiter :: maybe(emqx_limiter:limiter()),
          %% Limit Timer
          limit_timer :: maybe(reference()),
          %% Parse State
          parse_state :: emqx_frame:parse_state(),
          %% Serialize options
          serialize :: emqx_frame:serialize_opts(),
          %% Channel State
          channel :: emqx_channel:channel(),
          %% GC State
          gc_state :: maybe(emqx_gc:gc_state()),
          %% Stats Timer
          stats_timer :: disabled | maybe(reference()),
          %% Idle Timeout
          idle_timeout :: integer(),
          %% Idle Timer
          idle_timer :: maybe(reference()),
          %% Zone name
          zone :: atom(),
          %% Listener Type and Name
          listener :: {Type::atom(), Name::atom()}
        }).

-type(state() :: #state{}).

-define(ACTIVE_N, 100).
-define(INFO_KEYS, [socktype, peername, sockname, sockstate]).
-define(CONN_STATS, [recv_pkt, recv_msg, send_pkt, send_msg]).
-define(SOCK_STATS, [recv_oct, recv_cnt, send_oct, send_cnt, send_pend]).

-define(ENABLED(X), (X =/= undefined)).

-define(ALARM_TCP_CONGEST(Channel),
        list_to_binary(io_lib:format("mqtt_conn/congested/~s/~s",
            [emqx_channel:info(clientid, Channel),
             emqx_channel:info(username, Channel)]))).

-define(ALARM_CONN_INFO_KEYS, [
    socktype, sockname, peername,
    clientid, username, proto_name, proto_ver, connected_at
]).
-define(ALARM_SOCK_STATS_KEYS, [send_pend, recv_cnt, recv_oct, send_cnt, send_oct]).
-define(ALARM_SOCK_OPTS_KEYS, [high_watermark, high_msgq_watermark, sndbuf, recbuf, buffer]).

-dialyzer({no_match, [info/2]}).
-dialyzer({nowarn_function, [ init/4
                            , init_state/3
                            , run_loop/2
                            , system_terminate/4
                            , system_code_change/4
                            ]}).

-spec(start_link(esockd:transport(),
                 esockd:socket() | {pid(), quicer:connection_handler()},
                 emqx_channel:opts())
      -> {ok, pid()}).
start_link(Transport, Socket, Options) ->
    Args = [self(), Transport, Socket, Options],
    CPid = proc_lib:spawn_link(?MODULE, init, Args),
    {ok, CPid}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Get infos of the connection/channel.
-spec(info(pid()|state()) -> emqx_types:infos()).
info(CPid) when is_pid(CPid) ->
    call(CPid, info);
info(State = #state{channel = Channel}) ->
    ChanInfo = emqx_channel:info(Channel),
    SockInfo = maps:from_list(
                 info(?INFO_KEYS, State)),
    ChanInfo#{sockinfo => SockInfo}.

info(Keys, State) when is_list(Keys) ->
    [{Key, info(Key, State)} || Key <- Keys];
info(socktype, #state{transport = Transport, socket = Socket}) ->
    Transport:type(Socket);
info(peername, #state{peername = Peername}) ->
    Peername;
info(sockname, #state{sockname = Sockname}) ->
    Sockname;
info(sockstate, #state{sockstate = SockSt}) ->
    SockSt;
info(stats_timer, #state{stats_timer = StatsTimer}) ->
    StatsTimer;
info(limit_timer, #state{limit_timer = LimitTimer}) ->
    LimitTimer;
info(limiter, #state{limiter = Limiter}) ->
    maybe_apply(fun emqx_limiter:info/1, Limiter).

%% @doc Get stats of the connection/channel.
-spec(stats(pid()|state()) -> emqx_types:stats()).
stats(CPid) when is_pid(CPid) ->
    call(CPid, stats);
stats(#state{transport = Transport,
             socket    = Socket,
             channel   = Channel}) ->
    SockStats = case Transport:getstat(Socket, ?SOCK_STATS) of
                    {ok, Ss}   -> Ss;
                    {error, _} -> []
                end,
    ConnStats = emqx_pd:get_counters(?CONN_STATS),
    ChanStats = emqx_channel:stats(Channel),
    ProcStats = emqx_misc:proc_stats(),
    lists:append([SockStats, ConnStats, ChanStats, ProcStats]).

%% @doc Set TCP keepalive socket options to override system defaults.
%% Idle: The number of seconds a connection needs to be idle before
%%       TCP begins sending out keep-alive probes (Linux default 7200).
%% Interval: The number of seconds between TCP keep-alive probes
%%           (Linux default 75).
%% Probes: The maximum number of TCP keep-alive probes to send before
%%         giving up and killing the connection if no response is
%%         obtained from the other end (Linux default 9).
%%
%% NOTE: This API sets TCP socket options, which has nothing to do with
%%       the MQTT layer's keepalive (PINGREQ and PINGRESP).
async_set_keepalive(Idle, Interval, Probes) ->
    async_set_keepalive(self(), Idle, Interval, Probes).

async_set_keepalive(Pid, Idle, Interval, Probes) ->
    Options = [ {keepalive, true}
              , {raw, 6, 4, <<Idle:32/native>>}
              , {raw, 6, 5, <<Interval:32/native>>}
              , {raw, 6, 6, <<Probes:32/native>>}
              ],
    async_set_socket_options(Pid, Options).

%% @doc Set custom socket options.
%% This API is made async because the call might be originated from
%% a hookpoint callback (otherwise deadlock).
%% If failed to set, the error message is logged.
async_set_socket_options(Pid, Options) ->
    cast(Pid, {async_set_socket_options, Options}).

cast(Pid, Req) ->
    gen_server:cast(Pid, Req).

call(Pid, Req) ->
    call(Pid, Req, infinity).
call(Pid, Req, Timeout) ->
    gen_server:call(Pid, Req, Timeout).

stop(Pid) ->
    gen_server:stop(Pid).

%%--------------------------------------------------------------------
%% callbacks
%%--------------------------------------------------------------------

init(Parent, Transport, RawSocket, Options) ->
    case Transport:wait(RawSocket) of
        {ok, Socket} ->
            run_loop(Parent, init_state(Transport, Socket, Options));
        {error, Reason} ->
            ok = Transport:fast_close(RawSocket),
            exit_on_sock_error(Reason)
    end.

init_state(Transport, Socket, #{zone := Zone, listener := Listener} = Opts) ->
    {ok, Peername} = Transport:ensure_ok_or_exit(peername, [Socket]),
    {ok, Sockname} = Transport:ensure_ok_or_exit(sockname, [Socket]),
    Peercert = Transport:ensure_ok_or_exit(peercert, [Socket]),
    ConnInfo = #{socktype => Transport:type(Socket),
                 peername => Peername,
                 sockname => Sockname,
                 peercert => Peercert,
                 conn_mod => ?MODULE
                },
    Limiter = emqx_limiter:init(Zone, undefined, undefined, []),
    FrameOpts = #{
        strict_mode => emqx_config:get_zone_conf(Zone, [mqtt, strict_mode]),
        max_size => emqx_config:get_zone_conf(Zone, [mqtt, max_packet_size])
    },
    ParseState = emqx_frame:initial_parse_state(FrameOpts),
    Serialize = emqx_frame:serialize_opts(),
    Channel = emqx_channel:init(ConnInfo, Opts),
    GcState = case emqx_config:get_zone_conf(Zone, [force_gc]) of
        #{enable := false} -> undefined;
        GcPolicy -> emqx_gc:init(GcPolicy)
    end,
    StatsTimer = case emqx_config:get_zone_conf(Zone, [stats, enable]) of
        true -> undefined;
        false -> disabled
    end,
    IdleTimeout = emqx_channel:get_mqtt_conf(Zone, idle_timeout),
    IdleTimer = start_timer(IdleTimeout, idle_timeout),
    #state{transport    = Transport,
           socket       = Socket,
           peername     = Peername,
           sockname     = Sockname,
           sockstate    = idle,
           limiter      = Limiter,
           parse_state  = ParseState,
           serialize    = Serialize,
           channel      = Channel,
           gc_state     = GcState,
           stats_timer  = StatsTimer,
           idle_timeout = IdleTimeout,
           idle_timer   = IdleTimer,
           zone         = Zone,
           listener     = Listener
          }.

run_loop(Parent, State = #state{transport = Transport,
                                socket    = Socket,
                                peername  = Peername,
                                channel   = Channel}) ->
    emqx_logger:set_metadata_peername(esockd:format(Peername)),
    ShutdownPolicy = emqx_config:get_zone_conf(emqx_channel:info(zone, Channel),
            [force_shutdown]),
    emqx_misc:tune_heap_size(ShutdownPolicy),
    case activate_socket(State) of
        {ok, NState} -> hibernate(Parent, NState);
        {error, Reason} ->
            ok = Transport:fast_close(Socket),
            exit_on_sock_error(Reason)
    end.

-spec exit_on_sock_error(any()) -> no_return().
exit_on_sock_error(Reason) when Reason =:= einval;
                                Reason =:= enotconn;
                                Reason =:= closed ->
    erlang:exit(normal);
exit_on_sock_error(timeout) ->
    erlang:exit({shutdown, ssl_upgrade_timeout});
exit_on_sock_error(Reason) ->
    erlang:exit({shutdown, Reason}).

%%--------------------------------------------------------------------
%% Recv Loop

recvloop(Parent, State = #state{idle_timeout = IdleTimeout}) ->
    receive
        Msg ->
            handle_recv(Msg, Parent, State)
    after
        IdleTimeout + 100 ->
            hibernate(Parent, cancel_stats_timer(State))
    end.

handle_recv({system, From, Request}, Parent, State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
handle_recv({'EXIT', Parent, Reason}, Parent, State) ->
    %% FIXME: it's not trapping exit, should never receive an EXIT
    terminate(Reason, State);
handle_recv(Msg, Parent, State = #state{idle_timeout = IdleTimeout}) ->
    case process_msg([Msg], ensure_stats_timer(IdleTimeout, State)) of
        {ok, NewState} ->
            ?MODULE:recvloop(Parent, NewState);
        {stop, Reason, NewSate} ->
            terminate(Reason, NewSate)
    end.

hibernate(Parent, State) ->
    proc_lib:hibernate(?MODULE, wakeup_from_hib, [Parent, State]).

%% Maybe do something here later.
wakeup_from_hib(Parent, State) ->
    ?MODULE:recvloop(Parent, State).

%%--------------------------------------------------------------------
%% Ensure/cancel stats timer

-compile({inline, [ensure_stats_timer/2]}).
ensure_stats_timer(Timeout, State = #state{stats_timer = undefined}) ->
    State#state{stats_timer = start_timer(Timeout, emit_stats)};
ensure_stats_timer(_Timeout, State) -> State.

-compile({inline, [cancel_stats_timer/1]}).
cancel_stats_timer(State = #state{stats_timer = TRef}) when is_reference(TRef) ->
    ?tp(debug, cancel_stats_timer, #{}),
    ok = emqx_misc:cancel_timer(TRef),
    State#state{stats_timer = undefined};
cancel_stats_timer(State) -> State.

%%--------------------------------------------------------------------
%% Process next Msg

process_msg([], State) ->
    {ok, State};
process_msg([Msg|More], State) ->
    try
        case handle_msg(Msg, State) of
            ok ->
                process_msg(More, State);
            {ok, NState} ->
                process_msg(More, NState);
            {ok, Msgs, NState} ->
                process_msg(append_msg(More, Msgs), NState);
            {stop, Reason, NState} ->
                {stop, Reason, NState}
        end
    catch
        exit : normal ->
            {stop, normal, State};
        exit : shutdown ->
            {stop, shutdown, State};
        exit : {shutdown, _} = Shutdown ->
            {stop, Shutdown, State};
        Exception : Context : Stack ->
            {stop, #{exception => Exception,
                     context => Context,
                     stacktrace => Stack}, State}
    end.

-compile({inline, [append_msg/2]}).
append_msg([], Msgs) when is_list(Msgs) ->
    Msgs;
append_msg([], Msg) -> [Msg];
append_msg(Q, Msgs) when is_list(Msgs) ->
    lists:append(Q, Msgs);
append_msg(Q, Msg) ->
    lists:append(Q, [Msg]).

%%--------------------------------------------------------------------
%% Handle a Msg

handle_msg({'$gen_call', From, Req}, State) ->
    case handle_call(From, Req, State) of
        {reply, Reply, NState} ->
            gen_server:reply(From, Reply),
            {ok, NState};
        {stop, Reason, Reply, NState} ->
            gen_server:reply(From, Reply),
            stop(Reason, NState)
    end;
handle_msg({'$gen_cast', Req}, State) ->
    NewState = handle_cast(Req, State),
    {ok, NewState};

handle_msg({Inet, _Sock, Data}, State) when Inet == tcp; Inet == ssl ->
    ?LOG(debug, "RECV ~0p", [Data]),
    Oct = iolist_size(Data),
    inc_counter(incoming_bytes, Oct),
    ok = emqx_metrics:inc('bytes.received', Oct),
    parse_incoming(Data, State);

handle_msg({quic, Data, _Sock, _, _, _}, State) ->
    ?LOG(debug, "RECV ~0p", [Data]),
    Oct = iolist_size(Data),
    inc_counter(incoming_bytes, Oct),
    ok = emqx_metrics:inc('bytes.received', Oct),
    parse_incoming(Data, State);

handle_msg({incoming, Packet = ?CONNECT_PACKET(ConnPkt)},
           State = #state{idle_timer = IdleTimer}) ->
    ok = emqx_misc:cancel_timer(IdleTimer),
    Serialize = emqx_frame:serialize_opts(ConnPkt),
    NState = State#state{serialize  = Serialize,
                         idle_timer = undefined
                        },
    handle_incoming(Packet, NState);

handle_msg({incoming, Packet}, State) ->
    handle_incoming(Packet, State);

handle_msg({outgoing, Packets}, State) ->
    handle_outgoing(Packets, State);

handle_msg({Error, _Sock, Reason}, State)
  when Error == tcp_error; Error == ssl_error ->
    handle_info({sock_error, Reason}, State);

handle_msg({Closed, _Sock}, State)
  when Closed == tcp_closed; Closed == ssl_closed ->
    handle_info({sock_closed, Closed}, close_socket(State));

handle_msg({Passive, _Sock}, State)
  when Passive == tcp_passive; Passive == ssl_passive; Passive =:= quic_passive ->
    %% In Stats
    Pubs = emqx_pd:reset_counter(incoming_pubs),
    Bytes = emqx_pd:reset_counter(incoming_bytes),
    InStats = #{cnt => Pubs, oct => Bytes},
    %% Ensure Rate Limit
    NState = ensure_rate_limit(InStats, State),
    %% Run GC and Check OOM
    NState1 = check_oom(run_gc(InStats, NState)),
    handle_info(activate_socket, NState1);

handle_msg(Deliver = {deliver, _Topic, _Msg}, #state{
        listener = {Type, Listener}} = State) ->
    ActiveN = get_active_n(Type, Listener),
    Delivers = [Deliver|emqx_misc:drain_deliver(ActiveN)],
    with_channel(handle_deliver, [Delivers], State);

%% Something sent
handle_msg({inet_reply, _Sock, ok}, State = #state{listener = {Type, Listener}}) ->
    case emqx_pd:get_counter(outgoing_pubs) > get_active_n(Type, Listener) of
        true ->
            Pubs = emqx_pd:reset_counter(outgoing_pubs),
            Bytes = emqx_pd:reset_counter(outgoing_bytes),
            OutStats = #{cnt => Pubs, oct => Bytes},
            {ok, check_oom(run_gc(OutStats, State))};
        false -> ok
    end;

handle_msg({inet_reply, _Sock, {error, Reason}}, State) ->
    handle_info({sock_error, Reason}, State);

handle_msg({connack, ConnAck}, State) ->
    handle_outgoing(ConnAck, State);

handle_msg({close, Reason}, State) ->
    ?LOG(debug, "Force to close the socket due to ~p", [Reason]),
    handle_info({sock_closed, Reason}, close_socket(State));

handle_msg({event, connected}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:insert_channel_info(ClientId, info(State), stats(State));

handle_msg({event, disconnected}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_info(ClientId, info(State)),
    emqx_cm:connection_closed(ClientId),
    {ok, State};

handle_msg({event, _Other}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_info(ClientId, info(State)),
    emqx_cm:set_chan_stats(ClientId, stats(State)),
    {ok, State};

handle_msg({timeout, TRef, TMsg}, State) ->
    handle_timeout(TRef, TMsg, State);

handle_msg(Shutdown = {shutdown, _Reason}, State) ->
    stop(Shutdown, State);

handle_msg(Msg, State) ->
    handle_info(Msg, State).

%%--------------------------------------------------------------------
%% Terminate

-spec terminate(any(), state()) -> no_return().
terminate(Reason, State = #state{channel = Channel, transport = Transport,
          socket = Socket}) ->
    try
        Channel1 = emqx_channel:set_conn_state(disconnected, Channel),
        emqx_congestion:cancel_alarms(Socket, Transport, Channel1),
        emqx_channel:terminate(Reason, Channel1),
        close_socket_ok(State)
    catch
        E : C : S ->
            ?tp(warning, unclean_terminate, #{exception => E, context => C, stacktrace => S})
    end,
    ?tp(info, terminate, #{reason => Reason}),
    maybe_raise_excption(Reason).

%% close socket, discard new state, always return ok.
close_socket_ok(State) ->
    _ = close_socket(State),
    ok.

%% tell truth about the original exception
maybe_raise_excption(#{exception := Exception,
                       context := Context,
                       stacktrace := Stacktrace
                      }) ->
    erlang:raise(Exception, Context, Stacktrace);
maybe_raise_excption(Reason) ->
    exit(Reason).

%%--------------------------------------------------------------------
%% Sys callbacks

system_continue(Parent, _Debug, State) ->
    ?MODULE:recvloop(Parent, State).

system_terminate(Reason, _Parent, _Debug, State) ->
    terminate(Reason, State).

system_code_change(State, _Mod, _OldVsn, _Extra) ->
    {ok, State}.

system_get_state(State) -> {ok, State}.

%%--------------------------------------------------------------------
%% Handle call

handle_call(_From, info, State) ->
    {reply, info(State), State};

handle_call(_From, stats, State) ->
    {reply, stats(State), State};

handle_call(_From, {ratelimit, Policy}, State = #state{channel = Channel}) ->
    Zone = emqx_channel:info(zone, Channel),
    Limiter = emqx_limiter:init(Zone, Policy),
    {reply, ok, State#state{limiter = Limiter}};

handle_call(_From, Req, State = #state{channel = Channel}) ->
    case emqx_channel:handle_call(Req, Channel) of
        {reply, Reply, NChannel} ->
            {reply, Reply, State#state{channel = NChannel}};
        {shutdown, Reason, Reply, NChannel} ->
            shutdown(Reason, Reply, State#state{channel = NChannel});
        {shutdown, Reason, Reply, OutPacket, NChannel} ->
            NState = State#state{channel = NChannel},
            ok = handle_outgoing(OutPacket, NState),
            shutdown(Reason, Reply, NState)
    end.

%%--------------------------------------------------------------------
%% Handle timeout

handle_timeout(_TRef, idle_timeout, State) ->
    shutdown(idle_timeout, State);

handle_timeout(_TRef, limit_timeout, State) ->
    NState = State#state{sockstate   = idle,
                         limit_timer = undefined
                        },
    handle_info(activate_socket, NState);

handle_timeout(_TRef, emit_stats, State = #state{channel = Channel, transport = Transport,
        socket = Socket}) ->
    emqx_congestion:maybe_alarm_conn_congestion(Socket, Transport, Channel),
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_stats(ClientId, stats(State)),
    {ok, State#state{stats_timer = undefined}};

handle_timeout(TRef, keepalive, State = #state{transport = Transport,
                                               socket = Socket,
                                               channel = Channel})->
    case emqx_channel:info(conn_state, Channel) of
        disconnected -> {ok, State};
        _ ->
            case Transport:getstat(Socket, [recv_oct]) of
                {ok, [{recv_oct, RecvOct}]} ->
                    handle_timeout(TRef, {keepalive, RecvOct}, State);
                {error, Reason} ->
                    handle_info({sock_error, Reason}, State)
            end
    end;

handle_timeout(TRef, Msg, State) ->
    with_channel(handle_timeout, [TRef, Msg], State).

%%--------------------------------------------------------------------
%% Parse incoming data

-compile({inline, [parse_incoming/2]}).
parse_incoming(Data, State) ->
    {Packets, NState} = parse_incoming(Data, [], State),
    {ok, next_incoming_msgs(Packets), NState}.

parse_incoming(<<>>, Packets, State) ->
    {Packets, State};

parse_incoming(Data, Packets, State = #state{parse_state = ParseState}) ->
    try emqx_frame:parse(Data, ParseState) of
        {more, NParseState} ->
            {Packets, State#state{parse_state = NParseState}};
        {ok, Packet, Rest, NParseState} ->
            NState = State#state{parse_state = NParseState},
            parse_incoming(Rest, [Packet|Packets], NState)
    catch
        error:Reason:Stk ->
            ?LOG(error, "~nParse failed for ~0p~n~0p~nFrame data:~0p",
                 [Reason, Stk, Data]),
            {[{frame_error, Reason}|Packets], State}
    end.

-compile({inline, [next_incoming_msgs/1]}).
next_incoming_msgs([Packet]) ->
    {incoming, Packet};
next_incoming_msgs(Packets) ->
    [{incoming, Packet} || Packet <- lists:reverse(Packets)].

%%--------------------------------------------------------------------
%% Handle incoming packet

handle_incoming(Packet, State) when is_record(Packet, mqtt_packet) ->
    ok = inc_incoming_stats(Packet),
    ?LOG(debug, "RECV ~s", [emqx_packet:format(Packet)]),
    with_channel(handle_in, [Packet], State);

handle_incoming(FrameError, State) ->
    with_channel(handle_in, [FrameError], State).

%%--------------------------------------------------------------------
%% With Channel

with_channel(Fun, Args, State = #state{channel = Channel}) ->
    case erlang:apply(emqx_channel, Fun, Args ++ [Channel]) of
        ok -> {ok, State};
        {ok, NChannel} ->
            {ok, State#state{channel = NChannel}};
        {ok, Replies, NChannel} ->
            {ok, next_msgs(Replies), State#state{channel = NChannel}};
        {shutdown, Reason, NChannel} ->
            shutdown(Reason, State#state{channel = NChannel});
        {shutdown, Reason, Packet, NChannel} ->
            NState = State#state{channel = NChannel},
            ok = handle_outgoing(Packet, NState),
            shutdown(Reason, NState)
    end.

%%--------------------------------------------------------------------
%% Handle outgoing packets

handle_outgoing(Packets, State) when is_list(Packets) ->
    send(lists:map(serialize_and_inc_stats_fun(State), Packets), State);

handle_outgoing(Packet, State) ->
    send((serialize_and_inc_stats_fun(State))(Packet), State).

serialize_and_inc_stats_fun(#state{serialize = Serialize}) ->
    fun(Packet) ->
        case emqx_frame:serialize_pkt(Packet, Serialize) of
            <<>> -> ?LOG(warning, "~s is discarded due to the frame is too large!",
                         [emqx_packet:format(Packet)]),
                    ok = emqx_metrics:inc('delivery.dropped.too_large'),
                    ok = emqx_metrics:inc('delivery.dropped'),
                    <<>>;
            Data -> ?LOG(debug, "SEND ~s", [emqx_packet:format(Packet)]),
                    ok = inc_outgoing_stats(Packet),
                    Data
        end
    end.

%%--------------------------------------------------------------------
%% Send data

-spec(send(iodata(), state()) -> ok).
send(IoData, #state{transport = Transport, socket = Socket, channel = Channel}) ->
    Oct = iolist_size(IoData),
    ok = emqx_metrics:inc('bytes.sent', Oct),
    inc_counter(outgoing_bytes, Oct),
    emqx_congestion:maybe_alarm_conn_congestion(Socket, Transport, Channel),
    case Transport:async_send(Socket, IoData, [nosuspend]) of
        ok -> ok;
        Error = {error, _Reason} ->
            %% Send an inet_reply to postpone handling the error
            self() ! {inet_reply, Socket, Error},
            ok
    end.

%%--------------------------------------------------------------------
%% Handle Info

handle_info(activate_socket, State = #state{sockstate = OldSst}) ->
    case activate_socket(State) of
        {ok, NState = #state{sockstate = NewSst}} ->
            case OldSst =/= NewSst of
                true -> {ok, {event, NewSst}, NState};
                false -> {ok, NState}
            end;
        {error, Reason} ->
            handle_info({sock_error, Reason}, State)
    end;

handle_info({sock_error, Reason}, State) ->
    case Reason =/= closed andalso Reason =/= einval of
        true -> ?LOG(warning, "socket_error: ~p", [Reason]);
        false -> ok
    end,
    handle_info({sock_closed, Reason}, close_socket(State));

handle_info({quic, peer_send_shutdown, _Stream}, State) ->
    handle_info({sock_closed, force}, close_socket(State));

handle_info({quic, closed, _Channel, ReasonFlag}, State) ->
    handle_info({sock_closed, ReasonFlag}, State);

handle_info({quic, closed, _Stream}, State) ->
    handle_info({sock_closed, force}, State);

handle_info(Info, State) ->
    with_channel(handle_info, [Info], State).

%%--------------------------------------------------------------------
%% Handle Info

handle_cast({async_set_socket_options, Opts},
            State = #state{transport = Transport,
                           socket    = Socket
                          }) ->
    case Transport:setopts(Socket, Opts) of
        ok -> ?tp(info, "custom_socket_options_successfully", #{opts => Opts});
        Err -> ?tp(error, "failed_to_set_custom_socket_optionn", #{reason => Err})
    end,
    State;
handle_cast(Req, State) ->
    ?tp(error, "received_unknown_cast", #{cast => Req}),
    State.

%%--------------------------------------------------------------------
%% Ensure rate limit

ensure_rate_limit(Stats, State = #state{limiter = Limiter}) ->
    case ?ENABLED(Limiter) andalso emqx_limiter:check(Stats, Limiter) of
        false -> State;
        {ok, Limiter1} ->
            State#state{limiter = Limiter1};
        {pause, Time, Limiter1} ->
            ?LOG(warning, "Pause ~pms due to rate limit", [Time]),
            TRef = start_timer(Time, limit_timeout),
            State#state{sockstate   = blocked,
                        limiter     = Limiter1,
                        limit_timer = TRef
                       }
    end.

%%--------------------------------------------------------------------
%% Run GC and Check OOM

run_gc(Stats, State = #state{gc_state = GcSt}) ->
    case ?ENABLED(GcSt) andalso emqx_gc:run(Stats, GcSt) of
        false -> State;
        {_IsGC, GcSt1} ->
            State#state{gc_state = GcSt1}
    end.

check_oom(State = #state{channel = Channel}) ->
    ShutdownPolicy = emqx_config:get_zone_conf(
        emqx_channel:info(zone, Channel), [force_shutdown]),
    ?tp(debug, check_oom, #{policy => ShutdownPolicy}),
    case emqx_misc:check_oom(ShutdownPolicy) of
        {shutdown, Reason} ->
            %% triggers terminate/2 callback immediately
            erlang:exit({shutdown, Reason});
        _ -> ok
    end,
    State.

%%--------------------------------------------------------------------
%% Activate Socket

-compile({inline, [activate_socket/1]}).
activate_socket(State = #state{sockstate = closed}) ->
    {ok, State};
activate_socket(State = #state{sockstate = blocked}) ->
    {ok, State};
activate_socket(State = #state{transport = Transport, socket = Socket,
        listener = {Type, Listener}}) ->
    ActiveN = get_active_n(Type, Listener),
    case Transport:setopts(Socket, [{active, ActiveN}]) of
        ok -> {ok, State#state{sockstate = running}};
        Error -> Error
    end.

%%--------------------------------------------------------------------
%% Close Socket

close_socket(State = #state{sockstate = closed}) -> State;
close_socket(State = #state{transport = Transport, socket = Socket}) ->
    ok = Transport:fast_close(Socket),
    State#state{sockstate = closed}.

%%--------------------------------------------------------------------
%% Inc incoming/outgoing stats

-compile({inline, [inc_incoming_stats/1]}).
inc_incoming_stats(Packet = ?PACKET(Type)) ->
    inc_counter(recv_pkt, 1),
    case Type =:= ?PUBLISH of
        true ->
            inc_counter(recv_msg, 1),
            inc_counter(incoming_pubs, 1);
        false ->
            ok
    end,
    emqx_metrics:inc_recv(Packet).

-compile({inline, [inc_outgoing_stats/1]}).
inc_outgoing_stats(Packet = ?PACKET(Type)) ->
    inc_counter(send_pkt, 1),
    case Type =:= ?PUBLISH of
        true ->
            inc_counter(send_msg, 1),
            inc_counter(outgoing_pubs, 1);
        false ->
            ok
    end,
    emqx_metrics:inc_sent(Packet).

%%--------------------------------------------------------------------
%% Helper functions

-compile({inline, [next_msgs/1]}).
next_msgs(Packet) when is_record(Packet, mqtt_packet) ->
    {outgoing, Packet};
next_msgs(Event) when is_tuple(Event) ->
    Event;
next_msgs(More) when is_list(More) ->
    More.

-compile({inline, [shutdown/2, shutdown/3]}).
shutdown(Reason, State) ->
    stop({shutdown, Reason}, State).

shutdown(Reason, Reply, State) ->
    stop({shutdown, Reason}, Reply, State).

-compile({inline, [stop/2, stop/3]}).
stop(Reason, State) ->
    {stop, Reason, State}.

stop(Reason, Reply, State) ->
    {stop, Reason, Reply, State}.

inc_counter(Key, Inc) ->
    _ = emqx_pd:inc_counter(Key, Inc),
    ok.

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, State) ->
    Pos = emqx_misc:index_of(Name, record_info(fields, state)),
    setelement(Pos+1, State, Value).

get_state(Pid) ->
    State = sys:get_state(Pid),
    maps:from_list(lists:zip(record_info(fields, state),
                             tl(tuple_to_list(State)))).

get_active_n(quic, _Listener) -> 100;
get_active_n(Type, Listener) ->
    emqx_config:get_listener_conf(Type, Listener, [tcp, active_n]).
