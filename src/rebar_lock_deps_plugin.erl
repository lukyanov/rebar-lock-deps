%%% vim: set ts=4 sts=4 sw=4 et:

%% @author Seth Falcon
%% @copyright 2011 Seth Falcon
%% @doc lock-deps: Generate Locked Dependencies for Rebar
%%
%% The lock-deps command generates an alternate rebar.config file that
%% lists every dependency of a project and locks them at the git
%% revision found in the deps directory.
%%
%% Basic usage is:
%% ```
%% ./rebar lock-deps [ignore=...]
%% '''
%%
%% See the README.md file for details on how to use the script in your
%% build and notes on implementation.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%
-module(rebar_lock_deps_plugin).
-author("Seth Falcon <seth@userprimary.net>").
-author("Yuri Lukyanov <y.snaky@gmail.com>").
-export([
    'lock-deps'/2,
    'update-deps-local'/2,
    'list-deps-versions'/2
]).

'lock-deps'(Config, _AppFile) ->
    run_on_base_dir(Config, fun lock_deps/1).

'update-deps-local'(Config, _AppFile) ->
    run_on_base_dir(Config, fun update_deps_local/1).

'list-deps-versions'(Config, _AppFile) ->
    run_on_base_dir(Config, fun list_deps_versions/1).

run_on_base_dir(Config, Fun) ->
    case rebar_utils:processing_base_dir(Config) of
        true -> Fun(Config);
        false -> ok
    end.

lock_deps(Config) ->
    DepsDir = rebar_config:get(Config, deps_dir, "deps"),
    Ignores = string:tokens(rebar_config:get_global(Config, ignore, ""), ","),
    KeepFirst = string:tokens(rebar_config:get_global(Config, keep_first, ""), ","),
    DepDirs = deps_dirs(DepsDir),
    SubDirs = rebar_config:get(Config, sub_dirs, []),
    DepVersions = get_dep_versions(DepDirs),
    SortedDepVersions = sort_dep_versions(DepVersions, KeepFirst),
    AllDeps = collect_deps(["."|DepDirs++SubDirs]),
    NewDeps = get_locked_deps(SortedDepVersions, AllDeps, Ignores),
    NewConfig = rebar_config:get_global(Config,
        lock_config, "./rebar.config.lock"),
    write_rebar_lock("./rebar.config", NewConfig, NewDeps),
    io:format("wrote locked rebar config to: ~s~n", [NewConfig]),
    ok.

list_deps_versions(Config) ->
    DepsDir = rebar_config:get(Config, deps_dir, "deps"),
    Dirs = deps_dirs(DepsDir),
    DepVersions = get_dep_versions(Dirs),
    lists:foreach(fun({Dep, Ver}) ->
        io:format("~s ~s~n", [Ver, Dep])
    end, DepVersions),
    ok.

update_deps_local(Config) ->
    Deps = rebar_config:get(Config, deps, []),
    lists:foreach(fun({App, _, {_, _, Sha}}) ->
        AppDir = get_dep_dir(Config, App),
        case filelib:is_dir(AppDir) and is_list(Sha) of
            true -> update_dep(App, AppDir, Sha);
            false -> nop
        end
    end, Deps),
    ok.

%% Create rebar dependency specs for each dep in `DepVersions' locked
%% to the SHA1 in `DepVersions'. Spec details are taken from
%% `AllDeps'. Dependencies, listed by name (atom) in `Ignores' are not
%% locked and the spec found in `AllDeps' is passed through.
%%
get_locked_deps(DepVersions, AllDeps, Ignores) ->
    IgnoreNames = [ list_to_atom(I) || I <- Ignores ],
    NewDeps = [ begin
                    DepSpec = lists:keyfind(Name, 1, AllDeps),
                    lock_dep(DepSpec, Sha)
                end
                || {Name, Sha} <- DepVersions,
                   lists:member(Name, IgnoreNames) =:= false ],
    IgnoreDeps0 = [ lists:keyfind(Name, 1, AllDeps) || Name <- IgnoreNames ],
    IgnoreDeps = [ D || D <- IgnoreDeps0, D =/= false ],
    io:format("locked ~b deps~n", [length(NewDeps)]),
    io:format("ignored ~b deps~n", [length(IgnoreDeps)]),
    IgnoreDeps ++ NewDeps.

%% Write a locked down rebar.config file to `NewPath' based on the
%% rebar.config file found at `OrigPath'.
write_rebar_lock(OrigPath, NewPath, NewDeps) ->
    {ok, Orig} = file:consult(OrigPath),
    New = lists:keyreplace(deps, 1, Orig, {deps, NewDeps}),
    {ok, F} = file:open(NewPath, [write]),
    io:fwrite(F, "~s~n~n",
        ["%% THIS FILE IS GENERATED. EDIT WITH CAUTION %%~n"]),
    [ io:fwrite(F, "~p.~n", [Item]) || Item <- New ],
    io:fwrite(F, "~s", ["\n"]),
    file:close(F),
    ok.

lock_dep({Name, _Version, {Git, Url, _Tag}}, Sha) ->
    {Name, ".*", {Git, Url, Sha}};
lock_dep({Name, _Version, {Git, Url, _Tag}, ExtraOpts}, Sha) ->
    {Name, ".*", {Git, Url, Sha}, ExtraOpts}.


%% Find the git SHA1s of all the dependencies in `DepsDir' and return
%% as a list of {Name, Sha} tuples where Name is an atom and Sha is a
%% string.
get_dep_versions(Dirs) ->
    [ sha_for_project(D) || D <- Dirs ].

sort_dep_versions(Deps, KeepFirst) ->
    FirstNames = [ list_to_atom(N) || N <- KeepFirst ],
    {_, Rest} = lists:partition(fun({N, _}) ->
        lists:member(N, FirstNames)
    end, Deps),
    First = [lists:keyfind(N, 1, Deps) || N <- FirstNames],
    First ++ lists:sort(Rest).

sha_for_project(Dir) ->
    Cmd = ["cd ", Dir, "; git rev-parse HEAD"],
    Sha = re:replace(os:cmd(Cmd), "\n$", "", [{return, list}]),
    {list_to_atom(filename:basename(Dir)), Sha}.

deps_dirs(Dir) ->
    [ D || D <- filelib:wildcard(Dir ++ "/*"), filelib:is_dir(D) ].

collect_deps(Dirs) ->
    %% Note that there may be duplicate entries
    lists:foldl(fun(Dir, Acc) ->
                        extract_deps(Dir) ++ Acc
                end, [], Dirs).

extract_deps(Dir) ->
    ConfigFile = Dir ++ "/rebar.config",
    case filelib:is_file(ConfigFile) of
        true ->
            {ok, Config} = file:consult(Dir ++ "/rebar.config"),
            case lists:keyfind(deps, 1, Config) of
                {deps, Deps} -> Deps;
                false -> []
            end;
        false -> []
    end.

update_dep(App, AppDir, Sha) ->
    io:format("Updating locked ~s to ~s...~n", [App, Sha]),
    case git_checkout(AppDir, Sha) of
        {ok, _} -> ok;
        {error, _} ->
            git_fetch_checkout(AppDir, Sha)
    end.

get_dep_dir(Config, App) ->
    BaseDir = rebar_config:get_xconf(Config, base_dir, []),
    DepsDir = rebar_config:get(Config, deps_dir, "deps"),
    filename:join([BaseDir, DepsDir, App]).

git_checkout(AppDir, Sha) ->
    ShOpts = [return_on_error, {cd, AppDir}],
    rebar_utils:sh(git_checkout_cmd(Sha), ShOpts).

git_fetch_checkout(AppDir, Sha) ->
    ShOpts = [abort_on_error, {cd, AppDir}],
    rebar_utils:sh("git fetch origin", ShOpts),
    rebar_utils:sh(git_checkout_cmd(Sha), ShOpts).

git_checkout_cmd(Sha) ->
    lists:flatten(io_lib:format("git checkout -q ~s", [Sha])).
