%%% -*- erlang -*-
%%%
%%% Test demonstrating recv_timeout bug with connection pooling in Hackney 3.X
%%%
%%% Bug: When using connection pooling, the recv_timeout option passed in
%%% hackney:request/5 is ignored. The connection uses its original timeout
%%% from when it was created.
%%%
%%% Expected: Each request should respect its own recv_timeout option
%%% Actual: Pooled connections use the timeout they were created with

-module(hackney_recv_timeout_bug_test).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 8124).
-define(URL(Path), "http://127.0.0.1:" ++ integer_to_list(?PORT) ++ Path).

%%====================================================================
%% Test Setup
%%====================================================================

recv_timeout_bug_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"recv_timeout works without pooling", fun test_timeout_no_pool/0},
      {"recv_timeout BUG with pooling", fun test_timeout_with_pool/0}
     ]}.

setup() ->
    error_logger:tty(false),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(hackney),

    %% Start test server with delay endpoint
    Host = '_',
    Routes = [
        {"/delay/:seconds", delay_resource, []},
        {"/[...]", test_http_resource, []}
    ],
    Dispatch = cowboy_router:compile([{Host, Routes}]),
    {ok, _} = cowboy:start_clear(recv_timeout_test_server,
                                  [{port, ?PORT}],
                                  #{env => #{dispatch => Dispatch}}),
    ok.

teardown(_) ->
    cowboy:stop_listener(recv_timeout_test_server),
    application:stop(cowboy),
    application:stop(hackney),
    error_logger:tty(true),
    ok.

%%====================================================================
%% Tests
%%====================================================================

test_timeout_no_pool() ->
    %% Without pooling, recv_timeout should work correctly
    %% Request to /delay/5 with 100ms timeout should timeout
    Url = ?URL("/delay/5"),
    Opts = [
        {pool, false},           % Disable pooling
        {recv_timeout, 100}      % 100ms timeout
    ],

    Result = hackney:request(get, Url, [], <<>>, Opts),

    %% Should timeout
    ?assertEqual({error, timeout}, Result).

test_timeout_with_pool() ->
    %% BUG: With pooling, recv_timeout is ignored for pooled connections

    Url = ?URL("/delay/2"),

    %% First request: create connection with long timeout (10000ms)
    %% This should succeed
    {ok, 200, _, _} = hackney:request(get, ?URL("/get"), [], <<>>,
                                       [{pool, default}, {recv_timeout, 10000}]),

    %% Second request: try to use same pooled connection with 100ms timeout
    %% BUG: The 100ms timeout will be IGNORED - connection still has 10000ms timeout
    ShortTimeoutOpts = [{pool, default}, {recv_timeout, 100}],

    Result = hackney:request(get, Url, [], <<>>, ShortTimeoutOpts),

    %% EXPECTED: {error, timeout}
    %% ACTUAL: {ok, 200, _, _} - request succeeds because timeout is ignored

    %% This assertion will FAIL, demonstrating the bug
    case Result of
        {error, timeout} ->
            %% Expected behavior - timeout was respected
            ok;
        {ok, 200, _, _} ->
            %% BUG CONFIRMED: Request succeeded despite 100ms timeout on 2s delay
            error({bug_confirmed,
                   "recv_timeout option ignored with pooled connection",
                   "Expected {error, timeout} but got {ok, 200, ...}"})
    end.
