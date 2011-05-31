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

-module(rabbit_federation_unit_test).

-define(INFO, [{<<"baz">>, longstr, <<"bam">>}]).
-define(H, <<"x-forwarding">>).

-define(TEST_NAME, <<"TEST">>).

-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%% Test that we add routing information to message headers sensibly.
routing_test() ->
    ?assertEqual([{<<"x-forwarding">>, array, [{table, ?INFO}]}],
                 add(undefined)),

    ?assertEqual([{<<"x-forwarding">>, array, [{table, ?INFO}]}],
                 add([])),

    ?assertEqual([{<<"foo">>, longstr, <<"bar">>},
                  {<<"x-forwarding">>, array, [{table, ?INFO}]}],
                 add([{<<"foo">>, longstr, <<"bar">>}])),

    ?assertEqual([{<<"x-forwarding">>, array, [{table, ?INFO},
                                               {table, ?INFO}]}],
                 add([{<<"x-forwarding">>, array, [{table, ?INFO}]}])),
    ok.

add(Table) ->
    rabbit_federation_link:add_routing_to_headers(Table, ?INFO).

%% Test that we apply binding changes in the correct order even when
%% they arrive out of order.
serialisation_test() ->
    rabbit_exchange:declare(r(<<"upstream">>), fanout,
                            false, false, false, []),
    X = x(),
    B1 = b(<<"1">>),
    B2 = b(<<"2">>),
    B3 = b(<<"3">>),

    create(X),
    %% TODO this only passes as long as we don't permute the list!
    add_binding(1, X, B1),
    add_binding(2, X, B2),
    add_binding(3, X, B3),
    remove_bindings(4, X, [B1, B3]),
    add_binding(5, X, B1),

    %% List of lists because one for each link
    ?assertEqual([[<<"1">>, <<"2">>]],
                 rabbit_federation_link:list_routing_keys(X)),

    delete(X, [B1, B3]),
    rabbit_exchange:delete(r(<<"upstream">>), false),
    ok.

create(X) ->
    rabbit_federation_exchange:create(transaction, X),
    rabbit_federation_exchange:create(none, X).

delete(X, Bs) ->
    rabbit_federation_exchange:delete(transaction, X, Bs),
    rabbit_federation_exchange:delete(none, X, Bs).

add_binding(Ser, X, B) ->
    rabbit_federation_exchange:add_binding(transaction, X, B),
    rabbit_federation_exchange:add_binding(Ser, X, B).

remove_bindings(Ser, X, Bs) ->
    rabbit_federation_exchange:remove_bindings(transaction, X, Bs),
    rabbit_federation_exchange:remove_bindings(Ser, X, Bs).

x() ->
    Upstreams = [{table, [{<<"host">>,    longstr,  <<"localhost">>},
                          {<<"exchange">>,longstr,  <<"upstream">>}]}],
    Args = [{<<"upstreams">>, array,   Upstreams},
            {<<"type">>,      longstr, <<"fanout">>}],
    #exchange{name      = r(?TEST_NAME),
              type      = <<"x-federation">>,
              arguments = Args}.

r(Name) -> rabbit_misc:r(<<"/">>, exchange, Name).

b(Key) ->
    #binding{source = ?TEST_NAME, destination = ?TEST_NAME,
             key = Key, args = []}.