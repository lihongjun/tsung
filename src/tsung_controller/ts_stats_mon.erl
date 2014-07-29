%%%
%%%  Copyright (C) 2007 Nicolas Niclausse
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
%%%
%%%  In addition, as a special exception, you have the permission to
%%%  link the code of this program with any library released under
%%%  the EPL license and distribute linked combinations including
%%%  the two; the MPL (Mozilla Public License), which EPL (Erlang
%%%  Public License) is based on, is included in this exception.


%%----------------------------------------------------------------------
%% @copyright 2007-2008 Nicolas Niclausse
%% @author Nicolas Niclausse <nicolas@niclux.org>
%% @since 20 Nov 2007
%% @doc computes statistics for request, page, connect, transactions,
%% data size, errors, ... and other stats specific to plugins
%% ----------------------------------------------------------------------

-module(ts_stats_mon).
-author('nicolas@niclux.org').
-vc('$Id: ts_mon.erl 774 2007-11-20 09:36:13Z nniclausse $ ').

-behaviour(gen_server).

-include("ts_config.hrl").

%% External exports, API
-export([start/0, start/2, stop/0, stop/1,
         add/1, add/2, add/3, dumpstats/0, dumpstats/1,
         set_output/2, set_output/3,
         status/1, status/2, wait/2]).

%% More external exports for ts_mon
-export([update_stats/3, add_stats_data/2, reset_all_stats/1]).
-export([print_stats/3]).
-export([export_stats/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {log,          % log fd
                backend,      % type of backend: text|rrdtool|fullstats
                dump_interval,%
                type = ts_stats_mon, % type of stats
                fullstats,    % fullstats fd
                stats,        % dict keeping stats info
                laststats     % values of last printed stats
               }).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec start(Id::term()) -> ok | throw({error, Reason})
%% @doc Start the monitoring process
%%----------------------------------------------------------------------
start(Id, Type) ->
    ?LOGF("starting ~p stats server, global ~p~n",[Id, Type],?INFO),
    gen_server:start_link({local, Id}, ?MODULE, [Id, Type], []).

start() ->
    ?LOG("starting stats server, global ~n",?INFO),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [?MODULE], []).

stop(Id) ->
    gen_server:cast(Id, {stop}).

stop() ->
    gen_server:cast(?MODULE, {stop}).

wait(Time, Id) ->
    gen_server:cast(Id, {wait, Id, Time}).

add([]) -> ok;
add(Data) ->
    gen_server:cast(?MODULE, {add, Data}).

add([], _Id) -> ok;
add(Data, Id) ->
    gen_server:cast(Id, {add, Data}).

add([], _Id, _Node) -> ok;
add(Data, Id, Node) ->
    gen_server:cast({Id, Node}, {add, Data}).

status(Name,Type) ->
    gen_server:call(?MODULE, {status, Name, Type}).
status(Id) ->
    gen_server:call(Id, {status}).

dumpstats() ->
    gen_server:cast(?MODULE, {dumpstats}).
dumpstats(Id) ->
    gen_server:cast(Id, {dumpstats}).

set_output(BackEnd,Stream) ->
    set_output(BackEnd,Stream,?MODULE).

set_output(BackEnd,Stream,Id) ->
    gen_server:cast(Id, {set_output, BackEnd, Stream}).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
%% single type of data: don't need a dict, a simple list can store the data
init([Id, Type]) when Type == 'connect'; Type == 'page'; Type == 'request' ->
    ?LOGF("starting dedicated stats server for ~p ~p~n",[Type, Id],?INFO),
    Stats = [0,0,0,0,0,0,0,0],
    {ok, #state{ dump_interval = ?config(dumpstats_interval),
                 stats     = Stats,
                 type      = Type,
                 laststats = Stats
                }};
%% id = transaction or ?MODULE: it can handle several types of stats, must use a dict.
init([Id, Type]) ->
    ?LOGF("starting ~p stats server ~p~n",[Type, Id],?INFO),
    Tab = dict:new(),
    {ok, #state{ dump_interval = ?config(dumpstats_interval),
                 stats   = Tab,
                 type    = Type,
                 laststats = Tab
                }}.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call({status}, _From, State=#state{stats=Stats} ) when is_list(Stats) ->
    [_Esp, _Var, _Min, _Max, Count, _MeanFB,_CountFB,_Last] = Stats,
    {reply, Count, State};
handle_call({status}, _From, State=#state{stats=Stats} ) ->
    {reply, Stats, State};
handle_call({status, Name, Type}, _From, State ) ->
    Value = dict:find({Name,Type}, State#state.stats),
    {reply, Value, State};

handle_call(Request, _From, State) ->
    ?LOGF("Unknown call ~p !~n",[Request],?ERR),
    Reply = ok,
    {reply, Reply, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast({add, Data}, State=#state{type=Type}) when (( Type == 'connect') or
                                                         (Type == 'page') or
                                                         (Type == 'request'))  ->
    case State#state.backend of
        fullstats -> io:format(State#state.fullstats,"~p~n",[{sample, Type, Data}]);
        _Other   -> ok
    end,
    [Esp, Var, Max, Min, I, MeanFB,CountFB,Last] = State#state.stats,
    {NewEsp,NewVar,NewMin,NewMax,NewI} = ts_stats:meanvar_minmax(Esp,Var,Min,Max,Data,I),
    {noreply,State#state{stats=[NewEsp,NewVar,NewMax,NewMin,NewI,MeanFB,CountFB,Last]}};

handle_cast({add, Data}, State) when is_list(Data) ->
    case State#state.backend of
        fullstats -> io:format(State#state.fullstats,"~p~n",[Data]);
        _Other   -> ok
    end,
    NewStats = lists:foldl(fun add_stats_data/2, State#state.stats, Data ),
    {noreply,State#state{stats=NewStats}};

handle_cast({add, Data}, State) when is_tuple(Data) ->
    case State#state.backend of
        fullstats -> io:format(State#state.fullstats,"~p~n",[Data]);
        _Other   -> ok
    end,
    NewStats = add_stats_data(Data, State#state.stats),
    {noreply,State#state{stats=NewStats}};

handle_cast({set_output, BackEnd, {Stream, StreamFull}}, State) ->
    {noreply,State#state{backend=BackEnd, log=Stream, fullstats=StreamFull}};

handle_cast({dumpstats}, State) ->
    %% export_stats(State),
    NewStats = reset_all_stats(State#state.stats),
    {noreply, State#state{laststats = NewStats, stats=NewStats}};

handle_cast({wait, Id, Time}, State) ->
    ts_stats_server:done(Id, Time, State),
    {stop, normal, State};

handle_cast({stop}, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    ?LOGF("Unknown msg ~p !~n",[Msg], ?WARN),
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(Reason, _State) ->
    ?LOGF("stopping stats monitor (~p)~n",[Reason],?INFO),
    %% export_stats(State),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%%--------------------------------------------------------------------
code_change(_OldVsn, StateData, _Extra) ->
    {ok, StateData}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: add_stats_data/2
%% Purpose: update or add value in dictionnary
%% Returns: Dict
%%----------------------------------------------------------------------
%% continuous incrementing counters
add_stats_data({Type, Name, Value},Stats) when Type==sample;
                                              Type==sample_counter ->
    MyFun = fun (OldVal) -> update_stats(Type, OldVal, Value) end,
    dict:update({Name,Type}, MyFun, update_stats(Type, [], Value), Stats);
%% increase by one when called
add_stats_data({count, Name}, Stats)  ->
    dict:update_counter({Name, count}, 1, Stats);
%% cumulative counter
add_stats_data({sum, Name, Val}, Stats)  ->
    dict:update_counter({Name, sum}, Val, Stats).

%%----------------------------------------------------------------------
%% Func: export_stats/2
%%----------------------------------------------------------------------
export_stats(Log, State=#state{type=Type,backend=Backend}) when Type == 'connect'; Type == 'page'; Type == 'request' ->
    %% io:format(Log, "# export_stats: ~p~n~p~n", [Type, State]),
    Param = {Backend,State#state.laststats,Log},
    print_stats({Type,sample}, State#state.stats, Param);
export_stats(Log, State=#state{backend=Backend, type=_Type}) ->
    %% io:format(Log, "# export_stats1: ~p~n~p~n", [_Type, State]),
    Param = {Backend,State#state.laststats,Log},
    dict:fold(fun print_stats/3, Param, State#state.stats).

%%----------------------------------------------------------------------
%% @spec print_stats({Backend::tuple(),Name::tuple(),
%%                   Type::sample|count|sum|sample_counter}, Value::list(),
%%                   {Last, Logfile} ) -> {Last, Logfile}
%% @doc print statistics in text format in Logfile @end
%%----------------------------------------------------------------------
print_stats({_,_}, [], {Backend,LastRes,Logfile})->
    {Backend,LastRes, Logfile};
print_stats({_,_}, [0,0,0,0,0,0,0|_], {Backend,LastRes,Logfile})->
    {Backend,LastRes, Logfile};
print_stats({_,_,_}, 0, {Backend,0, Logfile})-> % no data yet
    {Backend,0, Logfile};
print_stats({{Name,Node},Type},Value,{json,Res,Log}) when (Type =:= sample) orelse (Type =:= sample_counter) ->
    [_,Host] = string:tokens(Node,"@"),
    print_stats_txt({Name,Type,", {\"name\": \"~p\", \"hostname\": \"" ++ Host
                     ++"\", \"value\": ~p, \"mean\": ~p,\"stddev\": ~p,\"max\": ~p,\"min\": ~p ,\"global_mean\": ~p ,\"global_count\": ~p}"},Value,{json,Res,Log});

print_stats({Name,Type},Value,{json,Res,Log}) when (Type =:= sample) orelse (Type =:= sample_counter) ->
    print_stats_txt({Name,Type,", {\"name\": \"~p\", \"value\": ~p, \"mean\": ~p,\"stddev\": ~p,\"max\":  ~p,\"min\": ~p ,\"global_mean\": ~p ,\"global_count\": ~p}"},Value,{json,Res,Log});

print_stats({Name,Type},Value,Other) when Type =:= sample orelse Type =:= sample_counter ->
    print_stats_txt({Name,Type,"stats: ~p ~p ~p ~p ~p ~p ~p ~p~n"},Value,Other);

print_stats({Name,Type},Value,{json,Res,Log}) when is_integer(Name) -> % http return code
    print_stats_txt({Name,Type,
                     ", {\"name\": \"http_~p\", \"value\": ~p, \"total\": ~p}"},Value,{json,Res,Log});
print_stats({Name=connected,Type},Value,{json,Res,Log}) ->
    print_stats_txt({Name,Type,", {\"name\": \"~p\", \"value\": ~p, \"max\": ~p}"},Value,{json,Res,Log});
print_stats({Name,Type},Value,{json,Res,Log}) ->
    print_stats_txt({Name,Type,", {\"name\": \"~p\", \"value\": ~p, \"total\": ~p}"},Value,{json,Res,Log});
print_stats({Name,Type},Value,Other) ->
    print_stats_txt({Name,Type,"stats: ~p ~p ~p~n"},Value,Other).


%% @spec print_stats_txt(tuple(),Data::list(),tuple()) -> {Backend::atom(),LastRest::term(), LogFile::term()}
print_stats_txt({Name,_,Format}, [Mean,0,Max,Min,Count,MeanFB,CountFB|_], {Backend,LastRes,Logfile})->
    io:format(Logfile, Format,
              [Name, Count, Mean, 0, Max, Min,MeanFB,CountFB ]),
    {Backend,LastRes, Logfile};
print_stats_txt({Name,_,Format},[Mean,Var,Max,Min,Count,MeanFB,CountFB|_],{Backend,LastRes,Logfile})->
    StdDev = math:sqrt(Var/Count),
    io:format(Logfile, Format,
              [Name, Count, Mean, StdDev, Max, Min, MeanFB,CountFB]),
    {Backend,LastRes, Logfile};
print_stats_txt({Name, _,Format}, [Value,Last], {Backend,LastRes, Logfile}) ->
    io:format(Logfile, Format, [Name, Value, Last ]),
    {Backend,LastRes, Logfile};
print_stats_txt({Name, _,Format}, Value, {Backend,LastRes, Logfile}) when is_number(LastRes)->
    io:format(Logfile, Format, [Name, Value-LastRes, Value]),
    {Backend,LastRes, Logfile};
print_stats_txt({Name, Type, Format}, Value, {Backend,LastRes, Logfile}) when is_number(Value)->
    PrevVal = case dict:find({Name, Type}, LastRes) of
                  {ok, OldVal} -> OldVal;
                  error        -> 0
              end,
    io:format(Logfile, Format, [Name, Value-PrevVal, Value]),
    {Backend,LastRes, Logfile}.


%%----------------------------------------------------------------------
%% update_stats/3
%% @spec (Type::atom, List, Value::[integer() | float()]) -> List
%% @doc update the mean and variance for the given sample
%%----------------------------------------------------------------------
update_stats(sample, [], New) ->
    [New, 0, New, New, 1, 0, 0, 0];
update_stats(sample, Data, Value) ->
    %% we don't use lastvalue for 'sample', set it to zero
    update_stats2(Data, Value, 0);
update_stats(sample_counter,[], New) -> %% first call, store the initial value
    [0, 0, 0, 0, 0, 0, 0, New];
update_stats(sample_counter, Current, 0) -> % skip 0 values
    Current;
update_stats(sample_counter,[Mean,Var,Max,Min,Count,MeanFB,CountFB,Last],Value)
  when Value < Last->
    %% maybe the counter has been restarted, use the new value, but don't update other data
    [Mean,Var,Max,Min,Count,MeanFB,CountFB,Value];
update_stats(sample_counter, [0, 0, 0, 0, 0, MeanFB,CountFB,Last], Value) ->
    New = Value-Last,
    [New, 0, New, New, 1, MeanFB,CountFB,Value];
update_stats(sample_counter,Data, Value) ->
    update_stats2(Data, Value, Value).

update_stats2([Mean, Var, Max, Min, Count, MeanFB,CountFB,Last], Value, NewLast) when is_number(Value), is_number(NewLast), is_number(Last), is_number(Count)->
    New = Value-Last,
    {NewMean, NewVar, _} = ts_stats:meanvar(Mean, Var, [New], Count),
    if
        New > Max -> % new max, min unchanged
            [NewMean, NewVar, New, Min, Count+1, MeanFB,CountFB,NewLast];
        New < Min ->
            [NewMean, NewVar, Max, New, Count+1, MeanFB,CountFB,NewLast];
        true ->
            [NewMean, NewVar, Max, Min, Count+1, MeanFB,CountFB,NewLast]
    end.

%%----------------------------------------------------------------------
%% Func: reset_all_stats/1
%%----------------------------------------------------------------------
reset_all_stats(Data) when is_list(Data)->
    reset_stats(Data);
reset_all_stats(Dict)->
    MyFun = fun (_Key, OldVal) -> reset_stats(OldVal) end,
    dict:map(MyFun, Dict).

%%----------------------------------------------------------------------
%% @spec reset_stats(list()) -> list()
%% @doc reset all stats except min and max and lastvalue. Compute the
%%      global mean here
%% @end
%%----------------------------------------------------------------------
reset_stats([]) ->
    [];
reset_stats([_Mean, _Var, Max, Min, 0, _MeanFB,0,Last]) ->
    [0, 0, Max, Min, 0, 0, 0,Last];
reset_stats([Mean, _Var, Max, Min, Count, MeanFB,CountFB,Last]) ->
    NewCount=CountFB+Count,
    NewMean=(CountFB*MeanFB+Count*Mean)/NewCount,
    [0, 0, Max, Min, 0, NewMean,NewCount,Last];
reset_stats([_Sample, LastValue]) ->
    [0, LastValue];
reset_stats(LastValue) ->
    LastValue.

