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
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_federation_upstream).

-include("rabbit_federation.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-export([to_table/1, from_table/3, from_props/3, validate_table/1]).

%%----------------------------------------------------------------------------

to_table(#upstream{params   = #amqp_params_network{host         = H,
                                                   port         = P,
                                                   virtual_host = V,
                                                   ssl_options  = SSL},
                   exchange = X}) ->
    Protocol = case SSL of
                   none -> <<"amqp">>;
                   _    -> <<"amqps">>
               end,
    {table, [{<<"host">>,         longstr, list_to_binary(H)},
             {<<"protocol">>,     longstr, Protocol},
             {<<"port">>,         long,    P},
             {<<"virtual_host">>, longstr, V},
             {<<"exchange">>,     longstr, X}]}.

from_table({table, Table}, DefaultXName, DefaultVHost) ->
    TableProps = [{list_to_atom(binary_to_list(K)), V} || {K, _T, V} <- Table],
    from_props(TableProps, DefaultXName, DefaultVHost).

%% For all the props in Props1, does Props2 match?
all_match(Props1, Props2) ->
    lists:all(fun ({K, V}) -> proplists:get_value(K, Props2) == V end, Props1).

%% Add elements of Props1 which are not in Props2 - i.e. Props2 wins in event
%% of a clash
merge(Props1, Props2) ->
    lists:foldl(fun({K, V}, P) ->
                        case proplists:is_defined(K, Props2) of
                            true  -> P;
                            false -> [{K, V} | P]
                        end
                end, Props2, Props1).

binaryise_all(Items) -> [binaryise(I) || I <- Items].

binaryise(Props) -> [{K, binaryise0(V)} || {K, V} <- Props].

binaryise0(L) when is_list(L) -> list_to_binary(L);
binaryise0(X)                 -> X.

from_props(Props, DefaultXName, DefaultVHost) ->
    {ok, Brokers} = application:get_env(rabbitmq_federation, brokers),
    Final = case [Merged || BrokerProps <- binaryise_all(Brokers),
                            Merged      <- [merge(BrokerProps, Props)],
                            all_match(BrokerProps, Merged)] of
                []    -> Props;
                [P|_] -> P
            end,
    from_merged_props(binaryise(Props), DefaultXName, DefaultVHost).

from_merged_props(Props, DefaultXName, DefaultVHost) ->
    #upstream{params          = amqp_params_from_props(Props, DefaultVHost),
              exchange        = pget(exchange,        Props, DefaultXName),
              prefetch_count  = pget(prefetch_count,  Props, none),
              reconnect_delay = pget(reconnect_delay, Props, 1),
              queue_expires   = pget(queue_expires,   Props, 1800)}.

amqp_params_from_props(Props, DVHost) ->
    Params = #amqp_params_network{
      host         = binary_to_list(pget(host, Props)),
      port         = pget(port,         Props),
      virtual_host = pget(virtual_host, Props, DVHost),
      username     = pget(username,     Props, <<"guest">>),
      password     = pget(password,     Props, <<"guest">>)
     },
    lists:foldl(fun (F, ParamsIn) -> F(ParamsIn, Props) end, Params,
                [fun set_ssl_options/2,
                 fun set_default_port/2,
                 fun set_heartbeat/2,
                 fun set_mechanisms/2]).

set_ssl_options(Params, Props) ->
    case pget(protocol, Props, <<"amqp">>) of
        <<"amqp">>  -> Params;
        <<"amqps">> -> {ok, Opts} = application:get_env(
                                      rabbit_federation, ssl_options),
                       Params#amqp_params_network{ssl_options = Opts}
    end.

%% TODO this should be part of the Erlang client - see bug 24138
set_default_port(Params, _Props) ->
    case Params#amqp_params_network.port of
        undefined  -> Port = case Params#amqp_params_network.ssl_options of
                                 none -> 5672;
                                 _    -> 5671
                             end,
                      Params#amqp_params_network{port = Port};
        _          -> Params
    end.

set_heartbeat(Params, Props) ->
    case pget(heartbeat, Props, none) of
        none -> Params;
        H    -> Params#amqp_params_network{heartbeat = H}
    end.

%% TODO it would be nice to support arbitrary mechanisms here.
set_mechanisms(Params, Props) ->
    case pget(mechanism, Props, default) of
        default    -> Params;
        'EXTERNAL' -> Params#amqp_params_network{
                        auth_mechanisms =
                            [fun amqp_auth_mechanisms:external/3]};
        M          -> exit({unsupported_mechanism, M})
    end.

%%----------------------------------------------------------------------------

validate_table({table, Table}) ->
    Args = [{<<"host">>,         [longstr],                      true},
            {<<"protocol">>,     [longstr],                      false},
            {<<"port">>,         [byte, short, signedint, long], false},
            {<<"virtual_host">>, [longstr],                      false},
            {<<"exchange">>,     [longstr],                      false}],
    [check_arg(Table, K, Ts, M) || {K, Ts, M} <- Args];
validate_table({Type, Obj}) ->
    fail("Upstream ~w was of type ~s, not table", [Obj, Type]).

check_arg(Table, K, Ts, Mandatory) ->
    case {rabbit_misc:table_lookup(Table, K), Mandatory} of
        {{T,  _}, _}     -> case lists:member(T, Ts) of
                                true  -> ok;
                                false -> fail("~s should have type in ~p, "
                                              "but ~s was received",
                                              [K, Ts, T])
                            end;
        {_,       true}  -> fail("~s is mandatory", [K]);
        {_,       false} -> ok
    end.

fail(Fmt, Args) -> rabbit_misc:protocol_error(precondition_failed, Fmt, Args).

%% TODO remove
pget(K, P, D) -> proplists:get_value(K, P, D).
pget(K, P) -> proplists:get_value(K, P).