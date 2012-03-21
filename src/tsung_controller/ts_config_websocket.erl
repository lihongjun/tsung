-module(ts_config_websocket).

-export([parse_config/2]).

-include("ts_profile.hrl").
-include("ts_websocket.hrl").
-include("ts_config.hrl").

-include("xmerl.hrl").

%%----------------------------------------------------------------------
%% Func: parse_config/2
%% Args: Element, Config
%% Returns: List
%% Purpose: parse a request defined in the XML config file
%%----------------------------------------------------------------------
%% Parsing other elements
parse_config(Element = #xmlElement{name=dyn_variable}, Conf = #config{}) ->
    ts_config:parse(Element,Conf);
parse_config(Element = #xmlElement{name=websocket},
             Config=#config{curid = Id, session_tab = Tab,
                            sessions = [CurS | _], dynvar=DynVar,
			    subst    = SubstFlag, match=MatchRegExp}) ->
    Type = ts_config:getAttr(atom, Element#xmlElement.attributes, type),
    ValRaw = ts_config:getText(Element#xmlElement.content),
    %is this needed ?
    CleanStr = ts_utils:clean_str(ValRaw),
    Request = #websocket_request{data=CleanStr, type=Type},

    Msg= #ts_request{ack = parse,
                     endpage = true,
                     dynvar_specs  = DynVar,
                     subst   = SubstFlag,
                     match   = MatchRegExp,
                     param   = Request},

    ts_config:mark_prev_req(Id-1, Tab, CurS),
    ets:insert(Tab,{{CurS#session.id, Id}, Msg }),
    lists:foldl( fun(A,B)->ts_config:parse(A,B) end,
        Config#config{dynvar=[]},
        Element#xmlElement.content);

%% Parsing other elements
parse_config(Element = #xmlElement{}, Conf = #config{}) ->
    ts_config:parse(Element,Conf);
%% Parsing non #xmlElement elements
parse_config(_, Conf = #config{}) ->
    Conf.

