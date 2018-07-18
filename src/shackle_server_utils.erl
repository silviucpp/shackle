-module(shackle_server_utils).
-include("shackle_internal.hrl").

-compile(inline).
-compile({inline_size, 512}).

%% public
-export([
    cancel_timer/1,
    client/5,
    process_responses/2,
    reconnect_state/1,
    reconnect_state_reset/1,
    reply/3,
    reply_all/2,
    connection_notification/2
]).

%% public
-spec cancel_timer(undefined | reference()) ->
    ok.

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) ->
    erlang:cancel_timer(TimerRef).

-spec client(client(), pool_name(), init_options(), socket_type(), socket()) ->
    {ok, client_state()} | {error, term(), client_state()}.

client(Client, PoolName, InitOptions, SocketType, Socket) ->
    case client_init(Client, PoolName, InitOptions) of
        {ok, ClientState} ->
            client_setup(Client, PoolName, SocketType, Socket, ClientState);
        {error, Reason} ->
            {error, Reason, undefined}
    end.

-spec process_responses([response()], server_name()) ->
    ok.

process_responses([], _Name) ->
    ok;
process_responses([{ExtRequestId, Reply} | T], Name) ->
    case shackle_queue:remove(Name, ExtRequestId) of
        {ok, Cast, TimerRef} ->
            erlang:cancel_timer(TimerRef),
            reply(Name, Reply, Cast);
        {error, not_found} ->
            ok
    end,
    process_responses(T, Name).

-spec reconnect_state(client_options()) ->
    undefined | reconnect_state().

reconnect_state(Options) ->
    Reconnect = ?LOOKUP(reconnect, Options, ?DEFAULT_RECONNECT),
    case Reconnect of
        true ->
            Max = ?LOOKUP(reconnect_time_max, Options,
                ?DEFAULT_RECONNECT_MAX),
            Min = ?LOOKUP(reconnect_time_min, Options,
                ?DEFAULT_RECONNECT_MIN),

            #reconnect_state {
                min = Min,
                max = Max
            };
        false ->
            undefined
    end.

-spec reconnect_state_reset(undefined | reconnect_state()) ->
    undefined | reconnect_state().

reconnect_state_reset(undefined) ->
    undefined;
reconnect_state_reset(#reconnect_state {} = ReconnectState) ->
    ReconnectState#reconnect_state {
        current = undefined
    }.

-spec reply(server_name(), term(), undefined | cast()) ->
    ok.

reply(Name, _Reply, #cast {pid = undefined}) ->
    shackle_backlog:decrement(Name),
    ok;
reply(Name, Reply, #cast {pid = Pid} = Cast) ->
    shackle_backlog:decrement(Name),
    Pid ! {Cast, Reply},
    ok.

-spec reply_all(server_name(), term()) ->
    ok.

reply_all(Name, Reply) ->
    reply_all(Name, Reply, shackle_queue:clear(Name)).

-spec connection_notification(undefined | pid(), boolean()) ->
    ok.

connection_notification(undefined, _) ->
    ok;
connection_notification(Pid, IsUp) ->
    Pid ! {shackle_connection_notification, self(), IsUp}.

%% private
client_init(Client, PoolName, InitOptions) ->
    try Client:init(InitOptions) of
        {ok, ClientState} ->
            {ok, ClientState};
        {error, Reason} ->
            ?WARN(PoolName, "init error: ~p~n", [Reason]),
            {error, Reason}
    catch
        E:R ->
            ?WARN(PoolName, "init crash: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()]),
            {error, client_crash}
    end.

client_setup(Client, PoolName, SocketType, Socket, ClientState) ->
    SocketType:setopts(Socket, [{active, false}]),
    try Client:setup(Socket, ClientState) of
        {ok, ClientState2} ->
            SocketType:setopts(Socket, [{active, true}]),
            {ok, ClientState2};
        {error, Reason, ClientState2} ->
            ?WARN(PoolName, "setup error: ~p", [Reason]),
            {error, Reason, ClientState2}
    catch
        E:R ->
            ?WARN(PoolName, "handle_data error: ~p:~p~n~p~n",
                [E, R, erlang:get_stacktrace()]),
            {error, client_crash, ClientState}
    end.

reply_all(_Name, _Reply, []) ->
    ok;
reply_all(Name, Reply, [{Cast, TimerRef} | T]) ->
    erlang:cancel_timer(TimerRef),
    reply(Name, Reply, Cast),
    reply_all(Name, Reply, T).
