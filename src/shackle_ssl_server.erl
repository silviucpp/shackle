-module(shackle_ssl_server).
-include("shackle_internal.hrl").

-compile(inline).
-compile({inline_size, 512}).

-export([
    start_link/4
]).

-behavior(metal).
-export([
    init/3,
    handle_msg/2,
    terminate/2
]).

-record(state, {
    client           :: client(),
    init_options     :: init_options(),
    ip               :: inet:ip_address() | inet:hostname(),
    name             :: server_name(),
    parent           :: pid(),
    pool_name        :: pool_name(),
    port             :: inet:port_number(),
    reconnect_state  :: undefined | reconnect_state(),
    socket           :: undefined | ssl:sslsocket(),
    socket_options   :: [ssl:connect_option()],
    timer_ref        :: undefined | reference(),
    monitor_pid      :: undefined | pid()
}).

-type init_opts() :: {pool_name(), client(), client_options()}.
-type state() :: #state {}.

%% public
-spec start_link(server_name(), pool_name(), client(), client_options()) ->
    {ok, pid()}.

start_link(Name, PoolName, Client, ClientOptions) ->
    Args = {PoolName, Client, ClientOptions},
    metal:start_link(?MODULE, Name, Args).

%% metal callbacks
-spec init(server_name(), pid(), init_opts()) ->
    no_return().

init(Name, Parent, Opts) ->
    {PoolName, Client, ClientOptions} = Opts,
    self() ! ?MSG_CONNECT,
    ok = shackle_backlog:new(Name),

    InitOptions = ?LOOKUP(init_options, ClientOptions,
        ?DEFAULT_INIT_OPTS),
    Ip = ?LOOKUP(ip, ClientOptions, ?DEFAULT_IP),
    Port = ?LOOKUP(port, ClientOptions),
    ReconnectState = ?SERVER_UTILS:reconnect_state(ClientOptions),
    SocketOptions = ?LOOKUP(socket_options, ClientOptions,
        ?DEFAULT_SOCKET_OPTS),

    MonitorPid = ?LOOKUP(monitor_pid, ClientOptions),

    {ok, {#state {
        client = Client,
        init_options = InitOptions,
        ip = Ip,
        name = Name,
        parent = Parent,
        pool_name = PoolName,
        port = Port,
        reconnect_state = ReconnectState,
        socket_options = SocketOptions,
        monitor_pid = MonitorPid
    }, undefined}}.

-spec handle_msg(term(), {state(), client_state()}) ->
    {ok, term()}.

handle_msg({_, #cast {} = Cast}, {#state {
        socket = undefined,
        name = Name
    } = State, ClientState}) ->

    ?SERVER_UTILS:reply(Name, {error, no_socket}, Cast),
    {ok, {State, ClientState}};
handle_msg({Request, #cast {
        timeout = Timeout
    } = Cast}, {#state {
        client = Client,
        name = Name,
        pool_name = PoolName,
        socket = Socket
    } = State, ClientState}) ->

    try Client:handle_request(Request, ClientState) of
        {ok, ExtRequestId, Data, ClientState2} ->
            case ssl:send(Socket, Data) of
                ok ->
                    Msg = {timeout, ExtRequestId},
                    TimerRef = erlang:send_after(Timeout, self(), Msg),
                    shackle_queue:add(ExtRequestId, Cast, TimerRef),
                    {ok, {State, ClientState2}};
                {error, Reason} ->
                    ?WARN(PoolName, "send error: ~p", [Reason]),
                    ssl:close(Socket),
                    ?SERVER_UTILS:reply(Name, {error, socket_closed}, Cast),
                    close(State, ClientState2)
            end
    catch
        E:R ->
            ?WARN(PoolName, "handle_request crash: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()]),
            ?SERVER_UTILS:reply(Name, {error, client_crash}, Cast),
            {ok, {State, ClientState}}
    end;
handle_msg({ssl, Socket, Data}, {#state {
        client = Client,
        name = Name,
        pool_name = PoolName,
        socket = Socket
    } = State, ClientState}) ->

    try Client:handle_data(Data, ClientState) of
        {ok, Replies, ClientState2} ->
            ?SERVER_UTILS:process_responses(Replies, Name),
            {ok, {State, ClientState2}};
        {error, Reason, ClientState2} ->
            ?WARN(PoolName, "handle_data error: ~p", [Reason]),
            ssl:close(Socket),
            close(State, ClientState2)
    catch
        E:R ->
            ?WARN(PoolName, "handle_data crash: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()]),
            ssl:close(Socket),
            close(State, ClientState)
    end;
handle_msg({timeout, ExtRequestId}, {#state {
        name = Name
    } = State, ClientState}) ->

    case shackle_queue:remove(Name, ExtRequestId) of
        {ok, Cast, _TimerRef} ->
            ?SERVER_UTILS:reply(Name, {error, timeout}, Cast);
        {error, not_found} ->
            ok
    end,
    {ok, {State, ClientState}};
handle_msg({ssl_closed, Socket}, {#state {
        socket = Socket
    } = State, ClientState}) ->
    close(State, ClientState);
handle_msg({ssl_error, Socket, Reason}, {#state {
        socket = Socket,
        pool_name = PoolName
    } = State, ClientState}) ->

    ?WARN(PoolName, "connection error: ~p", [Reason]),
    ssl:close(Socket),
    close(State, ClientState);
handle_msg(?MSG_CONNECT, {#state {
        client = Client,
        init_options = Init,
        ip = Ip,
        pool_name = PoolName,
        port = Port,
        reconnect_state = ReconnectState,
        socket_options = SocketOptions,
        monitor_pid = MonitorPid
    } = State, ClientState}) ->

    case connect(PoolName, Ip, Port, SocketOptions) of
        {ok, Socket} ->
            case ?SERVER_UTILS:client(Client, PoolName, Init, ssl, Socket) of
                {ok, ClientState2} ->
                    shackle_server_utils:connection_notification(MonitorPid, true),

                    ReconnectState2 =
                        ?SERVER_UTILS:reconnect_state_reset(ReconnectState),

                    {ok, {State#state {
                        reconnect_state = ReconnectState2,
                        socket = Socket
                    }, ClientState2}};
                {error, _Reason, ClientState2} ->
                    ssl:close(Socket),
                    reconnect(State, ClientState2)
            end;
        {error, _Reason} ->
            reconnect(State, ClientState)
    end;
handle_msg(Msg, {#state {
        pool_name = PoolName
    } = State, ClientState}) ->

    ?WARN(PoolName, "unknown msg: ~p", [Msg]),
    {ok, {State, ClientState}}.

-spec terminate(term(), term()) ->
    ok.

terminate(_Reason, {#state {
        client = Client,
        name = Name,
        pool_name = PoolName,
        timer_ref = TimerRef,
        monitor_pid = MonitorPid
    }, ClientState}) ->

    ?SERVER_UTILS:cancel_timer(TimerRef),
    try Client:terminate(ClientState)
    catch
        E:R ->
            ?WARN(PoolName, "terminate crash: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()])
    end,

    shackle_server_utils:connection_notification(MonitorPid, false),
    ?SERVER_UTILS:reply_all(Name, {error, shutdown}),
    shackle_backlog:delete(Name),
    ok.

%% private
close(#state {name = Name, monitor_pid = MonitorPid} = State, ClientState) ->
    ?SERVER_UTILS:reply_all(Name, {error, socket_closed}),
    shackle_server_utils:connection_notification(MonitorPid, false),
    reconnect(State, ClientState).

connect(PoolName, Ip, Port, SocketOptions) ->
    case inet:getaddrs(Ip, inet) of
        {ok, Addrs} ->
            Ip2 = shackle_utils:random_element(Addrs),
            case ssl:connect(Ip2, Port, SocketOptions,
                    ?DEFAULT_CONNECT_TIMEOUT) of
                {ok, Socket} ->
                    {ok, Socket};
                {error, Reason} ->
                    ?WARN(PoolName, "connect error: ~p", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            ?WARN(PoolName, "getaddrs error: ~p", [Reason]),
            {error, Reason}
    end.

reconnect(State, undefined) ->
    reconnect_timer(State, undefined);
reconnect(#state {
        client = Client,
        pool_name = PoolName
    } = State, ClientState) ->

    try Client:terminate(ClientState)
    catch
        E:R ->
            ?WARN(PoolName, "terminate crash: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()])
    end,
    reconnect_timer(State, ClientState).

reconnect_timer(#state {
        reconnect_state = undefined
    } = State, ClientState) ->

    {ok, {State#state {
        socket = undefined
    }, ClientState}};
reconnect_timer(#state {
        reconnect_state = ReconnectState
    } = State, ClientState)  ->

    ReconnectState2 = shackle_backoff:timeout(ReconnectState),
    #reconnect_state {current = Current} = ReconnectState2,
    TimerRef = erlang:send_after(Current, self(), ?MSG_CONNECT),

    {ok, {State#state {
        reconnect_state = ReconnectState2,
        socket = undefined,
        timer_ref = TimerRef
    }, ClientState}}.
