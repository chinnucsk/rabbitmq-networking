%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(emqtt_networking).

-export([boot/0, start/0, start_tcp_listener/1, 
         stop_tcp_listener/1, on_node_down/1, active_listeners/0,
         node_listeners/1, connections/0, connection_info_keys/0,
         connection_info/1, connection_info/2,
         connection_info_all/0, connection_info_all/1,
         close_connection/2, force_connection_event_refresh/0]).

%%used by TCP-based transports, e.g. STOMP adapter
-export([check_tcp_listener_address/2]).

-export([tcp_listener_started/3, tcp_listener_stopped/3,
         start_client/1]).

%% Internal
-export([connections_local/0]).

-include("emqtt.hrl").
-include_lib("kernel/include/inet.hrl").

-define(SSL_TIMEOUT, 5). %% seconds

-define(FIRST_TEST_BIND_PORT, 10000).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([ip_port/0, hostname/0]).

-type(hostname() :: inet:hostname()).
-type(ip_port() :: inet:ip_port()).

-type(family() :: atom()).
-type(listener_config() :: ip_port() |
                           {hostname(), ip_port()} |
                           {hostname(), ip_port(), family()}).

-spec(start/0 :: () -> 'ok').
-spec(start_tcp_listener/1 :: (listener_config()) -> 'ok').
-spec(stop_tcp_listener/1 :: (listener_config()) -> 'ok').
-spec(active_listeners/0 :: () -> [emqtt_types:listener()]).
-spec(node_listeners/1 :: (node()) -> [emqtt_types:listener()]).
-spec(connections/0 :: () -> [emqtt_types:connection()]).
-spec(connections_local/0 :: () -> [emqtt_types:connection()]).
-spec(connection_info_keys/0 :: () -> emqtt_types:info_keys()).
-spec(connection_info/1 ::
        (emqtt_types:connection()) -> emqtt_types:infos()).
-spec(connection_info/2 ::
        (emqtt_types:connection(), emqtt_types:info_keys())
        -> emqtt_types:infos()).
-spec(connection_info_all/0 :: () -> [emqtt_types:infos()]).
-spec(connection_info_all/1 ::
        (emqtt_types:info_keys()) -> [emqtt_types:infos()]).
-spec(close_connection/2 :: (pid(), string()) -> 'ok').
-spec(force_connection_event_refresh/0 :: () -> 'ok').

-spec(on_node_down/1 :: (node()) -> 'ok').
-spec(check_tcp_listener_address/2 :: (atom(), listener_config())
        -> [{inet:ip_address(), ip_port(), family(), atom()}]).

-spec(boot/0 :: () -> 'ok').
-spec(start_client/1 :: ( port() ) -> 
	atom() | pid() | port() | {atom(),atom()}).
-spec(tcp_listener_started/3 ::
	(_,
         string() |
	 {byte(),byte(),byte(),byte()} |
	 {char(),char(),char(),char(),char(),char(),char(),char()},
	 _) ->
				     'ok').
-spec(tcp_listener_stopped/3 ::
	(_,
         string() |
	 {byte(),byte(),byte(),byte()} |
	 {char(),char(),char(),char(),char(),char(),char(),char()},
	 _) ->
				     'ok').

-endif.

%%----------------------------------------------------------------------------

boot() ->
    ok = start(),
    ok = boot_tcp().

boot_tcp() ->
    {ok, TcpListeners} = application:get_env(tcp_listeners),
    [ok = start_tcp_listener(Listener) || Listener <- TcpListeners],
    ok.

start() ->
    {ok,_} = supervisor2:start_child(
               emqtt_sup,
               {emqtt_tcp_client_sup,
                {emqtt_client_sup, start_link,
                 [{local, emqtt_tcp_client_sup},
                  {emqtt_connection_sup,start_link,[]}]},
                transient, infinity, supervisor, [emqtt_client_sup]}),
    ok.

%% inet_parse:address takes care of ip string, like "0.0.0.0"
%% inet:getaddr returns immediately for ip tuple {0,0,0,0},
%%  and runs 'inet_gethost' port process for dns lookups.
%% On Windows inet:getaddr runs dns resolver for ip string, which may fail.

getaddr(Host, Family) ->
    case inet_parse:address(Host) of
        {ok, IPAddress} -> [{IPAddress, resolve_family(IPAddress, Family)}];
        {error, _}      -> gethostaddr(Host, Family)
    end.

gethostaddr(Host, auto) ->
    Lookups = [{Family, inet:getaddr(Host, Family)} || Family <- [inet, inet6]],
    case [{IP, Family} || {Family, {ok, IP}} <- Lookups] of
        []  -> host_lookup_error(Host, Lookups);
        IPs -> IPs
    end;

gethostaddr(Host, Family) ->
    case inet:getaddr(Host, Family) of
        {ok, IPAddress} -> [{IPAddress, Family}];
        {error, Reason} -> host_lookup_error(Host, Reason)
    end.

host_lookup_error(Host, Reason) ->
    error_logger:error_msg("invalid host ~p - ~p~n", [Host, Reason]),
    throw({error, {invalid_host, Host, Reason}}).

resolve_family({_,_,_,_},         auto) -> inet;
resolve_family({_,_,_,_,_,_,_,_}, auto) -> inet6;
resolve_family(IP,                auto) -> throw({error, {strange_family, IP}});
resolve_family(_,                 F)    -> F.

check_tcp_listener_address(NamePrefix, Port) when is_integer(Port) ->
    check_tcp_listener_address_auto(NamePrefix, Port);

check_tcp_listener_address(NamePrefix, {"auto", Port}) ->
    %% Variant to prevent lots of hacking around in bash and batch files
    check_tcp_listener_address_auto(NamePrefix, Port);

check_tcp_listener_address(NamePrefix, {Host, Port}) ->
    %% auto: determine family IPv4 / IPv6 after converting to IP address
    check_tcp_listener_address(NamePrefix, {Host, Port, auto});

check_tcp_listener_address(NamePrefix, {Host, Port, Family0}) ->
    if is_integer(Port) andalso (Port >= 0) andalso (Port =< 65535) -> ok;
       true -> error_logger:error_msg("invalid port ~p - not 0..65535~n",
                                      [Port]),
               throw({error, {invalid_port, Port}})
    end,
    [{IPAddress, Port, Family,
      emqtt_misc:tcp_name(NamePrefix, IPAddress, Port)} ||
        {IPAddress, Family} <- getaddr(Host, Family0)].

check_tcp_listener_address_auto(NamePrefix, Port) ->
    lists:append([check_tcp_listener_address(NamePrefix, Listener) ||
                     Listener <- port_to_listeners(Port)]).

start_tcp_listener(Listener) ->
    start_listener(Listener, mqtt, "TCP Listener",
                   {?MODULE, start_client, []}).

start_listener(Listener, Protocol, Label, OnConnect) ->
    [start_listener0(Spec, Protocol, Label, OnConnect) ||
        Spec <- check_tcp_listener_address(emqtt_tcp_listener_sup, Listener)],
    ok.

start_listener0({IPAddress, Port, Family, Name}, Protocol, Label, OnConnect) ->
    {ok,_} = supervisor:start_child(
               emqtt_sup,
               {Name,
                {tcp_listener_sup, start_link,
                 [IPAddress, Port, [Family | tcp_opts()],
                  {?MODULE, tcp_listener_started, [Protocol]},
                  {?MODULE, tcp_listener_stopped, [Protocol]},
                  OnConnect, Label]},
                transient, infinity, supervisor, [tcp_listener_sup]}).

stop_tcp_listener(Listener) ->
    [stop_tcp_listener0(Spec) ||
        Spec <- check_tcp_listener_address(emqtt_tcp_listener_sup, Listener)],
    ok.

stop_tcp_listener0({IPAddress, Port, _Family, Name}) ->
    Name = emqtt_misc:tcp_name(emqtt_tcp_listener_sup, IPAddress, Port),
    ok = supervisor:terminate_child(emqtt_sup, Name),
    ok = supervisor:delete_child(emqtt_sup, Name).

tcp_listener_started(Protocol, IPAddress, Port) ->
    %% We need the ip to distinguish e.g. 0.0.0.0 and 127.0.0.1
    %% We need the host so we can distinguish multiple instances of the above
    %% in a cluster.
    ok = mnesia:dirty_write(
           emqtt_listener,
           #listener{node = node(),
                     protocol = Protocol,
                     host = tcp_host(IPAddress),
                     ip_address = IPAddress,
                     port = Port}).

tcp_listener_stopped(Protocol, IPAddress, Port) ->
    ok = mnesia:dirty_delete_object(
           emqtt_listener,
           #listener{node = node(),
                     protocol = Protocol,
                     host = tcp_host(IPAddress),
                     ip_address = IPAddress,
                     port = Port}).

active_listeners() ->
    emqtt_misc:dirty_read_all(emqtt_listener).

node_listeners(Node) ->
    mnesia:dirty_read(emqtt_listener, Node).

on_node_down(Node) ->
    ok = mnesia:dirty_delete(emqtt_listener, Node).

start_client(Sock) ->
    {ok, _Child, Reader} = supervisor:start_child(emqtt_tcp_client_sup, [Sock]),
    emqtt_net:controlling_process(Sock, Reader),
    Reader.

connections() ->
    emqtt_misc:append_rpc_all_nodes(emqtt_mnesia:running_clustered_nodes(),
                                     emqtt_networking, connections_local, []).

connections_local() ->
    [Reader ||
        {_, ConnSup, supervisor, _}
            <- supervisor:which_children(emqtt_tcp_client_sup),
        Reader <- [try
                       emqtt_connection_sup:reader(ConnSup)
                   catch exit:{noproc, _} ->
                           noproc
                   end],
        Reader =/= noproc].

connection_info_keys() -> emqtt_reader:info_keys().

connection_info(Pid) -> emqtt_reader:info(Pid).
connection_info(Pid, Items) -> emqtt_reader:info(Pid, Items).

connection_info_all() -> cmap(fun (Q) -> connection_info(Q) end).
connection_info_all(Items) -> cmap(fun (Q) -> connection_info(Q, Items) end).

close_connection(Pid, Explanation) ->
    emqtt_log:info("Closing connection ~p because ~p~n", [Pid, Explanation]),
    case lists:member(Pid, connections()) of
        true  -> emqtt_reader:shutdown(Pid, Explanation);
        false -> throw({error, {not_a_connection_pid, Pid}})
    end.

force_connection_event_refresh() ->
    [emqtt_reader:force_event_refresh(C) || C <- connections()],
    ok.

%%--------------------------------------------------------------------

tcp_host({0,0,0,0}) ->
    hostname();

tcp_host({0,0,0,0,0,0,0,0}) ->
    hostname();

tcp_host(IPAddress) ->
    case inet:gethostbyaddr(IPAddress) of
        {ok, #hostent{h_name = Name}} -> Name;
        {error, _Reason} -> emqtt_misc:ntoa(IPAddress)
    end.

hostname() ->
    {ok, Hostname} = inet:gethostname(),
    case inet:gethostbyname(Hostname) of
        {ok,    #hostent{h_name = Name}} -> Name;
        {error, _Reason}                 -> Hostname
    end.

cmap(F) -> emqtt_misc:filter_exit_map(F, connections()).

tcp_opts() ->
    {ok, Opts} = application:get_env(emqtt, tcp_listen_options),
    Opts.

%%--------------------------------------------------------------------

%% There are three kinds of machine (for our purposes).
%%
%% * Those which treat IPv4 addresses as a special kind of IPv6 address
%%   ("Single stack")
%%   - Linux by default, Windows Vista and later
%%   - We also treat any (hypothetical?) IPv6-only machine the same way
%% * Those which consider IPv6 and IPv4 to be completely separate things
%%   ("Dual stack")
%%   - OpenBSD, Windows XP / 2003, Linux if so configured
%% * Those which do not support IPv6.
%%   - Ancient/weird OSes, Linux if so configured
%%
%% How to reconfigure Linux to test this:
%% Single stack (default):
%% echo 0 > /proc/sys/net/ipv6/bindv6only
%% Dual stack:
%% echo 1 > /proc/sys/net/ipv6/bindv6only
%% IPv4 only:
%% add ipv6.disable=1 to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub then
%% sudo update-grub && sudo reboot
%%
%% This matters in (and only in) the case where the sysadmin (or the
%% app descriptor) has only supplied a port and we wish to bind to
%% "all addresses". This means different things depending on whether
%% we're single or dual stack. On single stack binding to "::"
%% implicitly includes all IPv4 addresses, and subsequently attempting
%% to bind to "0.0.0.0" will fail. On dual stack, binding to "::" will
%% only bind to IPv6 addresses, and we need another listener bound to
%% "0.0.0.0" for IPv4. Finally, on IPv4-only systems we of course only
%% want to bind to "0.0.0.0".
%%
%% Unfortunately it seems there is no way to detect single vs dual stack
%% apart from attempting to bind to the port.
port_to_listeners(Port) ->
    IPv4 = {"0.0.0.0", Port, inet},
    IPv6 = {"::",      Port, inet6},
    case ipv6_status(?FIRST_TEST_BIND_PORT) of
        single_stack -> [IPv6];
        ipv6_only    -> [IPv6];
        dual_stack   -> [IPv6, IPv4];
        ipv4_only    -> [IPv4]
    end.

ipv6_status(TestPort) ->
    IPv4 = [inet,  {ip, {0,0,0,0}}],
    IPv6 = [inet6, {ip, {0,0,0,0,0,0,0,0}}],
    case gen_tcp:listen(TestPort, IPv6) of
        {ok, LSock6} ->
            case gen_tcp:listen(TestPort, IPv4) of
                {ok, LSock4} ->
                    %% Dual stack
                    gen_tcp:close(LSock6),
                    gen_tcp:close(LSock4),
                    dual_stack;
                %% Checking the error here would only let us
                %% distinguish single stack IPv6 / IPv4 vs IPv6 only,
                %% which we figure out below anyway.
                {error, _} ->
                    gen_tcp:close(LSock6),
                    case gen_tcp:listen(TestPort, IPv4) of
                        %% Single stack
                        {ok, LSock4}            -> gen_tcp:close(LSock4),
                                                   single_stack;
                        %% IPv6-only machine. Welcome to the future.
                        {error, eafnosupport}   -> ipv6_only;
                        %% Dual stack machine with something already
                        %% on IPv4.
                        {error, _}              -> ipv6_status(TestPort + 1)
                    end
            end;
        {error, eafnosupport} ->
            %% IPv4-only machine. Welcome to the 90s.
            ipv4_only;
        {error, _} ->
            %% Port in use
            ipv6_status(TestPort + 1)
    end.
