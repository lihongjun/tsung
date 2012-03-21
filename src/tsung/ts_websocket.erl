-module(ts_websocket).

-include("ts_profile.hrl").
-include("ts_websocket.hrl").

-export([init_dynparams/0,
         add_dynparams/4,
         get_message/2,
         session_defaults/0,
         parse/2,
         dump/2,
         decode_buffer/2,
         parse_config/2,
         new_session/0]).


%%----------------------------------------------------------------------
%% Function: session_default/0
%% Purpose: default parameters for session
%% Returns: {ok, ack_type = parse|no_ack|local, persistent = true|false} 
%%----------------------------------------------------------------------
session_defaults() ->
    {ok, true}.

%% @spec decode_buffer(Buffer::binary(),Session::record(jabber)) ->  NewBuffer::binary()
%% @doc We need to decode buffer (remove chunks, decompress ...) for
%%      matching or dyn_variables
%% @end
decode_buffer(Buffer,#ws_session{}) ->
    Buffer. % nothing to do for websocket

%%----------------------------------------------------------------------
%% Function: new_session/0
%% Purpose: initialize session information
%% Returns: record or []
%%----------------------------------------------------------------------
new_session() ->
    #ws_session{}.

dump(A,B) ->
    ts_plugin:dump(A,B).
%%----------------------------------------------------------------------
%% Function: get_message/1
%% Purpose: Build a message/request ,
%% Args:	record
%% Returns: binary
%%----------------------------------------------------------------------
get_message(#websocket_request{type=connect}, State=#state_rcv{session=WS}) ->
    {Req, Accept} = ts_websocket_util:initial_request(State#state_rcv.host, "/"),
    {erlang:list_to_binary(Req), WS#ws_session{stage=handshake, accept=Accept}};
get_message(#websocket_request{type=message, data=Data},#state_rcv{session=S}) ->
    {ts_websocket_util:encode_msg(list_to_binary(Data)), S};
get_message(#websocket_request{type=close},#state_rcv{session=S}) ->
    {ts_websocket_util:encode_close(<<"done">>), S}.

%%----------------------------------------------------------------------
%% Function: parse/2
%% Purpose: parse the response from the server and keep information
%%          about the response in State#state_rcv.session
%% Args:	Data (binary), State (#state_rcv)
%% Returns: {NewState, Options for socket (list), Close = true|false}
%%----------------------------------------------------------------------
parse(closed, State) ->
    {State#state_rcv{ack_done = true, datasize=0}, [], true};
%% new response, compute data size (for stats)
parse(Data, State=#state_rcv{acc = [], datasize= 0}) ->
    parse(Data, State#state_rcv{datasize= size(Data)});

%% handshake stage, parse response, and validate
parse(Data, State=#state_rcv{acc = [], session=WS}) 
        when WS#ws_session.stage == handshake ->
    List = binary_to_list(Data),
    Header = State#state_rcv.acc ++ List,
    case ts_websocket_util:check_handshake_response(Header, WS#ws_session.accept) of
        ok ->
           ts_mon:add({count, ws_success}), 
           {State#state_rcv{ack_done=true,session=WS#ws_session{stage=message}},[],false};
        {error, _} ->
            ts_mon:add({count, ws_failure}),
            {State#state_rcv{ack_done=true},[],true}
    end;

%% normal websocket message
parse(Data, State=#state_rcv{acc = [], session=WS})
        when WS#ws_session.stage == message ->
    case ts_websocket_util:decode_msg(Data) of
        {close, _} ->
            ts_mon:add({count, ws_close}),
            {State#state_rcv{ack_done = true},[],true};
        {Result, _} ->
            ts_mon:add({count, ws_msg}),
            {State#state_rcv{ack_done = true},[],false}
    end;
%% more data, add this to accumulator and parse, update datasize
parse(Data, State=#state_rcv{acc=Acc, datasize=DataSize}) ->
    NewSize= DataSize + size(Data),
    parse(<< Acc/binary,Data/binary >>, State#state_rcv{acc=[], datasize=NewSize}).

%%----------------------------------------------------------------------
%% Function: parse_config/2
%% Purpose:  parse tags in the XML config file related to the protocol
%% Returns:  List
%%----------------------------------------------------------------------
parse_config(Element, Conf) ->
	ts_config_websocket:parse_config(Element, Conf).

%%----------------------------------------------------------------------
%% Function: add_dynparams/4
%% Purpose: we dont actually do anything
%% Returns: #websocket_request
%%----------------------------------------------------------------------
add_dynparams(_Bool, _DynData, Param, _HostData) ->
    Param#websocket_request{}.

%%----------------------------------------------------------------------
%% Function: init_dynparams/0
%% Purpose:  initial dynamic parameters value
%% Returns:  #dyndata
%%----------------------------------------------------------------------
init_dynparams() ->
	#dyndata{proto=#websocket_dyndata{}}.



