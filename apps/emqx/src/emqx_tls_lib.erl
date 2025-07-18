%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_tls_lib).

-feature(maybe_expr, enable).

-elvis([{elvis_style, atom_naming_convention, #{regex => "^([a-z][a-z0-9A-Z]*_?)*(_SUITE)?$"}}]).

%% version & cipher suites
-export([
    available_versions/1,
    integral_versions/2,
    default_ciphers/0,
    selected_ciphers/1,
    integral_ciphers/2,
    all_ciphers_set_cached/0
]).

%% SSL files
-export([
    ensure_ssl_files_in_mutable_certs_dir/2,
    ensure_ssl_files_in_mutable_certs_dir/3,
    ensure_ssl_files/2,
    ensure_ssl_files/3,
    drop_invalid_certs/1,
    ssl_file_conf_keypaths/0,
    pem_dir/1,
    is_managed_ssl_file/1
]).

-export([
    to_server_opts/2,
    to_client_opts/1,
    to_client_opts/2
]).

%% ssl:tls_version/0 is not exported.
-type tls_version() :: tlsv1 | 'tlsv1.1' | 'tlsv1.2' | 'tlsv1.3'.

-include("logger.hrl").

-define(IS_TRUE(Val), ((Val =:= true) orelse (Val =:= <<"true">>))).
-define(IS_FALSE(Val), ((Val =:= false) orelse (Val =:= <<"false">>))).

-define(SSL_FILE_OPT_PATHS, [
    %% common ssl options
    [<<"keyfile">>],
    [<<"certfile">>],
    [<<"cacertfile">>],
    %% OCSP
    [<<"ocsp">>, <<"issuer_pem">>],
    %% SSO
    [<<"sp_public_key">>],
    [<<"sp_private_key">>]
]).

-define(SSL_FILE_OPT_PATHS_A, [
    [keyfile],
    [certfile],
    [cacertfile],
    [ocsp, issuer_pem]
]).

-define(ALLOW_EMPTY_PEM, [[<<"cacertfile">>], [cacertfile]]).

%% non-empty string
-define(IS_STRING(L), (is_list(L) andalso L =/= [] andalso is_integer(hd(L)))).
%% non-empty list of strings
-define(IS_STRING_LIST(L), (is_list(L) andalso L =/= [] andalso ?IS_STRING(hd(L)))).

-define(SELECTED_CIPHERS, [
    "ECDHE-ECDSA-AES256-GCM-SHA384",
    "ECDHE-RSA-AES256-GCM-SHA384",
    "ECDHE-ECDSA-AES256-SHA384",
    "ECDHE-RSA-AES256-SHA384",
    "ECDH-ECDSA-AES256-GCM-SHA384",
    "ECDH-RSA-AES256-GCM-SHA384",
    "ECDH-ECDSA-AES256-SHA384",
    "ECDH-RSA-AES256-SHA384",
    "DHE-DSS-AES256-GCM-SHA384",
    "DHE-DSS-AES256-SHA256",
    "AES256-GCM-SHA384",
    "AES256-SHA256",
    "ECDHE-ECDSA-AES128-GCM-SHA256",
    "ECDHE-RSA-AES128-GCM-SHA256",
    "ECDHE-ECDSA-AES128-SHA256",
    "ECDHE-RSA-AES128-SHA256",
    "ECDH-ECDSA-AES128-GCM-SHA256",
    "ECDH-RSA-AES128-GCM-SHA256",
    "ECDH-ECDSA-AES128-SHA256",
    "ECDH-RSA-AES128-SHA256",
    "DHE-DSS-AES128-GCM-SHA256",
    "DHE-DSS-AES128-SHA256",
    "AES128-GCM-SHA256",
    "AES128-SHA256",
    "ECDHE-ECDSA-AES256-SHA",
    "ECDHE-RSA-AES256-SHA",
    "DHE-DSS-AES256-SHA",
    "ECDH-ECDSA-AES256-SHA",
    "ECDH-RSA-AES256-SHA",
    "ECDHE-ECDSA-AES128-SHA",
    "ECDHE-RSA-AES128-SHA",
    "DHE-DSS-AES128-SHA",
    "ECDH-ECDSA-AES128-SHA",
    "ECDH-RSA-AES128-SHA",

    %% psk
    "RSA-PSK-AES256-GCM-SHA384",
    "RSA-PSK-AES256-CBC-SHA384",
    "RSA-PSK-AES128-GCM-SHA256",
    "RSA-PSK-AES128-CBC-SHA256",
    "RSA-PSK-AES256-CBC-SHA",
    "RSA-PSK-AES128-CBC-SHA"
]).

%% @doc Validate a given list of desired tls versions.
%% raise an error exception if non of them are available.
%% The input list can be a string/binary of comma separated versions.
-spec integral_versions(tls | dtls, undefined | string() | binary() | [tls_version()]) ->
    [tls_version()].
integral_versions(Type, undefined) ->
    available_versions(Type);
integral_versions(Type, []) ->
    available_versions(Type);
integral_versions(Type, <<>>) ->
    available_versions(Type);
integral_versions(Type, Desired) when ?IS_STRING(Desired) ->
    integral_versions(Type, iolist_to_binary(Desired));
integral_versions(Type, Desired) when is_binary(Desired) ->
    integral_versions(Type, parse_versions(Desired));
integral_versions(Type, DesiredIn) ->
    Available = available_versions(Type),
    Desired = dedup(DesiredIn),
    case lists:filter(fun(V) -> lists:member(V, Available) end, Desired) of
        [] ->
            erlang:error(#{
                reason => no_available_tls_version,
                desired => Desired,
                available => Available
            });
        Filtered ->
            Filtered
    end.

%% @doc Return a set of all ciphers
all_ciphers_set_cached() ->
    case persistent_term:get(?FUNCTION_NAME, false) of
        false ->
            S = sets:from_list(all_ciphers()),
            persistent_term:put(?FUNCTION_NAME, S),
            S;
        Set ->
            Set
    end.

%% @hidden Return a list of all supported ciphers.
all_ciphers() ->
    all_ciphers(available_versions(all)).

%% @hidden Return a list of (openssl string format) cipher suites.
-spec all_ciphers([tls_version()]) -> [string()].
all_ciphers(['tlsv1.3']) ->
    %% When it's only tlsv1.3 wanted, use 'exclusive' here
    %% because 'all' returns legacy cipher suites too,
    %% which does not make sense since tlsv1.3 can not use
    %% legacy cipher suites.
    ssl:cipher_suites(exclusive, 'tlsv1.3', openssl);
all_ciphers(Versions) ->
    %% assert non-empty
    List = lists:append([ssl:cipher_suites(all, V, openssl) || V <- Versions]),

    %% Some PSK ciphers are both supported by OpenSSL and Erlang, but they need manual add here.
    %% Found by this cmd
    %% openssl ciphers -v|grep ^PSK| awk '{print $1}'| sed  "s/^/\"/;s/$/\"/" | tr "\n" ","
    %% Then remove the ciphers that aren't supported by Erlang
    PSK = [
        "PSK-AES256-GCM-SHA384",
        "PSK-AES128-GCM-SHA256",
        "PSK-AES256-CBC-SHA384",
        "PSK-AES256-CBC-SHA",
        "PSK-AES128-CBC-SHA256",
        "PSK-AES128-CBC-SHA"
    ],
    [_ | _] = dedup(List ++ PSK).

%% @doc All Pre-selected TLS ciphers.
default_ciphers() ->
    selected_ciphers(available_versions(all)).

%% @doc Pre-selected TLS ciphers for given versions..
selected_ciphers(Vsns) ->
    All = all_ciphers(Vsns),
    dedup(
        lists:filter(
            fun(Cipher) -> lists:member(Cipher, All) end,
            lists:flatmap(fun do_selected_ciphers/1, Vsns)
        )
    ).

do_selected_ciphers('tlsv1.3') ->
    case lists:member('tlsv1.3', proplists:get_value(available, ssl:versions())) of
        true -> ssl:cipher_suites(exclusive, 'tlsv1.3', openssl);
        false -> []
    end ++ do_selected_ciphers('tlsv1.2');
do_selected_ciphers(_) ->
    ?SELECTED_CIPHERS.

%% @doc Ensure version & cipher-suites integrity.
-spec integral_ciphers([tls_version()], binary() | string() | [string()]) -> [string()].
integral_ciphers(Versions, Ciphers) when Ciphers =:= [] orelse Ciphers =:= undefined ->
    %% not configured
    integral_ciphers(Versions, selected_ciphers(Versions));
integral_ciphers(Versions, Ciphers) when ?IS_STRING_LIST(Ciphers) ->
    %% ensure tlsv1.3 ciphers if none of them is found in Ciphers
    dedup(ensure_tls13_cipher(lists:member('tlsv1.3', Versions), Ciphers));
integral_ciphers(Versions, Ciphers) when is_binary(Ciphers) ->
    %% parse binary
    integral_ciphers(Versions, binary_to_list(Ciphers));
integral_ciphers(Versions, Ciphers) ->
    %% parse comma separated cipher suite names
    integral_ciphers(Versions, string:tokens(Ciphers, ", ")).

%% In case tlsv1.3 is present, ensure tlsv1.3 cipher is added if user
%% did not provide it from config --- which is a common mistake
ensure_tls13_cipher(true, Ciphers) ->
    Tls13Ciphers = selected_ciphers(['tlsv1.3']),
    case lists:any(fun(C) -> lists:member(C, Tls13Ciphers) end, Ciphers) of
        true -> Ciphers;
        false -> Tls13Ciphers ++ Ciphers
    end;
ensure_tls13_cipher(false, Ciphers) ->
    Ciphers.

%% @doc Returns the default available tls/dtls versions.
available_versions(Type) ->
    All = ssl:versions(),
    available_versions(Type, All).

available_versions(tls, All) ->
    proplists:get_value(available, All);
available_versions(dtls, All) ->
    proplists:get_value(available_dtls, All);
available_versions(all, All) ->
    available_versions(tls, All) ++ available_versions(dtls, All).

%% Deduplicate a list without re-ordering the elements.
dedup([]) ->
    [];
dedup(List0) ->
    List = lists:foldl(
        fun(L, Acc) ->
            case lists:member(L, Acc) of
                false -> [L | Acc];
                true -> Acc
            end
        end,
        [],
        List0
    ),
    lists:reverse(List).

%% parse comma separated tls version strings
parse_versions(Versions) ->
    do_parse_versions(split_by_comma(Versions), []).

do_parse_versions([], Acc) ->
    lists:reverse(Acc);
do_parse_versions([V | More], Acc) ->
    case parse_version(V) of
        unknown ->
            ?SLOG(warning, #{msg => "unknown_tls_version_discarded", version => V}),
            do_parse_versions(More, Acc);
        Parsed ->
            do_parse_versions(More, [Parsed | Acc])
    end.

parse_version(<<"dtlsv1.2">>) -> 'dtlsv1.2';
parse_version(<<"dtlsv1">>) -> dtlsv1;
parse_version(<<"tlsv", Vsn/binary>>) -> parse_version(Vsn);
parse_version(<<"v", Vsn/binary>>) -> parse_version(Vsn);
parse_version(<<"1.3">>) -> 'tlsv1.3';
parse_version(<<"1.2">>) -> 'tlsv1.2';
parse_version(<<"1.1">>) -> 'tlsv1.1';
parse_version(<<"1">>) -> 'tlsv1';
parse_version(_) -> unknown.

split_by_comma(Bin) ->
    [trim_space(I) || I <- binary:split(Bin, <<",">>, [global])].

%% trim spaces
trim_space(Bin) ->
    hd([I || I <- binary:split(Bin, <<" ">>), I =/= <<>>]).

%% @doc The input map is a HOCON decoded result of a struct defined as
%% emqx_schema:server_ssl_opts_schema. (NOTE: before schema-checked).
%% `keyfile', `certfile' and `cacertfile' can be either pem format key or certificates,
%% or file path.
%% When PEM format key or certificate is given, it tries to to save them in the given
%% sub-dir in emqx's data_dir, and replace saved file paths for SSL options.
-spec ensure_ssl_files_in_mutable_certs_dir(file:name_all(), undefined | map()) ->
    {ok, undefined | map()} | {error, map()}.
ensure_ssl_files_in_mutable_certs_dir(Dir, SSL) ->
    ensure_ssl_files_in_mutable_certs_dir(Dir, SSL, #{dry_run => false, required_keys => []}).

ensure_ssl_files_in_mutable_certs_dir(_Dir, undefined, _Opts) ->
    {ok, undefined};
ensure_ssl_files_in_mutable_certs_dir(_Dir, #{<<"enable">> := False} = SSL, _Opts) when
    ?IS_FALSE(False)
->
    {ok, SSL};
ensure_ssl_files_in_mutable_certs_dir(_Dir, #{enable := False} = SSL, _Opts) when
    ?IS_FALSE(False)
->
    {ok, SSL};
ensure_ssl_files_in_mutable_certs_dir(Dir, SSL, Opts) ->
    %% NOTE:
    %% Pass Raw Dir to keep the file name hash consistent with the previous version
    ensure_ssl_files(pem_dir(Dir), SSL, Opts#{raw_dir => Dir}).

ensure_ssl_files(Dir, SSL) ->
    ensure_ssl_files(Dir, SSL, #{dry_run => false, required_keys => [], raw_dir => Dir}).
ensure_ssl_files(Dir, SSL, Opts) ->
    RequiredKeys = maps:get(required_keys, Opts, []),
    case ensure_ssl_file_key(SSL, RequiredKeys) of
        ok ->
            KeyPaths = ?SSL_FILE_OPT_PATHS ++ ?SSL_FILE_OPT_PATHS_A,
            ensure_ssl_files_per_key(Dir, SSL, KeyPaths, Opts);
        {error, _} = Error ->
            Error
    end.

ensure_ssl_files_per_key(_Dir, SSL, [], _Opts) ->
    {ok, SSL};
ensure_ssl_files_per_key(Dir, SSL, [KeyPath | KeyPaths], Opts) ->
    case
        ensure_ssl_file(Dir, KeyPath, SSL, emqx_utils_maps:deep_get(KeyPath, SSL, undefined), Opts)
    of
        {ok, NewSSL} ->
            ensure_ssl_files_per_key(Dir, NewSSL, KeyPaths, Opts);
        {error, Reason} ->
            {error, Reason#{which_option => format_key_path(KeyPath)}}
    end.

ensure_ssl_file(_Dir, _KeyPath, SSL, undefined, _Opts) ->
    {ok, SSL};
ensure_ssl_file(_Dir, KeyPath, SSL, MaybePem, _Opts) when
    MaybePem =:= "" orelse MaybePem =:= <<"">>
->
    case lists:member(KeyPath, ?ALLOW_EMPTY_PEM) of
        true -> {ok, SSL};
        false -> {error, #{reason => pem_file_path_or_string_is_required}}
    end;
ensure_ssl_file(Dir, KeyPath, SSL, MaybePem, Opts) ->
    case is_valid_string(MaybePem) of
        true ->
            DryRun = maps:get(dry_run, Opts, false),
            RawDir = maps:get(raw_dir, Opts, Dir),
            %% RawDir for backward compatibility
            %% when RawDir is not given, it is the same as Dir
            %% to keep the file name hash consistent with the previous version (Depends on RawDir)
            do_ensure_ssl_file(Dir, RawDir, KeyPath, SSL, MaybePem, DryRun);
        false ->
            {error, #{reason => invalid_file_path_or_pem_string}}
    end.

do_ensure_ssl_file(Dir, RawDir, KeyPath, SSL, MaybePem, DryRun) ->
    Type = keypath_to_type(KeyPath),
    Password = maps:get(password, SSL, maps:get(<<"password">>, SSL, undefined)),
    case is_pem(MaybePem) of
        true ->
            maybe
                ok ?= try_validate_pem(MaybePem, Type, Password),
                {ok, Path} ?= save_pem_file(Dir, RawDir, KeyPath, MaybePem, DryRun),
                NewSSL = emqx_utils_maps:deep_put(KeyPath, SSL, Path),
                {ok, NewSSL}
            end;
        false ->
            case is_valid_pem_file(MaybePem, Type, Password) of
                true ->
                    {ok, SSL};
                {error, #{pem_check := enoent}} when DryRun ->
                    {ok, SSL};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

keypath_to_type(KeyPath) when is_list(KeyPath) ->
    case lists:map(fun emqx_utils_conv:bin/1, KeyPath) of
        [<<"certfile">>] ->
            certfile;
        [<<"keyfile">>] ->
            keyfile;
        _ ->
            undefined
    end.

is_valid_string(Empty) when Empty == <<>>; Empty == "" -> false;
is_valid_string(String) when is_list(String) ->
    io_lib:printable_unicode_list(String);
is_valid_string(Binary) when is_binary(Binary) ->
    case unicode:characters_to_list(Binary, utf8) of
        String when is_list(String) -> is_valid_string(String);
        _Otherwise -> false
    end.

-spec ssl_file_conf_keypaths() -> [_ConfKeypath :: [binary()]].
ssl_file_conf_keypaths() ->
    ?SSL_FILE_OPT_PATHS.

%% Check if it is a valid PEM formatted key.
is_pem(MaybePem) ->
    try
        public_key:pem_decode(MaybePem) =/= []
    catch
        _:_ -> false
    end.

-define(catching(BODY, ON_ERROR),
    try
        {ok, BODY}
    catch
        _:_ -> ON_ERROR
    end
).
-define(catching(BODY), ?catching(BODY, error)).
try_validate_pem(PEM, certfile, _Password) ->
    do_validate_certfile(PEM);
try_validate_pem(PEM, keyfile, Password) ->
    do_validate_keyfile(PEM, Password);
try_validate_pem(_PEM, _Type, _Password) ->
    ok.

do_validate_certfile(PEM) ->
    maybe
        {ok, [{'Certificate' = Type, DER, not_encrypted} | _]} ?=
            ?catching(public_key:pem_decode(PEM)),
        {ok, _} ?= ?catching(public_key:der_decode(Type, DER)),
        ok
    else
        _ -> {error, #{reason => failed_to_parse_certfile}}
    end.

do_validate_keyfile(PEM, Password) ->
    maybe
        {ok, [Entry]} ?= ?catching(public_key:pem_decode(PEM)),
        {ok, _} ?= der_decode_file(Entry, Password),
        ok
    else
        {error, Reason} -> {error, Reason};
        _ -> {error, #{reason => failed_to_parse_keyfile}}
    end.

der_decode_file({Type, DER, not_encrypted}, _Password) ->
    ?catching(public_key:der_decode(Type, DER));
der_decode_file({_EncType, _EncDER, _EncryptionData}, undefined) ->
    {error, #{reason => encryped_keyfile_missing_password}};
der_decode_file({_EncType, _EncDER, _EncryptionData} = EncryptedEntry, Password) ->
    ?catching(
        public_key:pem_entry_decode(EncryptedEntry, emqx_secret:unwrap(Password)),
        {error, #{reason => bad_password_or_invalid_keyfile}}
    ).
-undef(catching).

%% Write the pem file to the given dir.
%% To make it simple, the file is always overwritten.
%% Also a potentially half-written PEM file (e.g. due to power outage)
%% can be corrected with an overwrite.
save_pem_file(Dir, RawDir, KeyPath, PEM, DryRun) ->
    Path = pem_file_path(Dir, RawDir, KeyPath, PEM),
    case filelib:ensure_dir(Path) of
        ok when DryRun ->
            {ok, Path};
        ok ->
            case file:write_file(Path, PEM) of
                ok -> {ok, Path};
                {error, Reason} -> {error, #{failed_to_write_file => Reason, file_path => Path}}
            end;
        {error, Reason} ->
            {error, #{failed_to_create_dir_for => Path, reason => Reason}}
    end.

%% compute the filename for a PEM format key/certificate
%% the filename is prefixed by the option name without the 'file' part
%% and suffixed with the first 8 byets the PEM content's md5 checksum.
%% e.g. key-1234567890abcdef, cert-1234567890abcdef, and cacert-1234567890abcdef
is_managed_ssl_file(Filename) ->
    case string:split(filename:basename(Filename), "-") of
        [_Name, Suffix] -> is_hex_str(Suffix);
        _ -> false
    end.

pem_file_path(Dir, RawDir, KeyPath, PEM) ->
    % NOTE
    % Wee need to have the same filename on every cluster node.
    Segments = lists:map(fun ensure_bin/1, KeyPath),
    Filename0 = iolist_to_binary(lists:join(<<"_">>, Segments)),
    Filename1 = binary:replace(Filename0, <<"file">>, <<>>),
    Fingerprint = crypto:hash(md5, [RawDir, Filename1, PEM]),
    Suffix = binary:encode_hex(binary:part(Fingerprint, 0, 8)),
    Filename = <<Filename1/binary, "-", Suffix/binary>>,
    filename:join([Dir, Filename]).

pem_dir(Dir) ->
    filename:join([emqx:mutable_certs_dir(), Dir]).

is_hex_str(Str) ->
    try
        _ = binary:decode_hex(iolist_to_binary(Str)),
        true
    catch
        error:badarg -> false
    end.

%% @doc Returns 'true' when the file is a valid pem, otherwise {error, Reason}.
is_valid_pem_file(Path0, Type, Password) ->
    Path = resolve_cert_path_for_read(Path0),
    case is_valid_filename(Path) of
        true ->
            case file:read_file(Path) of
                {ok, PEM} ->
                    case is_pem(PEM) andalso try_validate_pem(PEM, Type, Password) of
                        ok ->
                            true;
                        {error, #{reason := Reason}} ->
                            {error, #{reason => Reason, file_path => Path}};
                        {error, Reason} ->
                            {error, #{reason => Reason, file_path => Path}};
                        false ->
                            {error, #{pem_check => not_pem, file_path => Path}}
                    end;
                {error, Reason} ->
                    {error, #{pem_check => Reason, file_path => Path}}
            end;
        false ->
            %% do not report path because the content can be huge
            {error, #{pem_check => not_pem, file_path => not_file_path}}
    end.

%% no controle chars 0-31
%% the input is always string for this function
is_valid_filename(Path) ->
    lists:all(fun(C) -> C >= 32 end, Path).

%% @doc Input and output are both HOCON-checked maps, with invalid SSL
%% file options dropped.
%% This is to give a feedback to the front-end or management API caller
%% so they are forced to upload a cert file, or use an existing file path.
-spec drop_invalid_certs(map()) -> map().
drop_invalid_certs(#{enable := False} = SSL) when ?IS_FALSE(False) ->
    lists:foldl(fun emqx_utils_maps:deep_remove/2, SSL, ?SSL_FILE_OPT_PATHS_A);
drop_invalid_certs(#{<<"enable">> := False} = SSL) when ?IS_FALSE(False) ->
    lists:foldl(fun emqx_utils_maps:deep_remove/2, SSL, ?SSL_FILE_OPT_PATHS);
drop_invalid_certs(#{enable := True} = SSL) when ?IS_TRUE(True) ->
    do_drop_invalid_certs(?SSL_FILE_OPT_PATHS_A, SSL);
drop_invalid_certs(#{<<"enable">> := True} = SSL) when ?IS_TRUE(True) ->
    do_drop_invalid_certs(?SSL_FILE_OPT_PATHS, SSL).

do_drop_invalid_certs([], SSL) ->
    SSL;
do_drop_invalid_certs([KeyPath | KeyPaths], SSL) ->
    Type = keypath_to_type(KeyPath),
    Password = maps:get(password, SSL, maps:get(<<"password">>, SSL, undefined)),
    case emqx_utils_maps:deep_get(KeyPath, SSL, undefined) of
        undefined ->
            do_drop_invalid_certs(KeyPaths, SSL);
        PemOrPath ->
            case is_pem(PemOrPath) orelse is_valid_pem_file(PemOrPath, Type, Password) of
                true ->
                    do_drop_invalid_certs(KeyPaths, SSL);
                {error, _} ->
                    do_drop_invalid_certs(KeyPaths, emqx_utils_maps:deep_remove(KeyPath, SSL))
            end
    end.

%% @doc Convert hocon-checked ssl server options (map()) to
%% proplist accepted by ssl library.
%% Every field defined in `emqx_schema:server_ssl_opts_schema/2` is
%% taken care of, except for:
%%  * `ocsp`: current machinery is tied to `emqx_listeners`, this
%%            is where OCSP setup is happening.
%% If you plan to make changes here, please take care to follow the
%% spec and avoid introducing options not recognizable by `ssl`.
-spec to_server_opts(tls | dtls, map()) -> [ssl:tls_server_option()].
to_server_opts(Type, Opts) ->
    Versions = integral_versions(Type, conf_get_opt(versions, Opts)),
    Ciphers = integral_ciphers(Versions, conf_get_opt(ciphers, Opts)),
    DefaultUserLookupFun =
        case Versions of
            ['tlsv1.3'] -> undefined;
            [_ | _] -> {fun emqx_tls_psk:lookup/3, undefined}
        end,
    TLSServerOpts = [
        {versions, Versions},
        {ciphers, Ciphers}
        | emqx_utils:flattermap(
            fun(Extractor) -> conf_extract_opt(Extractor, Opts) end,
            [
                {keyfile, fun conf_resolve_path_strict/2},
                {certfile, fun conf_resolve_path_strict/2},
                {cacertfile, fun conf_resolve_path_strict/2},
                {cacerts, fun conf_get_opt/2},
                {password, fun conf_get_password/2},
                {depth, fun conf_get_opt/2},
                {dhfile, fun conf_get_opt/2},
                {verify, fun conf_get_opt/2},
                {fail_if_no_peer_cert, fun conf_get_opt/2},
                {reuse_session, fun conf_get_opt/2, #{omit_if => true}},
                {secure_renegotiate, fun conf_get_opt/2, #{omit_if => true}},
                {honor_cipher_order, fun conf_get_opt/2},
                {client_renegotiation, fun conf_get_opt/2, #{omit_if => true}},
                {handshake_timeout, fun conf_get_opt/2},
                {user_lookup_fun, fun conf_get_opt/2, #{default => DefaultUserLookupFun}},
                {log_level, fun conf_get_opt/2},
                {hibernate_after, fun conf_get_opt/2},
                %% esockd-only
                {gc_after_handshake, fun conf_get_opt/2, #{omit_if => false}},
                {crl_check, conf_crl_check(Opts)},
                {crl_cache, conf_crl_cache(Opts)}
            ]
        )
    ],
    TLSAuthExt = lists:append(
        emqx_tls_lib_auth_ext:opt_partial_chain(Opts),
        emqx_tls_lib_auth_ext:opt_verify_fun(Opts)
    ),
    ensure_valid_options(TLSServerOpts ++ TLSAuthExt).

conf_crl_check(#{enable_crl_check := true}) ->
    %% `{crl_check, true}' doesn't work
    peer;
conf_crl_check(#{}) ->
    undefined.

conf_crl_cache(#{enable_crl_check := true}) ->
    HTTPTimeout = emqx_config:get([crl_cache, http_timeout], timer:seconds(15)),
    {emqx_ssl_crl_cache, {internal, [{http, HTTPTimeout}]}};
conf_crl_cache(#{}) ->
    undefined.

%% @doc Convert hocon-checked tls client options (map()) to
%% proplist accepted by ssl library.
-spec to_client_opts(map()) -> [ssl:tls_client_option()].
to_client_opts(Opts) ->
    to_client_opts(tls, Opts).

%% @doc Convert hocon-checked tls or dtls client options (map()) to
%% proplist accepted by ssl library.
%% Every field defined in `emqx_schema:server_ssl_opts_schema/2` is
%% taken care of, except for:
%%  * `dhfile`
%%  * `cacerts`
%%  * `log_level`
%%  * `hibernate_after`
%%  * `partial_chain`: mostly makes sense in server context.
%%  * `verify_peer_ext_key_usage`: mostly makes sense in server context.
-spec to_client_opts(tls | dtls, map()) -> [ssl:tls_client_option()].
to_client_opts(Type, Opts = #{enable := true}) ->
    Versions = integral_versions(Type, conf_get_opt(versions, Opts)),
    Ciphers = integral_ciphers(Versions, conf_get_opt(ciphers, Opts)),
    Verify = conf_get_opt(verify, Opts, verify_none),
    TLSClientOpts =
        [
            {versions, Versions},
            {ciphers, Ciphers},
            {verify, Verify}
            | emqx_utils:flattermap(
                fun(Extractor) -> conf_extract_opt(Extractor, Opts) end,
                [
                    {keyfile, fun conf_resolve_path_strict/2},
                    {certfile, fun conf_resolve_path_strict/2},
                    {cacertfile, fun conf_resolve_path_strict/2},
                    {password, fun conf_get_password/2},
                    {depth, fun conf_get_opt/2},
                    {verify, fun conf_get_opt/2},
                    {middlebox_comp_mode, fun conf_get_opt/2, #{omit_if => true}},
                    {server_name_indication, fun conf_get_sni/2},
                    {customize_hostname_check, customize_hostname_check(Verify)},
                    {reuse_sessions, fun conf_get_opt/2, #{omit_if => true}},
                    {secure_renegotiate, fun conf_get_opt/2, #{omit_if => true}}
                ]
            )
        ],
    ensure_valid_options(TLSClientOpts);
to_client_opts(_Type, #{}) ->
    [].

customize_hostname_check(verify_none) ->
    undefined;
customize_hostname_check(verify_peer) ->
    %% allow wildcard certificates
    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}].

conf_extract_opt({Name, Fun}, Opts) ->
    conf_extract_opt({Name, Fun, #{}}, Opts);
conf_extract_opt({Name, Fun, Extra}, Opts) when is_function(Fun, 2) ->
    V0 = Fun(Name, Opts),
    conf_extract_opt(Name, V0, Extra);
conf_extract_opt({Name, V0, Extra}, _Opts) ->
    conf_extract_opt(Name, V0, Extra).

conf_extract_opt(Name, V0, Extra) ->
    V1 = emqx_maybe:define(V0, maps:get(default, Extra, undefined)),
    case V1 of
        undefined -> [];
        "" -> [];
        V when map_get(omit_if, Extra) == V -> [];
        V -> {Name, V}
    end.

resolve_cert_path_for_read_strict(Path) ->
    case resolve_cert_path_for_read(Path) of
        undefined ->
            undefined;
        ResolvedPath ->
            case filelib:is_regular(ResolvedPath) of
                true ->
                    ResolvedPath;
                false ->
                    PathToLog = ensure_str(Path),
                    LogData =
                        case PathToLog =:= ResolvedPath of
                            true ->
                                #{path => PathToLog};
                            false ->
                                #{path => PathToLog, resolved_path => ResolvedPath}
                        end,
                    ?SLOG(error, LogData#{msg => "cert_file_not_found"}),
                    undefined
            end
    end.

resolve_cert_path_for_read(Path) ->
    emqx_schema:naive_env_interpolation(Path).

ensure_valid_options(Options) ->
    Versions = proplists:get_value(versions, Options),
    ensure_valid_options(Options, Versions, []).

ensure_valid_options([], _, Acc) ->
    lists:reverse(Acc);
ensure_valid_options([{K, V} | T], Versions, Acc) ->
    case tls_option_compatible_versions(K) of
        all ->
            ensure_valid_options(T, Versions, [{K, V} | Acc]);
        CompatibleVersions ->
            case Versions -- CompatibleVersions of
                %% No intersection.
                Versions ->
                    ?SLOG(warning, #{
                        msg => "drop_incompatible_tls_option", option => K, versions => Versions
                    }),
                    ensure_valid_options(T, Versions, Acc);
                _ ->
                    ensure_valid_options(T, Versions, [{K, V} | Acc])
            end
    end.

%% see otp/lib/ssl/src/ssl.erl, `assert_option_dependency/4`
tls_option_compatible_versions(beast_mitigation) ->
    [dtlsv1, 'tlsv1'];
tls_option_compatible_versions(padding_check) ->
    [dtlsv1, 'tlsv1'];
tls_option_compatible_versions(client_renegotiation) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(reuse_session) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(reuse_sessions) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(secure_renegotiate) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(next_protocol_advertised) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(client_preferred_next_protocols) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(psk_identity) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(srp_identity) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(user_lookup_fun) ->
    [dtlsv1, 'dtlsv1.2', 'tlsv1', 'tlsv1.1', 'tlsv1.2'];
tls_option_compatible_versions(early_data) ->
    ['tlsv1.3'];
tls_option_compatible_versions(certificate_authorities) ->
    ['tlsv1.3'];
tls_option_compatible_versions(cookie) ->
    ['tlsv1.3'];
tls_option_compatible_versions(key_update_at) ->
    ['tlsv1.3'];
tls_option_compatible_versions(anti_replay) ->
    ['tlsv1.3'];
tls_option_compatible_versions(session_tickets) ->
    ['tlsv1.3'];
tls_option_compatible_versions(supported_groups) ->
    ['tlsv1.3'];
tls_option_compatible_versions(use_ticket) ->
    ['tlsv1.3'];
tls_option_compatible_versions(_) ->
    all.

-spec conf_get_opt(atom(), map()) -> any() | undefined.
conf_get_opt(Key, Options) ->
    conf_get_opt(Key, Options, undefined).

-spec conf_get_opt(atom(), map(), Default :: any()) -> any().
conf_get_opt(Key, Options, Default) ->
    case maps:find(Key, Options) of
        {ok, Value} ->
            Value;
        _Otherwise ->
            maps:get(atom_to_binary(Key, utf8), Options, Default)
    end.

conf_resolve_path_strict(Key, Options) ->
    resolve_cert_path_for_read_strict(conf_get_opt(Key, Options)).

conf_get_password(Name, Opts) ->
    ensure_password(conf_get_opt(Name, Opts)).

conf_get_sni(Name, Opts) ->
    ensure_sni(conf_get_opt(Name, Opts)).

ensure_sni(disable) -> disable;
ensure_sni(undefined) -> undefined;
ensure_sni(L) when is_list(L) -> L;
ensure_sni(B) when is_binary(B) -> unicode:characters_to_list(B, utf8).

ensure_password(Password) ->
    case emqx_secret:unwrap(Password) of
        undefined ->
            undefined;
        S ->
            ensure_str(S)
    end.

ensure_str(undefined) -> undefined;
ensure_str(L) when is_list(L) -> L;
ensure_str(B) when is_binary(B) -> unicode:characters_to_list(B, utf8).

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

ensure_ssl_file_key(_SSL, []) ->
    ok;
ensure_ssl_file_key(SSL, RequiredKeyPaths) ->
    Filter = fun(KeyPath) ->
        case emqx_utils_maps:deep_find(KeyPath, SSL) of
            {not_found, _, _} -> true;
            _ -> false
        end
    end,
    case lists:filter(Filter, RequiredKeyPaths) of
        [] ->
            ok;
        MissingL ->
            {error, #{
                reason => ssl_file_option_not_found,
                missing_options => format_key_paths(MissingL)
            }}
    end.

format_key_paths(Paths) ->
    lists:map(fun format_key_path/1, Paths).

format_key_path(Path) ->
    iolist_to_binary(lists:join(".", [ensure_bin(S) || S <- Path])).
