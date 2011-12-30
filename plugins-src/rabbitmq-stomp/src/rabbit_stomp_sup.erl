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
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
-module(rabbit_stomp_sup).
-behaviour(supervisor).

-export([start_link/2, init/1]).

-export([listener_started/3, listener_stopped/3,
         start_client/2, start_ssl_client/3]).

start_link(Listeners, Configuration) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE,
                          [Listeners, Configuration]).

init([{Listeners, SslListeners}, Configuration]) ->
    {ok, SocketOpts} = application:get_env(rabbitmq_stomp, tcp_listen_options),

    SslOpts = case SslListeners of
                  [] -> none;
                  _  -> rabbit_networking:ensure_ssl()
              end,

    {ok, {{one_for_all, 10, 10},
          [{rabbit_stomp_client_sup_sup,
            {rabbit_client_sup, start_link,
             [{local, rabbit_stomp_client_sup_sup},
              {rabbit_stomp_client_sup, start_link,[]}]},
            transient, infinity, supervisor, [rabbit_client_sup]} |
           listener_specs(fun tcp_listener_spec/1,
                          [SocketOpts, Configuration], Listeners) ++
           listener_specs(fun ssl_listener_spec/1,
                          [SocketOpts, SslOpts, Configuration], SslListeners)]}}.

listener_specs(Fun, Args, Listeners) ->
    [Fun([Address | Args]) ||
        Listener <- Listeners,
        Address <- rabbit_networking:check_tcp_listener_address(
                     rabbit_stomp_listener_sup, Listener)].

tcp_listener_spec([Address, SocketOpts, Configuration]) ->
    listener_spec(Address, SocketOpts, stomp,
                  {?MODULE, start_client, [Configuration]},
                  "STOMP TCP Listener").

ssl_listener_spec([Address, SocketOpts, SslOpts, Configuration]) ->
    listener_spec(Address, SocketOpts, 'stomp/ssl',
                  {?MODULE, start_ssl_client, [Configuration, SslOpts]},
                  "STOMP SSL Listener").

listener_spec({IPAddress, Port, Family, Name},
              SocketOpts, Protocol, OnConnect, Label) ->
    {Name,
     {tcp_listener_sup, start_link,
      [IPAddress, Port,
       [Family | SocketOpts],
       {?MODULE, listener_started, [Protocol]},
       {?MODULE, listener_stopped, [Protocol]},
       OnConnect, Label]},
     transient, infinity, supervisor, [tcp_listener_sup]}.

listener_started(Protocol, IPAddress, Port) ->
    rabbit_networking:tcp_listener_started(Protocol, IPAddress, Port).

listener_stopped(Protocol, IPAddress, Port) ->
    rabbit_networking:tcp_listener_stopped(Protocol, IPAddress, Port).

start_client(Configuration, Sock) ->
    {ok, SupPid, ReaderPid} =
        supervisor:start_child(rabbit_stomp_client_sup_sup,
                               [Sock, Configuration]),
    ok = rabbit_net:controlling_process(Sock, ReaderPid),
    ReaderPid ! {go, Sock},
    SupPid.

start_ssl_client(Configuration, SslOpts, Sock) ->
    Transform = rabbit_networking:ssl_transform_fun(SslOpts),
    {ok, SslSock} = Transform(Sock),
    start_client(Configuration, SslSock).

