rabbitmq-mochiweb
-----------------

rabbitmq-mochiweb is a thin veneer around mochiweb that provides the
ability for multiple applications to co-exist on mochiweb
listeners. Applications can register static docroots or dynamic
handlers to be executed, dispatched by URL path prefix.

Note that the version of mochiweb built by rabbitmq-mochiweb depends
on features introduced in Erlang R13A.

Environment Variables
---------------------

rabbitmq-mochiweb uses the standard OTP environment variables
mechanism. A configuration has this structure:

    Env = [{listeners, [Listener...]},
           {contexts, [Context...]},
           {default_listener, ListenerOptions}]

    Listener = {Name, ListenerOptions}

    ListenerOptions = [{port, Port} | Option...]

    Context = {Name, ListenerName}
            | {Name, {ListenerName, Path}}

Installation
------------

After you've successfully run make on the plugin, the plugin can be
installed by copying the files in dist/ to your RabbitMQ
installation's plugins directory.

Configuration and API
---------------------

As indicated in the Environment Variables section, the
rabbitmq-mochiweb plugin supports OTP application configuration
values. These values can be set as either Erlang startup parameters or
via the rabbitmq.config file, with a block such as:

    {rabbitmq_mochiweb, [{default_listener, [{port, 5567}]}]}

When listeners are supplied, each listener must have a port number.  A
listener may have other options, which are supplied to mochiweb as-is,
aside from `name` and `loop`. `name` because that is generated from
the listener name, and `loop` because that is supplied for each
context.

Each context must give the name of a listener that appears in the list
of listeners. It may give a path, which overrides any path given for a
context when it is registered. This configuration

    {rabbitmq_mochiweb, [{listeners, [{internal, [{port, 5568}]}]},
                         {contexts, [{foo, {internal, "bar"}}]}]}

assigns the context named `foo` to the listener on port 5568 and
forces its path prefix to `"bar"`.

To give a path for a context, but let it use the default listener, use
`'*'` as the listener name. For example:

    {rabbitmq_mochiweb, [{default_listener, [{port, 5567}]},
                         {contexts, [{foo, {'*', "bar"}}]}]}

will let the context `foo` default to the listener on port 5567, but
force its path prefix to `"bar"`.

The procedures `register_*` exported from the module `rabbit_mochiweb`
all take a context and a path as the first two arguments.

When an application registers a context with rabbitmq-mochiweb, it
supplies a context name, which is expected to be unique to that
application, and a path prefix. If this context is mentioned in the
environment, it is assigned to the listener given there. Its path
prefix may also be overidden if it is given in the configuration. If
it is not mentioned or gives the listener `'*'`, it is assigned to the
default listener.

For example, for the configuration

    {rabbitmq_mochiweb, [{default_listener, [{port, 55670}]},
                         {listeners, [{internal, [{port, 55671}]}]},
                         {contexts,  [{myapp, {internal, "mine"}}]}]}

an application registering the context name `myapp` will be assigned
to the listener `internal`, listening on port 55671, and be available
under the path "/mine/" in URLs. An application registering with the
context `yourapp` and the path `"yours"` will be assigned to the
default listener, listening on port 55670, and be available under
"/yours/".

There is no attempt made to avoid clashes of paths, either those given
in configuration or those given when registering.  Also note that an
application may register more than one context.

The most general registration procedure is
`rabbit_mochiweb:register_context_handler/4`. This takes a callback
procedure of the form

    loop({PathPrefix, Listener}, Request) ->
      ...

The procedures `rabbit_mochiweb:context_path/1` and
`rabbit_mochiweb:context_listener/1` may be used to obtain information
about a context and the listener it is assigned to; for example, its
port.

The module `rabbit_webmachine` provides a means of running more than
one webmachine in a VM, and understands rabbitmq-mochiweb contexts. To
use it, supply a dispatch table term of the kind usually given to
webmachine in the file `priv/dispatch.conf`.

`setup/{1,2}` in the same module allows some global configuration of
webmachine logging and error handling.
