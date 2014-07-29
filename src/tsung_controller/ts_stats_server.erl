%%%-------------------------------------------------------------------
%%% @author jiaozhihui@corp.netease.com
%%% @copyright 2014 NetEase
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ts_stats_server).

-behaviour(gen_server).

-include("ts_config.hrl").

%% API
-export([start_link/1, get_id/2, done/3, start_stats/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {log, parent, time, dump_interval, backend, args}).

-define(STATSPROCS, [request, connect, page, transaction, ts_stats_mon]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Parent) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Parent], []).

get_id(Prefix, Id) ->
    list_to_atom(Prefix ++ atom_to_list(Id)).

done(Id, Time, Data) ->
    gen_server:cast(?MODULE, {done, Id, Time, Data}).

start_stats(Backend, Args) ->
    gen_server:call(?MODULE, {start_stats, Backend, Args}).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Parent]) ->
    {ok, #state{parent = Parent, dump_interval = ?config(dumpstats_interval)}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({start_stats, Backend, Args = {Log, _}}, _From,
            State = #state{dump_interval = DumpInterval, parent = Parent}) ->
    ?LOGF("start_stats: ~p~n", [DumpInterval], ?NOTICE),
    Timestamp = ts_utils:now_sec(),
    NamePrefix = integer_to_list(Timestamp div 10),
    lists:foreach(fun(Type) -> StatId = get_id(NamePrefix, Type),
                Stat = {StatId, {ts_stats_mon, start, [StatId, Type]},
                        transient, 2000, worker, [ts_stats_mon]},
                supervisor:start_child(Parent, Stat),
                ts_stats_mon:set_output(Backend, Args, StatId) end, ?STATSPROCS),

    ts_mon:set_time(NamePrefix),

    erlang:start_timer(DumpInterval, self(), new_stats),
    {reply, ok, State#state{time = Timestamp, backend = Backend,
                            log = Log, args = Args}};

handle_call(_Request, _From, State) ->
    ?LOGF("stats_server_unknown_msg(call) ~p~n", [_Request], ?NOTICE),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({done, _Id, Time, Data}, State = #state{log = Log}) ->
    {WaitStatus, DataList}= get({wait_result, Time}),
    NewDataList = [Data|DataList],
    NewWaitStatus = WaitStatus + 1,
    ?LOGF("stats_done: ~p ~p ~p~n", [NewWaitStatus, _Id, Time], ?NOTICE),
    case NewWaitStatus of
        5 ->
            Timestamp = ts_utils:now_sec(),
            io:format(Log, "# stats: dump at ~w ~w~n", [Time, Timestamp]),
            lists:foreach(fun(Entry) ->
                        ts_stats_mon:export_stats(Log, Entry) end, NewDataList),
            erase({wait_result, Time});
        _ -> put({wait_result, Time}, {NewWaitStatus, NewDataList})
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    ?LOGF("stats_server_unknown_msg(cast) ~p~n", [_Msg], ?NOTICE),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({timeout, _Ref, new_stats},
            State = #state{time = PreTime, parent = Parent,
                           backend = Backend, args = Args,
                           dump_interval = DumpInterval}) ->
    Timestamp = ts_utils:now_sec(),
    ?LOGF("start_new_stat_server: ~p~n", [Timestamp], ?ERR),
    NamePrefix = integer_to_list(Timestamp div 10),
   
    lists:foreach(fun(Type) -> StatId = get_id(NamePrefix, Type),
                Stat = {StatId, {ts_stats_mon, start, [StatId, Type]},
                        transient, 2000, worker, [ts_stats_mon]},
                supervisor:start_child(Parent, Stat),
                ts_stats_mon:set_output(Backend, Args, StatId) end, ?STATSPROCS),

    ts_mon:set_time(NamePrefix),

    put({wait_result, PreTime}, {0, []}),

    lists:foreach(fun(Type) ->
                NP = integer_to_list(PreTime div 10),
                StatId = get_id(NP, Type),
                ts_stats_mon:wait(PreTime, StatId) end, ?STATSPROCS),


    ?LOGF("new_stat_server_started: ~p~n", [ts_utils:now_sec()], ?ERR),
    erlang:start_timer(DumpInterval, self(), new_stats),
    {noreply, State#state{time = Timestamp}};

handle_info(UnknownMsg, State) ->
    ?LOGF("stats_server_unknown_msg(info) ~p~n", [UnknownMsg], ?NOTICE),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ?LOGF("stats_server_stopped ~p~n", [_Reason], ?NOTICE),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
