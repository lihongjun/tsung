%%%-------------------------------------------------------------------
%%% @author OnlyChoice
%%% @copyright 2011 jzh
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ts_websocket_util).

%% Exported functions.
-export([connect/3, send/2, encode_msg/1, encode_close/1, 
        decode_msg/1, initial_request/2, check_handshake_response/2, encode_key/1]).

%% handshake status
-define(CONNECTING,0).
-define(OPEN,1).
-define(CLOSED,2).

%% Opcode of websocket frame
-define(OP_CONT,0).
-define(OP_TEXT,1).
-define(OP_BIN,2).
-define(OP_CLOSE,8).
-define(OP_PING,9).
-define(OP_PONG,10).

%% Websocket state record
-record(state, {socket,readystate=undefined,headers=[],accept,opts}).
-record(websocket, {status, accept, headers=[]}).

%%%===================================================================
%%% API functions
%%%===================================================================

connect(Server, Port, Opts) ->
    case gen_tcp:connect(Server, Port, [binary, {packet, http}, {active, true}] ++ Opts) of
        {ok, Socket} ->
            {Req, Accept} = initial_request(Server, "/"),
            ok = gen_tcp:send(Socket, Req),
            handshake_loop(#state{socket=Socket, accept=Accept, opts=Opts});
        {error, Reason} ->
            {error, Reason}
    end.

send(Socket, Message) ->
    EncodeResult =  encode_msg(Message),
    gen_tcp:send(Socket, EncodeResult).

encode_close(Reason) ->
    encode_frame(Reason, 8).

encode_msg(Message) ->
    encode_frame(Message, 2).

encode_frame(Message, Opcode) ->
    Key = crypto:rand_bytes(4),
    Len = erlang:size(Message),
    if
        Len < 126 ->
            list_to_binary([<<1:1, 0:3,Opcode:4,1:1,Len:7>>,Key,mask(Key,Message)]);
		Len < 65536 ->
            list_to_binary([<<1:1, 0:3,Opcode:4,1:1,126:7,Len:16>>,Key,mask(Key,Message)]);
		true ->
            list_to_binary([<<1:1, 0:3,Opcode:4,1:1,127:7,Len:64>>,Key,mask(Key,Message)])
	end.

decode_msg(Message) ->
    handle_data(Message, none).

check_handshake_response(Response, Accept) ->
    case parse_headers(#websocket{}, Response) of
        {ok, Result=#websocket{status=101}} ->
            case check_headers(Result#websocket.headers) of
                true ->
                    AcctualAcc = Result#websocket.accept,
                    case AcctualAcc of
                        Accept -> ok;
                        _ -> {error, mismatch_acc}
                    end;
                _ ->
                    {error, miss_headers}
            end;
        _ ->
            {error, error_status}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%Last frame of a segment
handle_frame(1,?OP_CONT,_Len,_Data) ->
     {close, seg_not_support};
%Frame w/o segment
handle_frame(1,Opcode,Len,Data) ->
    <<Data1:Len/binary,Rest/binary>> = Data,
    Result = case Opcode of
	?OP_BIN ->
        Data1;
    ?OP_TEXT ->
        Data1;
	?OP_CLOSE ->
        {close, close};
	_Any ->
        {close, error}
    end,

    case Rest of 
	<<>> ->
        {Result, none};
	_Left ->
        {Result, _Left}
    end;
%Cont. frame of a segment
handle_frame(0,?OP_CONT,_Len,_Data) ->
    {close, seg_not_support};
%first frame of a segment
handle_frame(0,_Opcode,_Len,_Data) ->
    {close, seg_not_support}.

handle_data(<<Fin:1,0:3,Opcode:4,0:1,PayloadLen:7,PayloadData/binary>>,none)
        when PayloadLen < 126 andalso PayloadLen =< size(PayloadData) ->
    handle_frame(Fin,Opcode,PayloadLen,PayloadData);
handle_data(<<Fin:1,0:3,Opcode:4,0:1,126:7,PayloadLen:16,PayloadData/binary>>,none) 
        when PayloadLen =< size(PayloadData) ->
    handle_frame(Fin,Opcode,PayloadLen,PayloadData);
handle_data(<<Fin:1,0:3,Opcode:4,0:1,127:7,0:1,PayloadLen:63,PayloadData/binary>>,none) 
        when PayloadLen =< size(PayloadData) ->
    handle_frame(Fin,Opcode,PayloadLen,PayloadData);

% Error, the MSB of extended payload length must be 0
handle_data(<<_Fin:1,0:3,_Opcode:4,_:1,127:7,1:1,_PayloadLen:63,_PayloadData/binary>>,none) ->
    {close, error};
handle_data(<<_Fin:1,0:3,_Opcode:4,1:1,_PayloadLen:7,_Data/binary>>,none) ->
    % Error, Server to client message can't be masked 
    {close, masked};
handle_data(Data,Buffer) ->
    handle_data(<<Buffer/binary,Data/binary>>,none).

mask(Key, Data) ->
    K = binary:copy(Key, 512 div 32),
    <<LongKey:512>> = K,
    <<ShortKey:32>> = Key,
    mask(ShortKey, LongKey, Data, <<>>).

encode_key(Key) ->
    A = binary:encode_unsigned(Key),
    case size(A) of
        4 -> A;
        _Other -> 
            Bits = (4 - _Other) * 8,
            <<0:Bits, A/binary>>
    end.

mask(Key, LongKey, Data, Accu) ->
    case Data of
        <<A:512, Rest/binary>> ->
            C = A bxor LongKey,
            mask(Key, LongKey, Rest, <<Accu/binary, C:512>>);
        <<A:32,Rest/binary>> ->
            C = A bxor Key,
            mask(Key,LongKey,Rest,<<Accu/binary,C:32>>);
        <<A:24>> ->
            <<B:24, _:8>> = encode_key(Key),
            C = A bxor B,
            <<Accu/binary,C:24>>;
        <<A:16>> ->
            <<B:16, _:16>> = encode_key(Key),
            C = A bxor B,
            <<Accu/binary,C:16>>;
        <<A:8>> ->
            <<B:8, _:24>> = encode_key(Key),
            C = A bxor B,
            <<Accu/binary,C:8>>;
        <<>> ->
            Accu
   end.

generateKeyAccept() ->
    random:seed(erlang:now()),
    Key = crypto:rand_bytes(16),
    KeyString = base64:encode_to_string(Key),
    A = binary:list_to_bin(KeyString ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
    Accept = base64:encode_to_string(crypto:sha(A)),
    {KeyString, Accept}.


initial_request(Host,Path) ->
    {Key,Accept} = generateKeyAccept(),
    Req = "GET "++ Path ++" HTTP/1.1\r\n" ++
	"Host: " ++ Host ++ "\r\n" ++
	"Upgrade: websocket\r\n" ++
	"Connection: Upgrade\r\n" ++ 
	"Sec-Websocket-Key: " ++ Key ++ "\r\n" ++
	"Sec-Websocket-Origin: http://" ++ Host ++ "\r\n" ++
	"Sec-Websocket-Version: 8\r\n\r\n",
    {Req, Accept}.

check_headers(Headers) ->
    RequiredHeaders = [
        {'Upgrade', "websocket"},
        {'Connection', "Upgrade"},
        {'Sec-Websocket-Accept', ignore}
    ],

    F = fun({Tag, Val}) ->
        Term = if
            is_atom (Tag) -> Tag;
            true -> string:to_lower(Tag)
        end,
        % see if the required Tag is in the Headers
	    case proplists:get_value(Term, Headers) of
            false -> true; % header not found, keep in list
            HVal ->
                case Val of
                    ignore -> false; % ignore value -> ok, remove from list
                    HVal -> false;	 % expected val -> ok, remove from list
		            _ -> true		 % val is different, keep in list
		        end		
	    end
    end,
    
    case lists:filter(F, RequiredHeaders) of
        [] -> true;
        MissingHeaders -> MissingHeaders
    end.


handshake_loop(State) ->
    receive
        {http,_Socket,{http_response,{1,1},101,"Switching Protocols"}} ->
	        State1 = State#state{readystate=?CONNECTING},
	        handshake_loop(State1);
	    {http,_Socket,{http_header, _, Name, _, Value}} when is_atom(Name) ->
	        case State#state.readystate of
                ?CONNECTING ->
		            H = [{Name,Value} | State#state.headers],
		            State1 = State#state{headers=H},
		            handshake_loop(State1);
                undefined ->
		            error_logger:error_msg("PID ~p undefined state1~n, Name: ~p, Value ~p", 
                        [self(),Name,Value]),
		            %% Bad state should have received response first
		            {error, undef_state}
            end;
	    {http,_Socket,{http_header, _, Name, _, Value}} ->
	        case State#state.readystate of
		        ?CONNECTING ->
		            H = [{string:to_lower(Name),Value} | State#state.headers],
		            State1 = State#state{headers=H},
                    handshake_loop(State1);
		        undefined ->
		            error_logger:error_msg("PID ~p undefined state1~n, Name: ~p, Value ~p, Headers ~p", 
                        [self(),Name,Value,State#state.headers]),
		            %% Bad state should have received response first
		            {error, undef_state}
            end;
	    %% Once we have all the headers check for the 'Upgrade' flag 
	    {http,Socket,http_eoh} ->
	        %% Validate headers, set state, change packet type back to raw
	        case State#state.readystate of
                ?CONNECTING ->
                    Headers = State#state.headers,
		        % check for headers existance
		        case check_headers(Headers) of
                    true -> 
                        {Accept} = {State#state.accept},
			            case proplists:get_value(string:to_lower("Sec-Websocket-Accept"),Headers) of
                            Accept ->
                                ok = inet:setopts(Socket, [{packet, raw}, {active, once}]),
                                {ok, Socket};
                            _Any  ->
                                error_logger:error_msg("Pid ~p: Error Sec-Websocket-Accept=~p, expected ~p~n",
                                    [self(),_Any,Accept]),
                                {error, mismatch_accept}
                        end;
                    _RemainingHeaders ->
                        error_logger:error_msg("Pid ~p: Missing headers: ~p~n", [self(),_RemainingHeaders]),
                        {error,miss_headers}
                end;
            undefined ->
                error_logger:error_msg("PID ~p undefined state2~n", [self()]),
                %% Bad state should have received response first
		        {error, undef_state}
        end
        %% Handshake complete, handle packets    
    end.

%% Parse http headers from websocket handshake response
parse_headers(W, Tail) ->
    case get_line(Tail) of
    {line, Line, Tail2} ->
        parse_headers(parse_line(Line, W), Tail2);
    {lastline, Line, _} ->
        {ok, parse_line(Line, W)}
    end.

parse_status([A,B,C|_], WS) ->
    Status=list_to_integer([A,B,C]),
    WS#websocket{status=Status}.

parse_line("http/1.1 " ++ TailLine, WS) ->
    parse_status(TailLine, WS);
parse_line("upgrade: " ++ TailLine, WS) ->
    Headers = [{'Upgrade', TailLine} | WS#websocket.headers],  
    WS#websocket{headers=Headers};
parse_line("connection: " ++ TailLine, WS) ->
    Headers = [{'Connection', TailLine} | WS#websocket.headers],
    WS#websocket{headers=Headers};
parse_line("sec-websocket-accept: " ++ TailLine, WS) ->
    Headers = [{'Sec-WebSocket-Accept', TailLine} | WS#websocket.headers],
    WS#websocket{headers=Headers, accept=TailLine};
parse_line(_Line, WS) ->
    WS.

%% code taken from yaws
is_nb_space(X) ->
    lists:member(X, [$\s, $\t]).
% ret: {line, Line, Trail} | {lastline, Line, Trail}
get_line(L) ->
    get_line(L, true, []).
get_line("\r\n\r\n" ++ Tail, _Cap, Cur) ->
    {lastline, lists:reverse(Cur), Tail};
get_line("\r\n", _, _) ->
    {more};
get_line("\r\n" ++ Tail, Cap, Cur) ->
    case is_nb_space(hd(Tail)) of
        true ->  %% multiline ... continue
            get_line(Tail, Cap,[$\n, $\r | Cur]);
        false ->
            {line, lists:reverse(Cur), Tail}
    end;
get_line([$:|T], true, Cur) -> % ':' separator
    get_line(T, false, [$:|Cur]);%the rest of the header isn't set to lower char
get_line([H|T], false, Cur) ->
    get_line(T, false, [H|Cur]);
get_line([Char|T], true, Cur) when Char >= $A, Char =< $Z ->
    get_line(T, true, [Char + 32|Cur]);
get_line([H|T], true, Cur) ->
    get_line(T, true, [H|Cur]);
get_line([], _, _) -> %% Headers are fragmented ... We need more data
    {more}.
