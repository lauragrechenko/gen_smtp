%%% Copyright 2009 Jack Danger Canty <code@jackcanty.com>. All rights reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining
%%% a copy of this software and associated documentation files (the
%%% "Software"), to deal in the Software without restriction, including
%%% without limitation the rights to use, copy, modify, merge, publish,
%%% distribute, sublicense, and/or sell copies of the Software, and to
%%% permit persons to whom the Software is furnished to do so, subject to
%%% the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be
%%% included in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
%%% LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
%%% OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
%%% WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

%% @doc Facilitates transparent gen_tcp/ssl socket handling
-module(smtp_socket).

-define(TCP_LISTEN_OPTIONS, [
    {active, false},
    {backlog, 30},
    {ip, {0, 0, 0, 0}},
    {keepalive, true},
    {packet, line},
    {reuseaddr, true}
]).
-define(TCP_CONNECT_OPTIONS, [
    {active, false},
    {packet, line},
    {ip, {0, 0, 0, 0}},
    {port, 0}
]).
-define(SSL_LISTEN_OPTIONS, [
    {active, false},
    {backlog, 30},
    {certfile, "server.crt"},
    {depth, 0},
    {keepalive, true},
    {keyfile, "server.key"},
    {packet, line},
    {reuse_sessions, false},
    {reuseaddr, true}
]).
-define(SSL_CONNECT_OPTIONS, [
    {active, false},
    {depth, 0},
    {packet, line},
    {ip, {0, 0, 0, 0}},
    {port, 0},
    {verify, verify_none}
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([connect/3, connect/4, connect/5]).
-export([listen/2, listen/3, accept/1, accept/2]).
-export([send/2, recv/2, recv/3]).
-export([controlling_process/2]).
-export([peername/1]).
-export([close/1, shutdown/2]).
-export([active_once/1]).
-export([setopts/2]).
-export([get_proto/1]).
-export([begin_inet_async/1]).
-export([handle_inet_async/1, handle_inet_async/2, handle_inet_async/3]).
-export([extract_port_from_socket/1]).
-export([to_ssl_server/1, to_ssl_server/2, to_ssl_server/3]).
-export([to_ssl_client/1, to_ssl_client/2, to_ssl_client/3]).
-export([type/1]).

-type protocol() :: 'tcp' | 'ssl'.
-type address() :: inet:ip_address() | string() | binary().
-type socket() :: ssl:sslsocket() | gen_tcp:socket().

-export_type([socket/0]).

%%%-----------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------
-spec connect(Protocol :: protocol(), Address :: address(), Port :: pos_integer()) ->
    {ok, socket()} | {error, any()}.
connect(Protocol, Address, Port) ->
    connect(Protocol, Address, Port, [], infinity).

-spec connect(
    Protocol :: protocol(), Address :: address(), Port :: pos_integer(), Options :: list()
) -> {ok, socket()} | {error, any()}.
connect(Protocol, Address, Port, Opts) ->
    connect(Protocol, Address, Port, Opts, infinity).

-spec connect(
    Protocol :: protocol(),
    Address :: address(),
    Port :: pos_integer(),
    Options :: list(),
    Time :: non_neg_integer() | 'infinity'
) -> {ok, socket()} | {error, any()}.
connect(tcp, Address, Port, Opts, Time) ->
    gen_tcp:connect(Address, Port, tcp_connect_options(Opts), Time);
connect(ssl, Address, Port, Opts, Time) ->
    SslOpts = ssl_connect_options(Opts),
    io:format("[LAURA_IS_HERE] SMTP_SOCKET SSL Options = ~p~n", [SslOpts]),
    io:format("[LAURA_IS_HERE] SMTP_SOCKET Options = ~p~n", [Opts]),
    ssl:connect(Address, Port, SslOpts, Time).

-spec listen(Protocol :: protocol(), Port :: pos_integer()) -> {ok, socket()} | {error, any()}.
listen(Protocol, Port) ->
    listen(Protocol, Port, []).

-spec listen(Protocol :: protocol(), Port :: pos_integer(), Options :: list()) ->
    {ok, socket()} | {error, any()}.
listen(ssl, Port, Options) ->
    ssl:listen(Port, ssl_listen_options(Options));
listen(tcp, Port, Options) ->
    gen_tcp:listen(Port, tcp_listen_options(Options)).

-spec accept(Socket :: socket()) -> {'ok', socket()} | {'error', any()}.
accept(Socket) ->
    accept(Socket, infinity).

-spec accept(Socket :: socket(), Timeout :: pos_integer() | 'infinity') ->
    {'ok', socket()} | {'error', any()}.
accept(Socket, Timeout) when is_port(Socket) ->
    case gen_tcp:accept(Socket, Timeout) of
        {ok, NewSocket} ->
            {ok, Opts} = inet:getopts(Socket, [active, keepalive, packet, reuseaddr]),
            inet:setopts(NewSocket, Opts),
            {ok, NewSocket};
        {error, _} = Error ->
            Error
    end;
accept(Socket, Timeout) ->
    case ssl:transport_accept(Socket, Timeout) of
        {ok, NewSocket} ->
            ssl:handshake(NewSocket);
        {error, _} = Error ->
            Error
    end.

-spec send(Socket :: socket(), Data :: binary() | string() | iolist()) -> 'ok' | {'error', any()}.
send(Socket, Data) when is_port(Socket) ->
    gen_tcp:send(Socket, Data);
send(Socket, Data) ->
    ssl:send(Socket, Data).

-spec recv(Socket :: socket(), Length :: non_neg_integer()) -> {'ok', any()} | {'error', any()}.
recv(Socket, Length) ->
    recv(Socket, Length, infinity).

-spec recv(
    Socket :: socket(), Length :: non_neg_integer(), Timeout :: non_neg_integer() | 'infinity'
) -> {'ok', any()} | {'error', any()}.
recv(Socket, Length, Timeout) when is_port(Socket) ->
    gen_tcp:recv(Socket, Length, Timeout);
recv(Socket, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout).

-spec controlling_process(Socket :: socket(), NewOwner :: pid()) -> 'ok' | {'error', any()}.
controlling_process(Socket, NewOwner) when is_port(Socket) ->
    gen_tcp:controlling_process(Socket, NewOwner);
controlling_process(Socket, NewOwner) ->
    ssl:controlling_process(Socket, NewOwner).

-spec peername(Socket :: socket()) ->
    {ok, {inet:ip_address(), non_neg_integer()}} | {'error', any()}.
peername(Socket) when is_port(Socket) ->
    inet:peername(Socket);
peername(Socket) ->
    ssl:peername(Socket).

-spec close(Socket :: socket()) -> 'ok'.
close(Socket) when is_port(Socket) ->
    gen_tcp:close(Socket);
close(Socket) ->
    ssl:close(Socket).

-spec shutdown(Socket :: socket(), How :: 'read' | 'write' | 'read_write') ->
    'ok' | {'error', any()}.
shutdown(Socket, How) when is_port(Socket) ->
    gen_tcp:shutdown(Socket, How);
shutdown(Socket, How) ->
    ssl:shutdown(Socket, How).

-spec active_once(Socket :: socket()) -> 'ok' | {'error', any()}.
active_once(Socket) when is_port(Socket) ->
    inet:setopts(Socket, [{active, once}]);
active_once(Socket) ->
    ssl:setopts(Socket, [{active, once}]).

-spec setopts(Socket :: socket(), Options :: list()) -> 'ok' | {'error', any()}.
setopts(Socket, Options) when is_port(Socket) ->
    inet:setopts(Socket, Options);
setopts(Socket, Options) ->
    ssl:setopts(Socket, Options).

-spec get_proto(Socket :: any()) -> 'tcp' | 'ssl'.
get_proto(Socket) when is_port(Socket) ->
    tcp;
get_proto(_Socket) ->
    ssl.

%% @doc {inet_async,...} will be sent to current process when a client connects
-spec begin_inet_async(Socket :: socket()) -> any().
begin_inet_async(Socket) when is_port(Socket) ->
    prim_inet:async_accept(Socket, -1);
begin_inet_async(Socket) ->
    Port = extract_port_from_socket(Socket),
    begin_inet_async(Port).

%% @doc handle the {inet_async,...} message
-spec handle_inet_async(Message :: {'inet_async', socket(), any(), {'ok', socket()}}) ->
    {'ok', socket()}.
handle_inet_async({inet_async, ListenSocket, _, {ok, ClientSocket}}) ->
    handle_inet_async(ListenSocket, ClientSocket, []).

-spec handle_inet_async(ListenSocket :: socket(), ClientSocket :: socket()) -> {'ok', socket()}.
handle_inet_async(ListenObject, ClientSocket) ->
    handle_inet_async(ListenObject, ClientSocket, []).

-spec handle_inet_async(ListenSocket :: socket(), ClientSocket :: socket(), Options :: list()) ->
    {'ok', socket()}.
handle_inet_async(ListenObject, ClientSocket, Options) ->
    ListenSocket = extract_port_from_socket(ListenObject),
    case set_sockopt(ListenSocket, ClientSocket) of
        ok -> ok;
        Error -> erlang:error(set_sockopt, Error)
    end,
    %% Signal the network driver that we are ready to accept another connection
    begin_inet_async(ListenSocket),
    %% If the listening socket is SSL then negotiate the client socket
    case is_port(ListenObject) of
        true ->
            {ok, ClientSocket};
        false ->
            {ok, UpgradedClientSocket} = to_ssl_server(ClientSocket, Options),
            {ok, UpgradedClientSocket}
    end.

%% @doc Upgrade a TCP connection to SSL
-spec to_ssl_server(Socket :: socket()) -> {'ok', ssl:sslsocket()} | {'error', any()}.
to_ssl_server(Socket) ->
    to_ssl_server(Socket, []).

-spec to_ssl_server(Socket :: socket(), Options :: list()) ->
    {'ok', ssl:sslsocket()} | {'error', any()}.
to_ssl_server(Socket, Options) ->
    to_ssl_server(Socket, Options, infinity).

-spec to_ssl_server(
    Socket :: socket(), Options :: list(), Timeout :: non_neg_integer() | 'infinity'
) -> {'ok', ssl:sslsocket()} | {'error', any()}.
to_ssl_server(Socket, Options, Timeout) when is_port(Socket) ->
    ssl:handshake(Socket, ssl_listen_options(Options), Timeout);
to_ssl_server(_Socket, _Options, _Timeout) ->
    {error, already_ssl}.

-spec to_ssl_client(Socket :: socket()) -> {'ok', ssl:sslsocket()} | {'error', 'already_ssl'}.
to_ssl_client(Socket) ->
    to_ssl_client(Socket, []).

-spec to_ssl_client(Socket :: socket(), Options :: list()) ->
    {'ok', ssl:sslsocket()} | {'error', 'already_ssl'}.
to_ssl_client(Socket, Options) ->
    to_ssl_client(Socket, Options, infinity).

-spec to_ssl_client(
    Socket :: socket(), Options :: list(), Timeout :: non_neg_integer() | 'infinity'
) -> {'ok', ssl:sslsocket()} | {'error', 'already_ssl'}.
to_ssl_client(Socket, Options, Timeout) when is_port(Socket) ->
    ssl:connect(Socket, ssl_connect_options(Options), Timeout);
to_ssl_client(_Socket, _Options, _Timeout) ->
    {error, already_ssl}.

-spec type(Socket :: socket()) -> protocol().
type(Socket) when is_port(Socket) ->
    tcp;
type(_Socket) ->
    ssl.

%%%-----------------------------------------------------------------
%%% Internal functions (OS_Mon configuration)
%%%-----------------------------------------------------------------

tcp_listen_options([Format | Options]) when Format =:= list; Format =:= binary ->
    tcp_listen_options(Options, Format);
tcp_listen_options(Options) ->
    tcp_listen_options(Options, list).
tcp_listen_options(Options, Format) ->
    parse_address([Format | proplist_merge(Options, ?TCP_LISTEN_OPTIONS)]).

ssl_listen_options([Format | Options]) when Format =:= list; Format =:= binary ->
    ssl_listen_options(Options, Format);
ssl_listen_options(Options) ->
    ssl_listen_options(Options, list).
ssl_listen_options(Options, Format) ->
    parse_address([Format | proplist_merge(Options, ?SSL_LISTEN_OPTIONS)]).

tcp_connect_options([Format | Options]) when Format =:= list; Format =:= binary ->
    tcp_connect_options(Options, Format);
tcp_connect_options(Options) ->
    tcp_connect_options(Options, list).
tcp_connect_options(Options, Format) ->
    parse_address([Format | proplist_merge(Options, ?TCP_CONNECT_OPTIONS)]).

ssl_connect_options([Format | Options]) when Format =:= list; Format =:= binary ->
    ssl_connect_options(Options, Format);
ssl_connect_options(Options) ->
    ssl_connect_options(Options, list).
ssl_connect_options(Options, Format) ->
    parse_address([Format | proplist_merge(Options, ?SSL_CONNECT_OPTIONS)]).

proplist_merge(PrimaryList, DefaultList) ->
    {PrimaryTuples, PrimaryOther} = lists:partition(fun(X) -> is_tuple(X) end, PrimaryList),
    {DefaultTuples, DefaultOther} = lists:partition(fun(X) -> is_tuple(X) end, DefaultList),
    MergedTuples = lists:ukeymerge(
        1,
        lists:keysort(1, PrimaryTuples),
        lists:keysort(1, DefaultTuples)
    ),
    MergedOther = lists:umerge(lists:sort(PrimaryOther), lists:sort(DefaultOther)),
    MergedTuples ++ MergedOther.

parse_address(Options) ->
    case proplists:get_value(ip, Options) of
        X when is_tuple(X) ->
            Options;
        X when is_list(X) ->
            case inet_parse:address(X) of
                {error, _} = Error ->
                    erlang:error(Error);
                {ok, IP} ->
                    proplists:delete(ip, Options) ++ [{ip, IP}]
            end;
        _ ->
            Options
    end.

-spec extract_port_from_socket(Socket :: socket()) -> port().
extract_port_from_socket({sslsocket, _, {SSLPort, _}}) ->
    SSLPort;
extract_port_from_socket(Socket) ->
    Socket.

-spec set_sockopt(ListSock :: port(), CliSocket :: port()) -> 'ok' | any().
set_sockopt(ListenObject, ClientSocket) ->
    ListenSocket = extract_port_from_socket(ListenObject),
    true = inet_db:register_socket(ClientSocket, inet_tcp),
    case prim_inet:getopts(ListenSocket, [active, nodelay, keepalive, delay_send, priority, tos]) of
        {ok, Opts} ->
            case prim_inet:setopts(ClientSocket, Opts) of
                ok ->
                    ok;
                Error ->
                    smtp_socket:close(ClientSocket),
                    Error
            end;
        Error ->
            smtp_socket:close(ClientSocket),
            Error
    end.

-ifdef(TEST).
-define(TEST_PORT, 7586).

connect_test_() ->
    [
        {"listen and connect via tcp", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 1,
            Ref = make_ref(),
            spawn(fun() ->
                {ok, ListenSocket} = listen(tcp, Port),
                ?assert(is_port(ListenSocket)),
                Self ! {Ref, listen},
                {ok, ServerSocket} = accept(ListenSocket),
                controlling_process(ServerSocket, Self),
                Self ! {Ref, ListenSocket}
            end),
            receive
                {Ref, listen} -> ok
            end,
            {ok, ClientSocket} = connect(tcp, "localhost", Port),
            receive
                {Ref, ListenSocket} when is_port(ListenSocket) -> ok
            end,
            ?assert(is_port(ClientSocket)),
            close(ListenSocket)
        end},
        {"listen and connect via ssl", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 2,
            Ref = make_ref(),
            application:ensure_all_started(gen_smtp),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/fixtures/mx1.example.com-server.crt"}
                ]),
                ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
                Self ! {Ref, listen},
                {ok, ServerSocket} = accept(ListenSocket),
                controlling_process(ServerSocket, Self),
                Self ! {Ref, ListenSocket}
            end),
            receive
                {Ref, listen} -> ok
            end,
            {ok, ClientSocket} = connect(ssl, "localhost", Port, []),
            receive
                {Ref, {sslsocket, _, _} = ListenSocket} -> ok
            end,
            ?assertMatch([sslsocket | _], tuple_to_list(ClientSocket)),
            close(ListenSocket)
        end}
    ].

evented_connections_test_() ->
    [
        {"current process receives connection to TCP listen sockets", fun() ->
            Port = ?TEST_PORT + 3,
            {ok, ListenSocket} = listen(tcp, Port),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(tcp, "localhost", Port) end),
            receive
                {inet_async, ListenSocket, _, {ok, ServerSocket}} -> ok
            end,
            {ok, NewServerSocket} = handle_inet_async(ListenSocket, ServerSocket),
            ?assert(is_port(ServerSocket)),
            %% only true for TCP
            ?assertEqual(ServerSocket, NewServerSocket),
            ?assert(is_port(ListenSocket)),
            % Stop the async
            spawn(fun() -> connect(tcp, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(NewServerSocket),
            close(ListenSocket)
        end},
        {"current process receives connection to SSL listen sockets", fun() ->
            Port = ?TEST_PORT + 4,
            application:ensure_all_started(gen_smtp),
            {ok, ListenSocket} = listen(ssl, Port, [
                {keyfile, "test/fixtures/mx1.example.com-server.key"},
                {certfile, "test/fixtures/mx1.example.com-server.crt"}
            ]),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                {inet_async, _ListenPort, _, {ok, ServerSocket}} -> ok
            end,
            {ok, NewServerSocket} = handle_inet_async(ListenSocket, ServerSocket, [
                {keyfile, "test/fixtures/mx1.example.com-server.key"},
                {certfile, "test/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assert(is_port(ServerSocket)),
            ?assertMatch([sslsocket | _], tuple_to_list(NewServerSocket)),
            ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
            %Stop the async
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(ListenSocket),
            close(NewServerSocket),
            ok
        end},
        %% TODO: figure out if the following passes because
        %% of an incomplete test case or if this really is
        %% a magical feature where a single listener
        %% can respond to either ssl or tcp connections.
        {"current TCP listener receives SSL connection", fun() ->
            Port = ?TEST_PORT + 5,
            application:ensure_all_started(gen_smtp),
            {ok, ListenSocket} = listen(tcp, Port),
            begin_inet_async(ListenSocket),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            ServerSocket =
                receive
                    {inet_async, _ListenPort, _, {ok, ServerSocket0}} -> ServerSocket0
                end,
            ?assertMatch({ok, ServerSocket}, handle_inet_async(ListenSocket, ServerSocket)),
            ?assert(is_port(ListenSocket)),
            ?assert(is_port(ServerSocket)),
            {ok, NewServerSocket} = to_ssl_server(ServerSocket, [
                {certfile, "test/fixtures/mx1.example.com-server.crt"},
                {keyfile, "test/fixtures/mx1.example.com-server.key"}
            ]),
            ?assertMatch([sslsocket | _], tuple_to_list(NewServerSocket)),
            % Stop the async
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            receive
                _Ignored -> ok
            end,
            close(ListenSocket),
            close(NewServerSocket)
        end}
    ].

accept_test_() ->
    [
        {"Accept via tcp", fun() ->
            Port = ?TEST_PORT + 6,
            {ok, ListenSocket} = listen(tcp, Port, tcp_listen_options([])),
            ?assert(is_port(ListenSocket)),
            spawn(fun() -> connect(ssl, "localhost", Port, tcp_connect_options([])) end),
            {ok, ServerSocket} = accept(ListenSocket),
            ?assert(is_port(ListenSocket)),
            close(ServerSocket),
            close(ListenSocket)
        end},
        {"Accept via ssl", fun() ->
            Port = ?TEST_PORT + 7,
            application:ensure_all_started(gen_smtp),
            {ok, ListenSocket} = listen(ssl, Port, [
                {keyfile, "test/fixtures/mx1.example.com-server.key"},
                {certfile, "test/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assertMatch([sslsocket | _], tuple_to_list(ListenSocket)),
            spawn(fun() -> connect(ssl, "localhost", Port) end),
            accept(ListenSocket),
            close(ListenSocket)
        end}
    ].

type_test_() ->
    [
        {"a tcp socket returns 'tcp'", fun() ->
            {ok, ListenSocket} = listen(tcp, ?TEST_PORT + 8),
            ?assertMatch(tcp, type(ListenSocket)),
            close(ListenSocket)
        end},
        {"an ssl socket returns 'ssl'", fun() ->
            application:ensure_all_started(gen_smtp),
            {ok, ListenSocket} = listen(ssl, ?TEST_PORT + 9, [
                {keyfile, "test/fixtures/mx1.example.com-server.key"},
                {certfile, "test/fixtures/mx1.example.com-server.crt"}
            ]),
            ?assertMatch(ssl, type(ListenSocket)),
            close(ListenSocket)
        end}
    ].

active_once_test_() ->
    [
        {"socket is set to active:once on tcp", fun() ->
            {ok, ListenSocket} = listen(tcp, ?TEST_PORT + 10, tcp_listen_options([])),
            ?assertEqual({ok, [{active, false}]}, inet:getopts(ListenSocket, [active])),
            active_once(ListenSocket),
            ?assertEqual({ok, [{active, once}]}, inet:getopts(ListenSocket, [active])),
            close(ListenSocket)
        end},
        {"socket is set to active:once on ssl", fun() ->
            {ok, ListenSocket} = listen(
                ssl,
                ?TEST_PORT + 11,
                ssl_listen_options([
                    {keyfile, "test/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/fixtures/mx1.example.com-server.crt"}
                ])
            ),
            ?assertEqual({ok, [{active, false}]}, ssl:getopts(ListenSocket, [active])),
            active_once(ListenSocket),
            ?assertEqual({ok, [{active, once}]}, ssl:getopts(ListenSocket, [active])),
            close(ListenSocket)
        end}
    ].

option_test_() ->
    [
        {"tcp_listen_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_LISTEN_OPTIONS]), lists:sort(tcp_listen_options([]))
            )
        end},
        {"tcp_connect_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_CONNECT_OPTIONS]), lists:sort(tcp_connect_options([]))
            )
        end},
        {"ssl_listen_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_LISTEN_OPTIONS]), lists:sort(ssl_listen_options([]))
            )
        end},
        {"ssl_connect_options has defaults", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_CONNECT_OPTIONS]), lists:sort(ssl_connect_options([]))
            )
        end},
        {"tcp_listen_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_LISTEN_OPTIONS]),
                lists:sort(tcp_listen_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?TCP_LISTEN_OPTIONS]),
                lists:sort(tcp_listen_options([binary, {active, false}]))
            )
        end},
        {"tcp_connect_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?TCP_CONNECT_OPTIONS]),
                lists:sort(tcp_connect_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?TCP_CONNECT_OPTIONS]),
                lists:sort(tcp_connect_options([binary, {active, false}]))
            )
        end},
        {"ssl_listen_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_LISTEN_OPTIONS]),
                lists:sort(ssl_listen_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?SSL_LISTEN_OPTIONS]),
                lists:sort(ssl_listen_options([binary, {active, false}]))
            )
        end},
        {"ssl_connect_options defaults to list type", fun() ->
            ?assertEqual(
                lists:sort([list | ?SSL_CONNECT_OPTIONS]),
                lists:sort(ssl_connect_options([{active, false}]))
            ),
            ?assertEqual(
                lists:sort([binary | ?SSL_CONNECT_OPTIONS]),
                lists:sort(ssl_connect_options([binary, {active, false}]))
            )
        end},
        {"tcp_listen_options merges provided proplist", fun() ->
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, true},
                        {backlog, 30},
                        {ip, {0, 0, 0, 0}},
                        {keepalive, true},
                        {packet, 2},
                        {reuseaddr, true}
                    ])
                ],
                tcp_listen_options([{active, true}, {packet, 2}])
            )
        end},
        {"tcp_connect_options merges provided proplist", fun() ->
            ?assertEqual(
                lists:sort([
                    list,
                    {active, true},
                    {packet, 2},
                    {ip, {0, 0, 0, 0}},
                    {port, 0}
                ]),
                lists:sort(tcp_connect_options([{active, true}, {packet, 2}]))
            )
        end},
        {"ssl_listen_options merges provided proplist", fun() ->
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, true},
                        {backlog, 30},
                        {certfile, "server.crt"},
                        {depth, 0},
                        {keepalive, true},
                        {keyfile, "server.key"},
                        {packet, 2},
                        {reuse_sessions, false},
                        {reuseaddr, true}
                    ])
                ],
                ssl_listen_options([{active, true}, {packet, 2}])
            ),
            ?assertEqual(
                [
                    list
                    | lists:keysort(1, [
                        {active, false},
                        {backlog, 30},
                        {certfile, "../server.crt"},
                        {depth, 0},
                        {keepalive, true},
                        {keyfile, "../server.key"},
                        {packet, line},
                        {reuse_sessions, false},
                        {reuseaddr, true}
                    ])
                ],
                ssl_listen_options([{certfile, "../server.crt"}, {keyfile, "../server.key"}])
            )
        end},
        {"ssl_connect_options merges provided proplist", fun() ->
            ?assertEqual(
                lists:sort([
                    list,
                    {active, true},
                    {depth, 0},
                    {ip, {0, 0, 0, 0}},
                    {port, 0},
                    {packet, 2}
                ]),
                lists:sort(ssl_connect_options([{active, true}, {packet, 2}]))
            )
        end}
    ].

ssl_upgrade_test_() ->
    [
        {"TCP connection can be upgraded to ssl", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 12,
            application:ensure_all_started(gen_smtp),
            spawn(fun() ->
                {ok, ListenSocket} = listen(tcp, Port),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                {ok, NewServerSocket} = smtp_socket:to_ssl_server(
                    ServerSocket,
                    [
                        {keyfile, "test/fixtures/mx1.example.com-server.key"},
                        {certfile, "test/fixtures/mx1.example.com-server.crt"}
                    ]
                ),
                Self ! {sock, NewServerSocket}
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(tcp, "localhost", Port),
            ?assert(is_port(ClientSocket)),
            {ok, NewClientSocket} = to_ssl_client(ClientSocket),
            ?assertMatch([sslsocket | _], tuple_to_list(NewClientSocket)),
            receive
                {sock, NewServerSocket} -> ok
            end,
            ?assertMatch({sslsocket, _, _}, NewServerSocket),
            close(NewClientSocket),
            close(NewServerSocket)
        end},
        {"SSL server connection can't be upgraded again", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 13,
            application:ensure_all_started(gen_smtp),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/fixtures/mx1.example.com-server.crt"}
                ]),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                ?assertMatch({error, already_ssl}, to_ssl_server(ServerSocket)),
                close(ServerSocket)
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(ssl, "localhost", Port),
            close(ClientSocket)
        end},
        {"SSL client connection can't be upgraded again", fun() ->
            Self = self(),
            Port = ?TEST_PORT + 14,
            application:ensure_all_started(gen_smtp),
            spawn(fun() ->
                {ok, ListenSocket} = listen(ssl, Port, [
                    {keyfile, "test/fixtures/mx1.example.com-server.key"},
                    {certfile, "test/fixtures/mx1.example.com-server.crt"}
                ]),
                Self ! listening,
                {ok, ServerSocket} = accept(ListenSocket),
                Self ! {sock, ServerSocket}
            end),
            receive
                listening -> ok
            end,
            erlang:yield(),
            {ok, ClientSocket} = connect(ssl, "localhost", Port),
            receive
                {sock, ServerSocket} -> ok
            end,
            ?assertMatch({error, already_ssl}, to_ssl_client(ClientSocket)),
            close(ClientSocket),
            close(ServerSocket)
        end}
    ].
-endif.
