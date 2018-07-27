%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2018, 2600Hz
%%% @doc
%%% @author Hesaam Farhang
%%% @end
%%%-----------------------------------------------------------------------------
-module(gql_core_query).

-export([execute/4
        ,load_doc/3
        ]).

-include("kz_graphql.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec execute(any(), any(), any(), any()) -> any().
execute(Context, Object, Field, Args) ->
    %% authenticate
    run_execute(Context, Object, Field, Args).

-spec run_execute(any(), any(), any(), any()) -> any().
run_execute(Context, _Object, <<"node">>, #{<<"id">> := ID}) ->
    ?DEV_LOG("resolving a node query"),
    load_node(Context, ID);
run_execute(Context, _Object, <<"account">>, #{<<"id">> := ID}) ->
    ?DEV_LOG("resovling account query"),
    load_doc(Context, [<<"account">>], kz_util:format_account_id(ID)).

load_node(Context, InputID) ->
    try
        case binary:split(InputID, <<":">>) of
            [Type, ID] ->
                load_doc(Context, [Type], ID);
            _Error ->
                ?DEV_LOG("~p split error: ~p", [InputID, _Error]),
                exit('invalid_id')
        end
    catch
        _E:_T ->
            ?DEV_LOG("~p try error ~p:~p", [InputID, _E, _T]),
            {'error', 'invalid_id'}
    end.

-spec load_doc(any(), kz_term:binaries(), kz_term:binary()) -> {'ok', any()} | {'error', any()}.
load_doc(_Context, Types, ID) ->
    %% dummy load for now
    Db = kz_util:format_account_db(ID),
    ?DEV_LOG("loading doc ~s from db ~s", [ID, Db]),
    case kz_datamgr:open_doc(Db, ID) of
        {'ok', JObj} ->
            case check_doc_type(Types, JObj) of
                {'ok', Type} ->
                    ?DEV_LOG("doc type ~p matched to expected type", [Type]),
                    % ?DEV_LOG("JObj~n~p~n~n", [JObj]),
                    {'ok', #{'$type' => Type
                            ,'object' => kz_json:to_map(JObj)
                            }
                    };
                {'error', Expected, Type} ->
                    ?DEV_LOG("document ~p with type ~p does not matched expected types ~p", [ID, Type, Expected]),
                    {'error', 'invalid_id'}
            end;
        {'error', _}=Error -> Error
    end.

check_doc_type(Expected, JObj) ->
    Type = kz_doc:type(JObj),
    case lists:member(Type, Expected) of
        'true' -> {'ok', Type};
        'false' -> {'error', Expected, Type}
    end.