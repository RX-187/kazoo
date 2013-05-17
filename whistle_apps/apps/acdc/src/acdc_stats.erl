%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2013, 2600Hz
%%% @doc
%%% Collector of stats
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(acdc_stats).

-behaviour(gen_listener).

%% Public API
-export([call_waiting/5
         ,call_abandoned/4
         ,call_handled/4
         ,call_missed/5
         ,call_processed/4

         ,agent_active/2
         ,agent_ready/2
         ,agent_paused/3
         ,agent_inactive/2
         ,agent_handling/3
         ,agent_wrapup/3
         ,agent_oncall/3
         ,agent_timeout/1
        ]).

%% ETS config
-export([table_id/0
         ,key_pos/0
         ,init_db/1
         ,db_name/1
         ,archive_data/1
        ]).

%% AMQP Callbacks
-export([handle_stat/2]).

%% gen_listener functions
-export([start_link/0
         ,init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("acdc.hrl").

%% Archive every 60 seconds
-define(ARCHIVE_PERIOD, whapps_config:get_integer(?CONFIG_CAT, <<"archive_period_ms">>, 60000)).

%% Defaults to one hour
-define(ARCHIVE_WINDOW, whapps_config:get_integer(?CONFIG_CAT, <<"archive_window_s">>, 3600)).

-define(ARCHIVE_MSG, 'time_to_archive').

-record(agent_miss, {
          agent_id :: api_binary()
          ,miss_reason :: api_binary()
          ,miss_timestamp = wh_util:current_tstamp() :: pos_integer()
         }).
-type agent_miss() :: #agent_miss{}.
-type agent_misses() :: [agent_miss(),...] | [].

-record(call_stat, {
          id :: api_binary() %% call_id-queue_id
          ,call_id :: api_binary()
          ,acct_id :: api_binary()
          ,queue_id :: api_binary()

          ,agent_id :: api_binary() % the handling agent

          ,entered_timestamp = wh_util:current_tstamp() :: pos_integer()
          ,abandoned_timestamp = wh_util:current_tstamp() :: pos_integer()
          ,handled_timestamp = wh_util:current_tstamp() :: pos_integer()
          ,processed_timestamp = wh_util:current_tstamp() :: pos_integer()

          ,abandoned_reason :: abandon_reason()

          ,misses = [] :: agent_misses()

          ,status :: api_binary()
          ,caller_id_name :: api_binary()
          ,caller_id_number :: api_binary()
         }).
-type call_stat() :: #call_stat{}.

%% Public API
call_waiting(AcctId, QueueId, CallId, CallerIdName, CallerIdNumber) ->
    Prop = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Queue-ID">>, QueueId}
              ,{<<"Call-ID">>, CallId}
              ,{<<"Caller-ID-Name">>, CallerIdName}
              ,{<<"Caller-ID-Number">>, CallerIdNumber}
              ,{<<"Entered-Timestamp">>, wh_util:current_tstamp()}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    whapps_util:amqp_pool_send(Prop, fun wapi_acdc_stats:publish_call_waiting/1).

call_abandoned(AcctId, QueueId, CallId, Reason) ->
    Prop = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Queue-ID">>, QueueId}
              ,{<<"Call-ID">>, CallId}
              ,{<<"Abandon-Reason">>, Reason}
              ,{<<"Abandon-Timestamp">>, wh_util:current_tstamp()}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    whapps_util:amqp_pool_send(Prop, fun wapi_acdc_stats:publish_call_abandoned/1).

call_handled(AcctId, QueueId, CallId, AgentId) ->
    Prop = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Queue-ID">>, QueueId}
              ,{<<"Call-ID">>, CallId}
              ,{<<"Agent-ID">>, AgentId}
              ,{<<"Handled-Timestamp">>, wh_util:current_tstamp()}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    whapps_util:amqp_pool_send(Prop, fun wapi_acdc_stats:publish_call_handled/1).

call_missed(AcctId, QueueId, AgentId, CallId, ErrReason) ->
    Prop = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Queue-ID">>, QueueId}
              ,{<<"Call-ID">>, CallId}
              ,{<<"Agent-ID">>, AgentId}
              ,{<<"Miss-Reason">>, ErrReason}
              ,{<<"Miss-Timestamp">>, wh_util:current_tstamp()}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    whapps_util:amqp_pool_send(Prop, fun wapi_acdc_stats:publish_call_missed/1).

call_processed(AcctId, QueueId, AgentId, CallId) ->
    Prop = props:filter_undefined(
             [{<<"Account-ID">>, AcctId}
              ,{<<"Queue-ID">>, QueueId}
              ,{<<"Call-ID">>, CallId}
              ,{<<"Agent-ID">>, AgentId}
              ,{<<"Processed-Timestamp">>, wh_util:current_tstamp()}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    whapps_util:amqp_pool_send(Prop, fun wapi_acdc_stats:publish_call_processed/1).

agent_active(_,_) -> 'ok'.
agent_ready(_,_) -> 'ok'.
agent_paused(_,_,_) -> 'ok'.
agent_inactive(_,_) -> 'ok'.
agent_handling(_,_,_) -> 'ok'.
agent_wrapup(_,_,_) -> 'ok'.
agent_oncall(_,_,_) -> 'ok'.
agent_timeout(_) -> 'ok'.

%% ETS config
table_id() -> ?MODULE.
key_pos() -> #call_stat.id.

-define(BINDINGS, [{'self', []}
                   ,{'acdc_stats', []}
                  ]).
-define(RESPONDERS, [{{?MODULE, 'handle_stat'}, [{<<"acdc_stat">>, <<"*">>}]}]).
-define(QUEUE_NAME, <<>>).

start_link() ->
    gen_listener:start_link(?MODULE
                            ,[{'bindings', ?BINDINGS}
                              ,{'responders', ?RESPONDERS}
                              ,{'queue_name', ?QUEUE_NAME}
                             ],
                            []).

handle_stat(JObj, Props) ->
    case wh_json:get_value(<<"Event-Name">>, JObj) of
        <<"waiting">> -> handle_waiting_stat(JObj, Props);
        <<"missed">> -> handle_missed_stat(JObj, Props);
        <<"abandoned">> -> handle_abandoned_stat(JObj, Props);
        <<"handled">> -> handle_handled_stat(JObj, Props);
        <<"processed">> -> handle_processed_stat(JObj, Props);
        _Name ->
            lager:debug("recv unknown stat type ~s: ~p", [_Name, JObj])
    end.

-record(state, {
          archive_ref :: reference()
         }).

init([]) ->
    put('callid', <<"acdc.stats">>),
    lager:debug("started new acdc stats collector"),

    {'ok', #state{archive_ref=start_archive_timer()}}.

-spec start_archive_timer() -> reference().
start_archive_timer() ->
    erlang:send_after(?ARCHIVE_PERIOD, self(), ?ARCHIVE_MSG).

handle_call(_Req, _From, State) ->
    {'reply', 'ok', State}.

handle_cast({'create', #call_stat{id=_Id}=Stat}, State) ->
    lager:debug("creating new stat ~s", [_Id]),
    ets:insert_new(table_id(), Stat),
    {'noreply', State};
handle_cast({'update', Id, Updates}, State) ->
    lager:debug("updating stat ~s", [Id]),
    ets:update_element(table_id(), Id, Updates),
    {'noreply', State};
handle_cast({'remove', [{M, P, _}]}, State) ->
    Match = [{M, P, ['true']}],
    lager:debug("removing stats from table"),
    N = ets:select_delete(table_id(), Match),
    lager:debug("removed (or not): ~p", [N]),
    {'noreply', State};
handle_cast(_Req, State) ->
    lager:debug("unhandling cast: ~p", [_Req]),
    {'noreply', State}.

handle_info({'ETS-TRANSFER', _TblId, _From, _Data}, State) ->
    lager:debug("ETS control transferred to me for writing"),
    {'noreply', State};
handle_info(?ARCHIVE_MSG, State) ->
    lager:debug("time to archive stats older than ~bs", [?ARCHIVE_WINDOW]),
    Self = self(),
    _ = spawn(?MODULE, 'archive_data', [Self]),
    {'noreply', State#state{archive_ref=start_archive_timer()}};
handle_info(_Msg, State) ->
    lager:debug("unhandling message: ~p", [_Msg]),
    {'noreply', State}.

handle_event(_JObj, _State) ->
    {'reply', []}.

terminate(_Reason, _) ->
    lager:debug("acdc stats terminating: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

archive_data(Srv) ->
    put('callid', <<"acdc_stats.archiver">>),

    StatsBefore = wh_util:current_tstamp() - ?ARCHIVE_WINDOW,
    lager:debug("archiving stats prior to ~b", [StatsBefore]),

    Match = [{#call_stat{entered_timestamp='$1', status='$2', _='_'}
              ,[{'=<', '$1', StatsBefore}
                ,{'=/=', '$2', {'const', <<"waiting">>}}
                ,{'=/=', '$2', {'const', <<"handled">>}}
               ]
              ,['$_']
             }],
    case ets:select(table_id(), Match) of
        [] -> lager:debug("no stats to be archived at this time");
        Stats ->
            gen_listener:cast(Srv, {'remove', Match}),
            ToSave = lists:foldl(fun archive_fold/2, dict:new(), Stats),
            lager:debug("saving ~p", [dict:to_list(ToSave)]),
            [couch_mgr:save_docs(db_name(Acct), Docs) || {Acct, Docs} <- dict:to_list(ToSave)]
    end.

archive_fold(#call_stat{acct_id=AcctId}=Stat, Acc) ->
    Doc = stat_to_doc(Stat),
    dict:update(AcctId, fun(L) -> [Doc | L] end, [Doc], Acc).

stat_to_doc(#call_stat{id=Id
                       ,call_id=CallId
                       ,acct_id=AcctId
                       ,queue_id=QueueId
                       ,agent_id=AgentId
                       ,entered_timestamp=EnteredT
                       ,abandoned_timestamp=AbandonedT
                       ,handled_timestamp=HandledT
                       ,processed_timestamp=ProcessedT
                       ,abandoned_reason=AbandonedR
                       ,misses=Misses
                       ,status=Status
                       ,caller_id_name=CallerIdName
                       ,caller_id_number=CallerIdNumber
                      }) ->
    wh_doc:update_pvt_parameters(
      wh_json:from_list(
        props:filter_undefined(
          [{<<"_id">>, Id}
           ,{<<"call_id">>, CallId}
           ,{<<"queue_id">>, QueueId}
           ,{<<"agent_id">>, AgentId}
           ,{<<"entered_timestamp">>, EnteredT}
           ,{<<"abandoned_timestamp">>, AbandonedT}
           ,{<<"handled_timestamp">>, HandledT}
           ,{<<"processed_timestamp">>, ProcessedT}
           ,{<<"abandoned_reason">>, AbandonedR}
           ,{<<"misses">>, misses_to_docs(Misses)}
           ,{<<"status">>, Status}
           ,{<<"caller_id_name">>, CallerIdName}
           ,{<<"caller_id_number">>, CallerIdNumber}
           ,{<<"wait_time">>, wait_time(EnteredT, AbandonedT, HandledT)}
           ,{<<"talk_time">>, talk_time(HandledT, ProcessedT)}
          ])), db_name(AcctId), [{'account_id', AcctId}
                                 ,{'type', <<"acdc_call">>}
                                ]).

wait_time(E, _, H) when is_integer(E), is_integer(H) -> H - E;
wait_time(E, A, _) when is_integer(E), is_integer(A) -> A - E;
wait_time(_, _, _) -> 'undefined'.

talk_time(H, P) when is_integer(H), is_integer(P) -> P - H;
talk_time(_, _) -> 'undefined'.

misses_to_docs(Misses) -> [miss_to_doc(Miss) || Miss <- Misses].
miss_to_doc(#agent_miss{agent_id=AgentId
                        ,miss_reason=Reason
                        ,miss_timestamp=T
                        }) ->
    wh_json:from_list([{<<"agent_id">>, AgentId}
                       ,{<<"reason">>, Reason}
                       ,{<<"timestamp">>, T}
                      ]).

init_db(AcctId) ->
    DbName = db_name(AcctId),
    lager:debug("created db ~s: ~s", [DbName, couch_mgr:db_create(DbName)]),
    lager:debug("revised docs in ~s: ~p", [AcctId, couch_mgr:revise_views_from_folder(DbName, 'acdc')]).

db_name(Acct) ->
    <<A:2/binary, B:2/binary, Rest/binary>> = wh_util:format_account_id(Acct, 'raw'),
    <<"acdc%2F",A/binary,"%2F",B/binary,"%2F", Rest/binary>>.

stat_id(JObj) ->
    stat_id(wh_json:get_value(<<"Call-ID">>, JObj)
            ,wh_json:get_value(<<"Queue-ID">>, JObj)
           ).
stat_id(CallId, QueueId) -> <<CallId/binary, "::", QueueId/binary>>.

handle_waiting_stat(JObj, Props) ->
    'true' = wapi_acdc_stats:call_waiting_v(JObj),

    Id = stat_id(JObj),
    case find_stat(Id) of
        'undefined' -> create_stat(Id, JObj, Props);
        _Stat ->
            Updates = props:filter_undefined(
                        [{#call_stat.caller_id_name, wh_json:get_value(<<"Caller-ID-Name">>, JObj)}
                         ,{#call_stat.caller_id_number, wh_json:get_value(<<"Caller-ID-Number">>, JObj)}
                        ]),
            update_stat(Id, Updates, Props)
    end.

handle_missed_stat(JObj, Props) ->
    'true' = wapi_acdc_stats:call_missed_v(JObj),

    Id = stat_id(JObj),
    case find_stat(Id) of
        'undefined' -> lager:debug("can't update stat ~s with missed data, missing", [Id]);
        #call_stat{misses=Misses} ->
            Updates = [{#call_stat.misses, [create_miss(JObj) | Misses]}],
            update_stat(Id, Updates, Props)
    end.

create_miss(JObj) ->
    #agent_miss{
       agent_id = wh_json:get_value(<<"Agent-ID">>, JObj)
       ,miss_reason = wh_json:get_value(<<"Miss-Reason">>, JObj)
       ,miss_timestamp = wh_json:get_value(<<"Miss-Timestamp">>, JObj)
      }.


handle_abandoned_stat(JObj, Props) ->
    'true' = wapi_acdc_stats:call_abandoned_v(JObj),

    Id = stat_id(JObj),
    Updates = props:filter_undefined(
                [{#call_stat.abandoned_reason, wh_json:get_value(<<"Abandon-Reason">>, JObj)}
                 ,{#call_stat.abandoned_timestamp, wh_json:get_value(<<"Abandon-Timestamp">>, JObj)}
                 ,{#call_stat.status, <<"abandoned">>}
                ]),
    update_stat(Id, Updates, Props).

handle_handled_stat(JObj, Props) ->
    'true' = wapi_acdc_stats:call_handled_v(JObj),

    Id = stat_id(JObj),
    Updates = props:filter_undefined(
                [{#call_stat.agent_id, wh_json:get_value(<<"Agent-ID">>, JObj)}
                 ,{#call_stat.handled_timestamp, wh_json:get_value(<<"Handled-Timestamp">>, JObj)}
                 ,{#call_stat.status, <<"handled">>}
                ]),
    update_stat(Id, Updates, Props).

handle_processed_stat(JObj, Props) ->
    'true' = wapi_acdc_stats:call_processed_v(JObj),

    Id = stat_id(JObj),
    Updates = props:filter_undefined(
                [{#call_stat.agent_id, wh_json:get_value(<<"Agent-ID">>, JObj)}
                 ,{#call_stat.processed_timestamp, wh_json:get_value(<<"Processed-Timestamp">>, JObj)}
                 ,{#call_stat.status, <<"processed">>}
                ]),
    update_stat(Id, Updates, Props).

find_stat(Id) ->
    case ets:lookup(table_id(), Id) of
        [] -> 'undefined';
        [Stat] -> Stat
    end.

create_stat(Id, JObj, Props) ->
    gen_listener:cast(props:get_value('server', Props)
                      ,{'create', #call_stat{
                                     id = Id
                                     ,call_id = wh_json:get_value(<<"Call-ID">>, JObj)
                                     ,acct_id = wh_json:get_value(<<"Account-ID">>, JObj)
                                     ,queue_id = wh_json:get_value(<<"Queue-ID">>, JObj)
                                     ,entered_timestamp = wh_json:get_value(<<"Entered-Timestamp">>, JObj)
                                     ,misses = []
                                     ,status = <<"waiting">>
                                     ,caller_id_name = wh_json:get_value(<<"Caller-ID-Name">>, JObj)
                                     ,caller_id_number = wh_json:get_value(<<"Caller-ID-Number">>, JObj)
                                    }
                       }).

update_stat(Id, Updates, Props) ->
    gen_listener:cast(props:get_value('server', Props)
                      ,{'update', Id, Updates}
                     ).
