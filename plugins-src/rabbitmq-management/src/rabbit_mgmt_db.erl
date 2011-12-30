%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2010-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_mgmt_db).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(gen_server).

-export([start_link/0]).

-export([augment_exchanges/2, augment_queues/2,
         get_channels/2, get_connections/1,
         get_all_channels/1, get_all_connections/0,
         get_overview/1, get_overview/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-import(rabbit_misc, [pget/3]).

-record(state, {tables, interval}).
-define(FINE_STATS_TYPES, [channel_queue_stats, channel_exchange_stats,
                           channel_queue_exchange_stats]).
-define(TABLES, [queue_stats, connection_stats, channel_stats, consumers] ++
            ?FINE_STATS_TYPES).

-define(DELIVER_GET, [deliver, deliver_no_ack, get, get_no_ack]).
-define(FINE_STATS, [publish, ack, deliver_get, confirm,
                     return_unroutable, return_not_delivered, redeliver] ++
            ?DELIVER_GET).

-define(
   FINE_STATS_CHANNEL_LIST,
   [{channel_queue_stats,   [channel], message_stats, channel},
    {channel_exchange_stats,[channel], message_stats, channel}]).

-define(
   FINE_STATS_CHANNEL_DETAIL,
   [{channel_queue_stats,    [channel],           message_stats, channel},
    {channel_exchange_stats, [channel],           message_stats, channel},
    {channel_exchange_stats, [channel, exchange], publishes,     channel},
    {channel_queue_stats,    [channel, queue],    deliveries,    channel}]).

-define(
   FINE_STATS_QUEUE_LIST,
   [{channel_queue_stats,          [queue], message_stats, queue},
    {channel_queue_exchange_stats, [queue], message_stats, queue}]).

-define(
   FINE_STATS_QUEUE_DETAIL,
   [{channel_queue_stats,          [queue],           message_stats, queue},
    {channel_queue_exchange_stats, [queue],           message_stats, queue},
    {channel_queue_stats,          [queue, channel],  deliveries, queue},
    {channel_queue_exchange_stats, [queue, exchange], incoming, queue}]).

-define(
   FINE_STATS_EXCHANGE_LIST,
   [{channel_exchange_stats,       [exchange], message_stats_in,  exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out, exchange}]).

-define(
   FINE_STATS_EXCHANGE_DETAIL,
   [{channel_exchange_stats,       [exchange], message_stats_in,   exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out,  exchange},
    {channel_exchange_stats,       [exchange, channel],  incoming, exchange},
    {channel_queue_exchange_stats, [exchange, queue],    outgoing, exchange}]).

-define(FINE_STATS_NONE, []).

-define(OVERVIEW_QUEUE_STATS,
        [messages, messages_ready, messages_unacknowledged, messages_details,
         messages_ready_details, messages_unacknowledged_details]).

%%----------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

augment_exchanges(Xs, Mode) -> safe_call({augment_exchanges, Xs, Mode}, Xs).
augment_queues(Qs, Mode)    -> safe_call({augment_queues, Qs, Mode}, Qs).

get_channels(Cs, Mode)      -> safe_call({get_channels, Cs, Mode}, Cs).
get_connections(Cs)         -> safe_call({get_connections, Cs}, Cs).

get_all_channels(Mode)      -> safe_call({get_all_channels, Mode}).
get_all_connections()       -> safe_call(get_all_connections).

get_overview(User)          -> safe_call({get_overview, User}).
get_overview()              -> safe_call({get_overview, all}).

safe_call(Term) -> safe_call(Term, []).

safe_call(Term, Item) ->
    try
        gen_server:call({global, ?MODULE}, Term, infinity)
    catch exit:{noproc, _} -> Item
    end.

%%----------------------------------------------------------------------------
pget(Key, List) -> pget(Key, List, unknown).

pset(Key, Value, List) -> [{Key, Value} | proplists:delete(Key, List)].

id(Pid) when is_pid(Pid) -> Pid;
id(List) -> pget(pid, List).

lookup_element(Table, Key) -> lookup_element(Table, Key, 2).

lookup_element(Table, Key, Pos) ->
    try ets:lookup_element(Table, Key, Pos)
    catch error:badarg -> []
    end.

result_or_error([]) -> error;
result_or_error(S)  -> S.

rates(Stats, Timestamp, OldStats, OldTimestamp, Keys) ->
    Stats ++ [R || Key <- Keys,
                   R   <- [rate(Stats, Timestamp, OldStats, OldTimestamp, Key)],
                   R =/= unknown].

rate(Stats, Timestamp, OldStats, OldTimestamp, Key) ->
    case OldTimestamp == [] orelse not proplists:is_defined(Key, OldStats) of
        true  -> unknown;
        false -> Diff = pget(Key, Stats) - pget(Key, OldStats),
                 Name = details_key(Key),
                 Interval = timer:now_diff(Timestamp, OldTimestamp),
                 Rate = Diff / (Interval / 1000000),
                 {Name, [{rate, Rate},
                         {interval, Interval},
                         {last_event,
                          rabbit_mgmt_format:timestamp_ms(Timestamp)}]}
    end.

sum(List, Keys) ->
    lists:foldl(fun (I0, I1) -> gs_update(I0, I1, Keys) end,
                gs_update([], [], Keys), List).

%% List = [{ [{channel, Pid}, ...], [{deliver, 123}, ...] } ...]
group_sum([], List) ->
    lists:foldl(fun ({_, Item1}, Item0) ->
                        gs_update(Item0, Item1)
                end, [], List);

group_sum([Group | Groups], List) ->
    D = lists:foldl(
          fun (Next = {Ids, _}, Dict) ->
                  Id = {Group, pget(Group, Ids)},
                  dict:update(Id, fun(Cur) -> [Next | Cur] end, [Next], Dict)
          end, dict:new(), List),
    dict:map(fun(_, SubList) ->
                     group_sum(Groups, SubList)
             end, D).

gs_update(Item0, Item1) ->
    Keys = lists:usort([K || {K, _} <- Item0 ++ Item1]),
    gs_update(Item0, Item1, Keys).

gs_update(Item0, Item1, Keys) ->
    [{Key, gs_update_add(Key, pget(Key, Item0), pget(Key, Item1))} ||
        Key <- Keys].

gs_update_add(Key, Item0, Item1) ->
    case is_details(Key) of
        true  ->
            I0 = if_unknown(Item0, []),
            I1 = if_unknown(Item1, []),
            %% TODO if I0 and I1 are from different channels then should we not
            %% just throw away interval / last_event?
            [{rate,       pget(rate, I0, 0) + pget(rate, I1, 0)},
             {interval,   gs_max(interval, I0, I1)},
             {last_event, gs_max(last_event, I0, I1)}];
        false ->
            I0 = if_unknown(Item0, 0),
            I1 = if_unknown(Item1, 0),
            I0 + I1
    end.

gs_max(Key, I0, I1) ->
    erlang:max(pget(Key, I0, 0), pget(Key, I1, 0)).

if_unknown(unknown, Def) -> Def;
if_unknown(Val,    _Def) -> Val.

%%----------------------------------------------------------------------------

init([]) ->
    rabbit:force_event_refresh(),
    {ok, Interval} = application:get_env(rabbit, collect_statistics_interval),
    rabbit_log:info("Statistics database started.~n"),
    {ok, #state{interval = Interval,
                tables = orddict:from_list(
                           [{Key, ets:new(anon, [private, ordered_set])} ||
                               Key <- ?TABLES])}}.

handle_call({augment_exchanges, Xs, basic}, _From, State) ->
    {reply, exchange_stats(Xs, ?FINE_STATS_EXCHANGE_LIST, State), State};

handle_call({augment_exchanges, Xs, full}, _From, State) ->
    {reply, exchange_stats(Xs, ?FINE_STATS_EXCHANGE_DETAIL, State), State};

handle_call({augment_queues, Qs, basic}, _From, State) ->
    {reply, list_queue_stats(Qs, State), State};

handle_call({augment_queues, Qs, full}, _From, State) ->
    {reply, detail_queue_stats(Qs, State), State};

handle_call({get_channels, Names, Mode}, _From,
            State = #state{tables = Tables}) ->
    Chans = created_event(Names, channel_stats, Tables),
    Result = case Mode of
                 basic -> list_channel_stats(Chans, State);
                 full  -> detail_channel_stats(Chans, State)
             end,
    {reply, lists:map(fun result_or_error/1, Result), State};

handle_call({get_connections, Names}, _From,
            State = #state{tables = Tables}) ->
    Conns = created_event(Names, connection_stats, Tables),
    Result = connection_stats(Conns, State),
    {reply, lists:map(fun result_or_error/1, Result), State};

handle_call({get_all_channels, Mode}, _From, State = #state{tables = Tables}) ->
    Chans = created_events(channel_stats, Tables),
    Result = case Mode of
                 basic -> list_channel_stats(Chans, State);
                 full  -> detail_channel_stats(Chans, State)
             end,
    {reply, Result, State};

handle_call(get_all_connections, _From, State = #state{tables = Tables}) ->
    Conns = created_events(connection_stats, Tables),
    {reply, connection_stats(Conns, State), State};

handle_call({get_overview, User}, _From, State = #state{tables = Tables}) ->
    VHosts = case User of
                 all -> rabbit_vhost:list();
                 _   -> rabbit_mgmt_util:list_visible_vhosts(User)
             end,
    Qs0 = [rabbit_mgmt_format:queue(Q) || V <- VHosts,
                                          Q <- rabbit_amqqueue:list(V)],
    Qs1 = basic_queue_stats(Qs0, State),
    Totals = sum(Qs1, ?OVERVIEW_QUEUE_STATS),
    Filter = fun(Id, Name) ->
                     lists:member(pget(vhost, pget(Name, Id)), VHosts)
             end,
    F = fun(Type, Name) ->
                get_fine_stats_from_list(
                  [], [R || R = {Id, _, _}
                                <- ets:tab2list(orddict:fetch(Type, Tables)),
                            Filter(augment_msg_stats(format_id(Id), State),
                                   Name)], State)
        end,
    Publish = F(channel_exchange_stats, exchange),
    Consume = F(channel_queue_stats, queue_details),
    {reply, [{message_stats, Publish ++ Consume},
             {queue_totals, Totals}], State};

handle_call(_Request, _From, State) ->
    {reply, not_understood, State}.

handle_cast({event, Event}, State) ->
    handle_event(Event, State),
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_event(#event{type = queue_created, props = Props}, State) ->
    QName = pget(name, Props),
    case pget(synchronised_slave_pids, Props) of
        SSPids when is_list(SSPids) ->
            [handle_slave_synchronised(QName, SSPid, State) || SSPid <- SSPids];
        _ ->
            ok
    end,
    {ok, State};

handle_event(#event{type = queue_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(queue_stats, Stats, Timestamp,
                 [{fun rabbit_mgmt_format:properties/1,[backing_queue_status]},
                  {fun rabbit_mgmt_format:timestamp/1, [idle_since]}],
                 [messages, messages_ready, messages_unacknowledged], State),
    prune_synchronised_slaves(
      true, pget(name, Stats), pget(slave_pids, Stats), State);

handle_event(Event = #event{type = queue_deleted}, State) ->
    handle_deleted(queue_stats, Event, State);

handle_event(#event{type = connection_created, props = Stats}, State) ->
    Name = rabbit_mgmt_format:connection(Stats),
    handle_created(
      connection_stats, [{name, Name} | proplists:delete(name, Stats)],
      [{fun rabbit_mgmt_format:addr/1,         [address, peer_address]},
       {fun rabbit_mgmt_format:port/1,         [port, peer_port]},
       {fun rabbit_mgmt_format:protocol/1,     [protocol]},
       {fun rabbit_mgmt_format:amqp_table/1,   [client_properties]}], State);

handle_event(#event{type = connection_stats, props = Stats,
                    timestamp = Timestamp},
             State) ->
    handle_stats(connection_stats, Stats, Timestamp, [], [recv_oct, send_oct],
                 State);

handle_event(Event = #event{type = connection_closed}, State) ->
    handle_deleted(connection_stats, Event, State);

handle_event(#event{type = channel_created, props = Stats},
             State = #state{tables = Tables}) ->
    ConnTable = orddict:fetch(connection_stats, Tables),
    Conn = lookup_element(ConnTable, {id(pget(connection, Stats)), create}),
    Name = rabbit_mgmt_format:print("~s:~w",
                                    [pget(name,   Conn),
                                     pget(number, Stats)]),
    handle_created(channel_stats, [{name, Name}|Stats], [], State);

handle_event(#event{type = channel_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(channel_stats, Stats, Timestamp,
                 [{fun rabbit_mgmt_format:timestamp/1, [idle_since]}],
                 [], State),
    [handle_fine_stats(Type, Stats, Timestamp, State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(Event = #event{type = channel_closed,
                            props = [{pid, Pid}]}, State) ->
    handle_deleted(channel_stats, Event, State),
    [delete_fine_stats(Type, id(Pid), State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(#event{type = consumer_created, props = Props}, State) ->
    handle_consumer(fun(Table, Id, P) -> ets:insert(Table, {Id, P}) end,
                    Props, State);

handle_event(#event{type = consumer_deleted, props = Props}, State) ->
    handle_consumer(fun(Table, Id, _P) -> ets:delete(Table, Id) end,
                    Props, State);

handle_event(#event{type = queue_slave_synchronised, props = Props}, State) ->
    handle_slave_synchronised(pget(name, Props), pget(pid, Props), State);

handle_event(#event{type = queue_slave_promoted, props = Props}, State) ->
    handle_slave_promoted(pget(name, Props), pget(pid, Props), State);

handle_event(#event{type = queue_mirror_deaths, props = Props},
             State = #state{tables = Tables}) ->
    Dead = pget(pids, Props),
    Table = orddict:fetch(queue_stats, Tables),
    %% This is of course slow. It would be faster if the queue stats
    %% were keyed off queue name as well. But that's a big change, and
    %% this doesn't happen very often.
    prune_slaves(ets:match(Table, {{'$1', stats}, '$2', '$3'}, 100),
                 Dead, Table),
    prune_synchronised_slaves(false, pget(name, Props), Dead, State);

handle_event(_Event, State) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_created(TName, Stats, Funs, State = #state{tables = Tables}) ->
    Formatted = rabbit_mgmt_format:format(Stats, Funs),
    ets:insert(orddict:fetch(TName, Tables), {{id(Stats), create},
                                              Formatted,
                                              pget(name, Stats)}),
    {ok, State}.

handle_stats(TName, Stats0, Timestamp, Funs,
             RatesKeys, State = #state{tables = Tables}) ->
    Stats = lists:foldl(
              fun (K, StatsAcc) -> proplists:delete(K, StatsAcc) end,
              Stats0, ?FINE_STATS_TYPES),
    Table = orddict:fetch(TName, Tables),
    Id = {id(Stats), stats},
    OldStats = lookup_element(Table, Id),
    OldTimestamp = lookup_element(Table, Id, 3),
    Stats1 = rates(Stats, Timestamp, OldStats, OldTimestamp, RatesKeys),
    Stats2 = proplists:delete(pid, rabbit_mgmt_format:format(Stats1, Funs)),
    ets:insert(Table, {Id, Stats2, Timestamp}),
    {ok, State}.

handle_deleted(TName, #event{props = Props}, State = #state{tables = Tables}) ->
    Table = orddict:fetch(TName, Tables),
    Pid = pget(pid, Props),
    Name = pget(name, Props),
    ets:delete(Table, {id(Pid), create}),
    ets:delete(Table, {id(Pid), stats}),
    ets:delete(Table, {Name, synchronised_slaves}),
    {ok, State}.

handle_consumer(Fun, Props,
                State = #state{tables = Tables}) ->
    P = rabbit_mgmt_format:format(Props, []),
    Table = orddict:fetch(consumers, Tables),
    Fun(Table, {pget(queue, P), pget(channel, P)}, P),
    {ok, State}.

handle_slave_synchronised(QName, SSPid, State) ->
    SSNode = node(SSPid),
    update_synchronised_slaves(
      fun (SSNodes) -> case lists:member(SSNode, SSNodes) of
                           true  -> SSNodes;
                           false -> [SSNode | SSNodes]
                       end
      end, QName, State).

handle_slave_promoted(QName, NewMPid, State) ->
    update_synchronised_slaves(
      fun (SSNodes) -> SSNodes -- [node(NewMPid)] end, QName, State).

prune_synchronised_slaves(Member, QName, SPids, State) ->
    SNodes = [node(SPid) || SPid <- SPids],
    update_synchronised_slaves(
      fun (SSNodes) ->
              lists:filter(fun (S) -> lists:member(S, SNodes) =:= Member end,
                           SSNodes)
      end, QName, State).

update_synchronised_slaves(Fun, QName, State = #state{tables = Tables}) ->
    Table = orddict:fetch(queue_stats, Tables),
    New = case ets:lookup(Table, {QName, synchronised_slaves}) of
              []             -> Fun([]);
              [{_, SSNodes}] -> Fun(SSNodes)
          end,
    ets:insert(Table, {{QName, synchronised_slaves}, New}),
    {ok, State}.

prune_slaves('$end_of_table', _Dead, _Table) -> ok;

prune_slaves({Matches, Continuation}, Dead, Table) ->
    [prune_slaves0(M, Dead, Table) || M <- Matches],
    prune_slaves(ets:match(Continuation), Dead, Table).

prune_slaves0([Pid, Stats, Timestamp], Dead, Table) ->
    Old = pget(slave_pids, Stats),
    New = Old -- Dead,
    case New of
        Old -> ok;
        _   -> NewStats = pset(slave_pids, New, Stats),
               ets:insert(Table, {{Pid, stats}, NewStats, Timestamp})
    end.

handle_fine_stats(Type, Props, Timestamp, State = #state{tables = Tables}) ->
    case pget(Type, Props) of
        unknown ->
            ok;
        AllFineStats ->
            ChPid = id(Props),
            Table = orddict:fetch(Type, Tables),
            IdsStatsTS =
                [{Ids,
                  Stats,
                  lookup_element(Table, fine_stats_key(ChPid, Ids)),
                  lookup_element(Table, fine_stats_key(ChPid, Ids), 3)} ||
                    {Ids, Stats} <- AllFineStats],
            delete_fine_stats(Type, ChPid, State),
            [handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                              OldStats, OldTimestamp, Table) ||
                {Ids, Stats, OldStats, OldTimestamp} <- IdsStatsTS]
    end.


handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                 OldStats, OldTimestamp,
                 Table) ->
    Id = fine_stats_key(ChPid, Ids),
    Total = lists:sum([V || {K, V} <- Stats, lists:member(K, ?DELIVER_GET)]),
    Stats1 = case Total of
                 0 -> Stats;
                 _ -> [{deliver_get, Total}|Stats]
             end,
    Res = rates(Stats1, Timestamp, OldStats, OldTimestamp, ?FINE_STATS),
    ets:insert(Table, {Id, Res, Timestamp}).

delete_fine_stats(Type, ChPid, #state{tables = Tables}) ->
    Table = orddict:fetch(Type, Tables),
    ets:match_delete(Table, {{ChPid, '_'}, '_', '_'}),
    ets:match_delete(Table, {{ChPid, '_', '_'}, '_', '_'}).

fine_stats_key(ChPid, {QPid, X})              -> {ChPid, id(QPid), X};
fine_stats_key(ChPid, QPid) when is_pid(QPid) -> {ChPid, id(QPid)};
fine_stats_key(ChPid, X)                      -> {ChPid, X}.

created_event(Names, Type, Tables) ->
    Table = orddict:fetch(Type, Tables),
    [lookup_element(
       Table, {case ets:match(Table, {{'$1', create}, '_', Name}) of
                   []    -> none;
                   [[I]] -> I
               end, create}) || Name <- Names].

created_events(Type, Tables) ->
    [Facts || {{_, create}, Facts, _Name}
                  <- ets:tab2list(orddict:fetch(Type, Tables))].

get_fine_stats(Type, GroupBy, State = #state{tables = Tables}) ->
    get_fine_stats_from_list(
      GroupBy, ets:tab2list(orddict:fetch(Type, Tables)), State).

get_fine_stats_from_list(GroupBy, List, State) ->
    All = [{format_id(Id), zero_old_rates(Stats, State)} ||
              {Id, Stats, _Timestamp} <- List],
    group_sum(GroupBy, All).

format_id({ChPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {exchange, [{name, XName}, {vhost, XVhost}]}];
format_id({ChPid, QPid}) ->
    [{channel, ChPid}, {queue, QPid}];
format_id({ChPid, QPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {queue, QPid},
     {exchange, [{name, XName}, {vhost, XVhost}]}].

%%----------------------------------------------------------------------------

merge_stats(Objs, Funs) ->
    [lists:foldl(fun (Fun, Props) -> Fun(Props) ++ Props end, Obj, Funs)
     || Obj <- Objs].

basic_stats_fun(Type, State = #state{tables = Tables}) ->
    Table = orddict:fetch(Type, Tables),
    fun (Props) ->
            zero_old_rates(lookup_element(Table, {pget(pid, Props), stats}),
                           State)
    end.

fine_stats_fun(FineSpecs, State) ->
    FineStats = [{AttachName, AttachBy,
                  get_fine_stats(FineStatsType, GroupBy, State)}
                 || {FineStatsType, GroupBy, AttachName, AttachBy}
                        <- FineSpecs],
    fun (Props) ->
            lists:foldl(fun (FineStat, StatProps) ->
                                fine_stat(Props, StatProps, FineStat, State)
                        end, [], FineStats)
    end.

fine_stat(Props, StatProps, {AttachName, AttachBy, Dict}, State) ->
    Id = case AttachBy of
             exchange ->
                 [{name, pget(name, Props)}, {vhost, pget(vhost, Props)}];
             _ ->
                 pget(pid, Props)
         end,
    case dict:find({AttachBy, Id}, Dict) of
        {ok, Stats} -> [{AttachName, pget(AttachName, StatProps, []) ++
                             augment_fine_stats(Stats, State)} |
                        proplists:delete(AttachName, StatProps)];
        error       -> StatProps
    end.

augment_fine_stats(Dict, State) when element(1, Dict) == dict ->
    [[{stats, augment_fine_stats(Stats, State)} |
      augment_msg_stats([IdTuple], State)]
     || {IdTuple, Stats} <- dict:to_list(Dict)];
augment_fine_stats(Stats, _State) ->
    Stats.

consumer_details_fun(PatternFun, State = #state{tables = Tables}) ->
    Table = orddict:fetch(consumers, Tables),
    fun ([])    -> [];
        (Props) -> Pattern = PatternFun(Props),
                   [{consumer_details,
                     [augment_msg_stats(Obj, State)
                      || Obj <- lists:append(
                                  ets:match(Table, {Pattern, '$1'}))]}]
    end.

synchronised_slaves_fun(#state{tables = Tables}) ->
    Table = orddict:fetch(queue_stats, Tables),

    fun (Props) -> QName = rabbit_misc:r(pget(vhost, Props), queue,
                                         pget(name, Props)),
                   Key = {QName, synchronised_slaves},
                   case ets:lookup(Table, Key) of
                       []       -> [];
                       [{_, N}] -> [{synchronised_slave_nodes, N}]
                   end
    end.

zero_old_rates(Stats, State) -> [maybe_zero_rate(S, State) || S <- Stats].

maybe_zero_rate({Key, Val}, #state{interval = Interval}) ->
    case is_details(Key) of
        true  -> Age = rabbit_misc:now_ms() - pget(last_event, Val),
                 {Key, case Age > Interval * 1.5 of
                           true  -> pset(rate, 0, Val);
                           false -> Val
                       end};
        false -> {Key, Val}
    end.

is_details(Key) -> lists:suffix("_details", atom_to_list(Key)).

details_key(Key) -> list_to_atom(atom_to_list(Key) ++ "_details").

%%----------------------------------------------------------------------------

augment_msg_stats(Props, State) ->
    rabbit_mgmt_format:strip_pids(
      (augment_msg_stats_fun(State))(Props) ++ Props).

augment_msg_stats_fun(State) ->
    Funs = [{connection, fun augment_connection_pid/2},
            {channel,    fun augment_channel_pid/2},
            {queue,      fun augment_queue_pid/2},
            {owner_pid,  fun augment_connection_pid/2}],
    fun (Props) -> augment(Props, Funs, State) end.

augment(Items, Funs, State) ->
    Augmented = [augment(K, Items, Fun, State) || {K, Fun} <- Funs],
    [{K, V} || {K, V} <- Augmented, V =/= unknown].

augment(K, Items, Fun, State) ->
    Key = details_key(K),
    case pget(K, Items) of
        none    -> {Key, unknown};
        unknown -> {Key, unknown};
        Id      -> {Key, Fun(Id, State)}
    end.

augment_channel_pid(Pid, #state{tables = Tables}) ->
    Ch = lookup_element(orddict:fetch(channel_stats, Tables),
                        {Pid, create}),
    Conn = lookup_element(orddict:fetch(connection_stats, Tables),
                          {pget(connection, Ch), create}),
    [{name,            pget(name,   Ch)},
     {number,          pget(number, Ch)},
     {connection_name, pget(name,         Conn)},
     {peer_address,    pget(peer_address, Conn)},
     {peer_port,       pget(peer_port,    Conn)}].

augment_connection_pid(Pid, #state{tables = Tables}) ->
    Conn = lookup_element(orddict:fetch(connection_stats, Tables),
                          {Pid, create}),
    [{name,         pget(name,         Conn)},
     {peer_address, pget(peer_address, Conn)},
     {peer_port,    pget(peer_port,    Conn)}].

augment_queue_pid(Pid, _State) ->
    %% TODO This should be in rabbit_amqqueue?
    case mnesia:dirty_match_object(
           rabbit_queue, #amqqueue{pid = Pid, _ = '_'}) of
        [Q] -> Name = Q#amqqueue.name,
               [{name,  Name#resource.name},
                {vhost, Name#resource.virtual_host}];
        []  -> [] %% Queue went away before we could get its details.
    end.

%%----------------------------------------------------------------------------

basic_queue_stats(Objs, State) ->
    merge_stats(Objs, queue_funs(State)).

list_queue_stats(Objs, State) ->
    adjust_hibernated_memory_use(
      merge_stats(Objs, [fine_stats_fun(?FINE_STATS_QUEUE_LIST, State)] ++
                      queue_funs(State))).

detail_queue_stats(Objs, State) ->
    adjust_hibernated_memory_use(
      merge_stats(Objs, [consumer_details_fun(
                           fun (Props) -> {pget(pid, Props), '_'} end, State),
                         fine_stats_fun(?FINE_STATS_QUEUE_DETAIL, State)] ++
                      queue_funs(State))).

queue_funs(State) ->
    [basic_stats_fun(queue_stats, State), augment_msg_stats_fun(State),
     synchronised_slaves_fun(State)].

exchange_stats(Objs, FineSpecs, State) ->
    merge_stats(Objs, [fine_stats_fun(FineSpecs, State),
                       augment_msg_stats_fun(State)]).

connection_stats(Objs, State) ->
    merge_stats(Objs, [basic_stats_fun(connection_stats, State),
                       augment_msg_stats_fun(State)]).

list_channel_stats(Objs, State) ->
    merge_stats(Objs, [basic_stats_fun(channel_stats, State),
                       fine_stats_fun(?FINE_STATS_CHANNEL_LIST, State),
                       augment_msg_stats_fun(State)]).

detail_channel_stats(Objs, State) ->
    merge_stats(Objs, [basic_stats_fun(channel_stats, State),
                       consumer_details_fun(
                         fun (Props) -> {'_', pget(pid, Props)} end, State),
                       fine_stats_fun(?FINE_STATS_CHANNEL_DETAIL, State),
                       augment_msg_stats_fun(State)]).

%%----------------------------------------------------------------------------

%% We do this when retrieving the queue record rather than when
%% storing it since the memory use will drop *after* we find out about
%% hibernation, so to do it when we receive a queue stats event would
%% be fiddly and racy. This should be quite cheap though.
adjust_hibernated_memory_use(Qs) ->
    Pids = [pget(pid, Q) ||
               Q <- Qs, pget(idle_since, Q, not_idle) =/= not_idle],
    {Mem, _BadNodes} = delegate:invoke(
                         Pids, fun (Pid) -> process_info(Pid, memory) end),
    MemDict = dict:from_list([{P, M} || {P, M = {memory, _}} <- Mem]),
    [case dict:find(pget(pid, Q), MemDict) of
         error        -> Q;
         {ok, Memory} -> [Memory|proplists:delete(memory, Q)]
     end || Q <- Qs].
