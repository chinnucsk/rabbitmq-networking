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
%%   The Original Code is RabbitMQ Management Console.
%%
%%   The Initial Developers of the Original Code are Rabbit Technologies Ltd.
%%
%%   Copyright (C) 2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
-module(rabbit_mgmt_test_clustering).

-include("rabbit_mgmt_test.hrl").

-export([start_second_node/0, stop_second_node/0]).

-import(rabbit_mgmt_test_http, [http_get/1, http_put/3, http_delete/2]).
-import(rabbit_misc, [pget/2]).

%%----------------------------------------------------------------------------

start_second_node() ->
    %% ?assertCmd seems to hang if you background anything. Bah!
    Res = os:cmd("make -C " ++ plugin_dir() ++ " start-second-node ; echo $?"),
    LastLine = hd(lists:reverse(string:tokens(Res, "\n"))),
    ?assertEqual("0", LastLine).

stop_second_node() ->
    ?assertCmd("make -C " ++ plugin_dir() ++ " stop-second-node").

plugin_dir() ->
    {ok, [[File]]} = init:get_argument(config),
    filename:dirname(filename:dirname(File)).

%%----------------------------------------------------------------------------

cluster_nodes_test() ->
    ?assertEqual(2, length(http_get("/nodes"))),
    ok.

ha_test_() ->
    {timeout, 60, fun ha/0}.

ha() ->
    QArgs = [{node,      <<"hare">>},
             {arguments, [{'x-ha-policy', all}]}],
    http_put("/queues/%2f/ha-queue", QArgs, ?NO_CONTENT),
    Q = wait_for("/queues/%2f/ha-queue"),
    assert_node(hare, pget(node, Q)),
    assert_single_node('rabbit-test', pget(slave_nodes, Q)),
    assert_single_node('rabbit-test', pget(synchronised_slave_nodes, Q)),
    restart_node(),
    Q2 = wait_for("/queues/%2f/ha-queue"),
    assert_node('rabbit-test', pget(node, Q2)),
    assert_single_node(hare, pget(slave_nodes, Q2)),
    assert_single_node(hare, pget(synchronised_slave_nodes, Q2)),
    http_delete("/queues/%2f/ha-queue", ?NO_CONTENT),
    ok.

%%----------------------------------------------------------------------------

wait_for(Path) ->
    wait_for(Path, [slave_nodes, synchronised_slave_nodes]).

wait_for(Path, Keys) ->
    wait_for(Path, Keys, 1000).

wait_for(Path, Keys, 0) ->
    exit({timeout, {Path, Keys}});

wait_for(Path, Keys, Count) ->
    Res = http_get(Path),
    case present(Keys, Res) of
        false -> timer:sleep(10),
                 wait_for(Path, Keys, Count - 1);
        true  -> Res
    end.

present(Keys, Res) ->
    lists:all(fun (Key) ->
                      X = pget(Key, Res),
                      X =/= [] andalso X =/= undefined
              end, Keys).

assert_single_node(Exp, Act) ->
    ?assertEqual(1, length(Act)),
    assert_node(Exp, hd(Act)).

assert_node(Exp, Act) ->
    ?assertEqual(Exp,
                 list_to_atom(hd(string:tokens(binary_to_list(Act), "@")))).

restart_node() ->
    stop_second_node(),
    timer:sleep(1000),
    start_second_node().
