%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn_mysql_tls_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("../../emqx_connector/include/emqx_connector.hrl").
-include_lib("emqx_auth/include/emqx_authn.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(MYSQL_HOST, "mysql-tls").

-define(PATH, [authentication]).
-define(ResourceID, <<"password_based:mysql">>).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_testcase(_, Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    Config.

init_per_suite(Config) ->
    case emqx_common_test_helpers:is_tcp_server_available(?MYSQL_HOST, ?MYSQL_DEFAULT_PORT) of
        true ->
            Apps = emqx_cth_suite:start([emqx, emqx_conf, emqx_auth, emqx_auth_mysql], #{
                work_dir => ?config(priv_dir, Config)
            }),
            [{apps, Apps} | Config];
        false ->
            {skip, no_mysql_tls}
    end.

end_per_suite(Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    ok = emqx_cth_suite:stop(?config(apps, Config)),
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_create(_Config) ->
    %% openssl s_client -tls1_2 -cipher ECDHE-RSA-AES256-GCM-SHA384 \
    %%   -connect authn-server:3306 -starttls mysql \
    %%   -cert client.crt -key client.key -CAfile ca.crt
    ?assertMatch(
        {ok, _},
        create_mysql_auth_with_ssl_opts(
            #{
                <<"server_name_indication">> => <<"authn-server">>,
                <<"verify">> => <<"verify_peer">>,
                <<"versions">> => [<<"tlsv1.2">>],
                <<"ciphers">> => [<<"ECDHE-RSA-AES256-GCM-SHA384">>]
            }
        )
    ).

t_create_invalid(_Config) ->
    %% invalid server_name
    ?assertMatch(
        {ok, _},
        create_mysql_auth_with_ssl_opts(
            #{
                <<"server_name_indication">> => <<"authn-server-unknown-host">>,
                <<"verify">> => <<"verify_peer">>
            }
        )
    ),
    emqx_authn_test_lib:delete_config(?ResourceID),
    %% incompatible versions
    ?assertMatch(
        {ok, _},
        create_mysql_auth_with_ssl_opts(
            #{
                <<"server_name_indication">> => <<"authn-server">>,
                <<"verify">> => <<"verify_peer">>,
                <<"versions">> => [<<"tlsv1.1">>]
            }
        )
    ),
    emqx_authn_test_lib:delete_config(?ResourceID),
    %% incompatible ciphers
    ?assertMatch(
        {ok, _},
        create_mysql_auth_with_ssl_opts(
            #{
                <<"server_name_indication">> => <<"authn-server">>,
                <<"verify">> => <<"verify_peer">>,
                <<"versions">> => [<<"tlsv1.2">>],
                <<"ciphers">> => [<<"ECDHE-ECDSA-AES128-GCM-SHA256">>]
            }
        )
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

create_mysql_auth_with_ssl_opts(SpecificSSLOpts) ->
    AuthConfig = raw_mysql_auth_config(SpecificSSLOpts),
    emqx:update_config(?PATH, {create_authenticator, ?GLOBAL, AuthConfig}).

raw_mysql_auth_config(SpecificSSLOpts) ->
    SSLOpts = maps:merge(
        emqx_authn_test_lib:client_ssl_cert_opts(),
        #{<<"enable">> => <<"true">>}
    ),
    #{
        <<"mechanism">> => <<"password_based">>,
        <<"password_hash_algorithm">> => #{
            <<"name">> => <<"plain">>,
            <<"salt_position">> => <<"suffix">>
        },
        <<"enable">> => <<"true">>,

        <<"backend">> => <<"mysql">>,
        <<"database">> => <<"mqtt">>,
        <<"username">> => <<"root">>,
        <<"password">> => <<"public">>,

        <<"query">> =>
            <<
                "SELECT password_hash, salt, is_superuser_str as is_superuser\n"
                "                      FROM users where username = ${username} LIMIT 1"
            >>,
        <<"server">> => mysql_server(),
        <<"ssl">> => maps:merge(SSLOpts, SpecificSSLOpts)
    }.

mysql_server() ->
    iolist_to_binary(io_lib:format("~s", [?MYSQL_HOST])).
