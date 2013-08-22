%% -------------------------------------------------------------------
%%
%% cuttlefish_generator: this is where the action is
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(cuttlefish_generator).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-endif.

-export([map/3, find_mapping/2]).

map(Translations, Mappings, Config) ->

    %% Config at this point is just what's in the .conf file.
    %% add_defaults/2 rolls the default values in from the schema
    DConfig = add_defaults(Config, Mappings),

    %% Everything in DConfig is of datatype "string", 
    %% transform_datatypes turns them into other erlang terms
    %% based on the schema
    Conf =  transform_datatypes(DConfig, Mappings),

    %% This fold handles 1:1 mappings, that have no cooresponding translations
    %% The accumlator is the app.config proplist that we start building from
    %% these 1:1 mappings, hence the return "DirectMappings". 
    %% It also builds a list of "TranslationsToDrop". It's basically saying that
    %% if a user didn't actually configure this setting in the .conf file and 
    %% there's no default in the schema, then there won't be enough information
    %% during the translation phase to succeed, so we'll earmark it to be skipped
    {DirectMappings, {TranslationsToMaybeDrop, TranslationsToKeep}} = lists:foldl(
        fun(MappingRecord, {ConfAcc, {MaybeDrop, Keep}}) ->
            Mapping = cuttlefish_mapping:mapping(MappingRecord),
            Default = cuttlefish_mapping:default(MappingRecord),
            Key = cuttlefish_mapping:key(MappingRecord),
            case {
                Default =/= undefined orelse proplists:is_defined(Key, Conf), 
                proplists:is_defined(Mapping, Translations)
                } of
                {true, false} -> 
                    Tokens = string:tokens(Mapping, "."),
                    NewValue = proplists:get_value(Key, Conf),
                    {set_value(Tokens, ConfAcc, NewValue), {MaybeDrop, [Mapping|Keep]}};
                {true, true} -> {ConfAcc, {MaybeDrop, [Mapping|Keep]}};
                _ -> {ConfAcc, {[Mapping|MaybeDrop], Keep}}
            end
        end, 
        {[], {[],[]}},
        Mappings),
    TranslationsToDrop = TranslationsToMaybeDrop -- TranslationsToKeep,
    %% The fold handles the translations. After we've build the DirecetMappings,
    %% we use that to seed this fold's accumulator. As we go through each translation
    %% we write that to the `app.config` that lives in the accumutator.
    lists:foldl(
        fun(TranslationRecord, Acc) ->
            Mapping = cuttlefish_translation:mapping(TranslationRecord), 
            Xlat = cuttlefish_translation:func(TranslationRecord),
            case lists:member(Mapping, TranslationsToDrop) of
                false ->
                    Tokens = string:tokens(Mapping, "."),
                    %% get Xlat arity
                    Arity = proplists:get_value(arity, erlang:fun_info(Xlat)),
                    NewValue = case Arity of 
                        1 ->
                            Xlat(Conf);
                        3 -> 
                            Xlat(Conf, Mappings, Translations);
                        Other -> 
                            lager:error("~p is not a valid arity for translation fun() ~s. Try 1 or 3.", [Other, Mapping]),
                            undefined
                    end,
                    set_value(Tokens, Acc, NewValue);
                _ ->
                    lager:debug("~p in Translations to drop...", [Mapping]),
                    Acc
            end
        end, 
        DirectMappings, 
        Translations). 

%for each token, is it special?
%
%if yes, special processing
%if no, recurse into this with the value from the proplist and tail of tokens
%
%unless the tail of tokens is []

%% This is the last token, so things ends with replacing the proplist value.
set_value([LastToken], Acc, NewValue) ->
    {_Type, Token, _X} = token_type(LastToken),
    cuttlefish_util:replace_proplist_value(Token, NewValue, Acc); 
%% This is the case of all but the last token.
%% recurse until you hit a leaf.
set_value([HeadToken|MoreTokens], PList, NewValue) ->
    {_Type, Token, _X} = token_type(HeadToken),
    OldValue = proplists:get_value(Token, PList, []),
    cuttlefish_util:replace_proplist_value(
        Token,
        set_value(MoreTokens, OldValue, NewValue),
        PList).

%% TODO: Why is this function still here?
%% It's an important reminder that '$name' tokens aren't what you'd call "done"
%% They currently work as a place holder and it's up to the schema to do more 
%% robust handling. It might be that that's enough, but until we're sure.
%% never forget token_type/1
token_type(Token) ->
    case string:tokens(Token, "$") of
        [Token] -> { normal, list_to_atom(Token), none};
        [X] -> {named, list_to_atom(X), none}
    end.

add_defaults(Conf, Mappings) ->

    FuzzyKeyDefs = lists:filter(
        fun(Key) -> lists:member($$, Key) end, 
        [ cuttlefish_mapping:key(M) || M <- Mappings]
    ),

    %% Find all fuzzy matches in Conf, 
    %% get all their {Prefix, Var}s
    %% for each Prefix, 

    FuzzyKeys = lists:foldl(
        fun({Key, _}, FuzzyMatches) ->
            Fuzz = lists:filter(
                fun(KeyDef) -> 
                    cuttlefish_util:variable_key_match(Key, KeyDef)
                end, 
                FuzzyKeyDefs), 
            case length(Fuzz) of
                0 -> FuzzyMatches;
                _ -> [{hd(Fuzz), Key}|FuzzyMatches]
            end
        end, 
        [], 
        Conf), 

    FuzzVal = [ {K, proplists:get_all_values(K, FuzzyKeys)} || K <- proplists:get_keys(FuzzyKeys)],

    Names = [ begin 
        C = [ {L, 0}  || L <- List ],
        {K, cuttlefish_util:variables_for_mapping(K, C)}
    end || {K, List} <- FuzzVal],

    %% Names need organizing by prefix now
    %% Names: [{"n.$name.x",[{"$name","ak"},{"$name","bk"}]}]

    Prefixes1 = lists:foldl(
        fun({KeyDef, NameList}, Acc) -> 
            {Prefix, _, _} = cuttlefish_util:split_variable(KeyDef), 
            [{Prefix, NameList}|Acc]
        end, 
        [], 
        Names),
    PrefixesWithoutDefaults = [
        {Key, [ Y || {_, Y} <- lists:flatten(proplists:get_all_values(Key, Prefixes1))]}
    || Key <- proplists:get_keys(Prefixes1)],

    %% PrefixesWithoutDefaults
    %% [{"n",["ck","ak","bk"]}]

    %% Go through the FuzzyKeyDefs again.
    %% make sure that each one starts with a Prefix. 
    %% if not, add include_default to prefixes

    DefaultsNeeded = lists:filter(
        fun(FKD) -> 
            lists:all(
                fun({P, _List}) -> 
                    string:str(FKD, P) =/= 1 
                end, 
                PrefixesWithoutDefaults) 
        end, 
        FuzzyKeyDefs), 

    Prefixes = lists:foldl(
        fun(Needed, Acc) ->
            M = find_mapping(Needed, Mappings),
            DefaultVar = cuttlefish_mapping:include_default(M),

            case DefaultVar of
                undefined ->
                    Acc;
                _ ->
                    {Prefix, _Var, _} = cuttlefish_util:split_variable(Needed), 
                    DefaultVar = cuttlefish_mapping:include_default(M),
                    [{Prefix, [DefaultVar]}|Acc] 
            end
            
        end, 
        PrefixesWithoutDefaults, 
        DefaultsNeeded), 
    io:format("PrefixesWithoutDefaults: ~p~n", [PrefixesWithoutDefaults]),
    io:format("DefaultsNeeded: ~p~n", [DefaultsNeeded]),
    io:format("Prefixes: ~p~n", [Prefixes]),

    lists:foldl(
        fun(MappingRecord, Acc) ->
            Default = cuttlefish_mapping:default(MappingRecord),
            KeyDef = cuttlefish_mapping:key(MappingRecord),

            IsFuzzyMatch = lists:member(KeyDef, FuzzyKeyDefs),

            IsStrictMatch = lists:any(
                fun({K, _V}) ->
                    K =:= KeyDef
                end, 
                Conf),

            %% No, then plug in the default
            case {IsStrictMatch, IsFuzzyMatch} of
                %% Strict match means we have the setting already
                {true, false} -> Acc;
                %% If IsStrictMatch =:= false, IsFuzzyMatch =:= true, we've got a setting, but 
                %% it's part of a complex data structure.
                {false, true} ->
                    lists:foldl(
                        fun({Prefix, List}, SubAcc) -> 
                            case string:str(KeyDef, Prefix) =:= 1 of
                                true ->
                                    ToAdd = [ begin
                                        io:format("KeyDef: ~p, Key:~p~n", [KeyDef, K]),
                                        KeyToAdd = cuttlefish_util:variable_key_replace(KeyDef, K),
                                        case proplists:is_defined(KeyToAdd, Acc) of
                                            true ->
                                                no;
                                            _ ->
                                                {KeyToAdd, Default}
                                        end 
                                    end || K <- List],
                                    ToAdd2 = lists:filter(fun(X) -> X =/= no end, ToAdd), 
                                    SubAcc ++ ToAdd2;
                                _ -> SubAcc
                            end
                        end, 
                        Acc, 
                        Prefixes);
                %% If Match =:= FuzzyMatch =:= false, use the default, key not set in .conf
                {false, false} -> [{KeyDef, Default}|Acc];
                %% If Match =:= true, do nothing, the value is set in the .conf file
                _ -> lager:error("Both fuzzy and strict match! should not happen")
            end 
        end, 
        Conf, 
        lists:filter(fun(MappingRecord) -> cuttlefish_mapping:default(MappingRecord) =/= undefined end, Mappings)).

transform_datatypes(Conf, Mappings) ->
    [ begin
        %% Look up mapping from schema
        MappingRecord = find_mapping(Key, Mappings),
        DT = cuttlefish_mapping:datatype(MappingRecord),
        {Key, cuttlefish_datatypes:from_string(Value, DT)}
    end || {Key, Value} <- Conf].

%% Ok, this is tricky
%% There are three scenarios we have to deal with:
%% 1. The mapping is there! -> return mapping
%% 2. The mapping is not there -> error
%% 3. The mapping is there, but the key in the schema contains a $.
%%      (fuzzy match)
find_mapping(Key, Mappings) ->
    {HardMappings, FuzzyMappings} =  lists:foldl(
        fun(Mapping, {HM, FM}) ->
            K = cuttlefish_mapping:key(Mapping), 
            case {Key =:= K, cuttlefish_util:variable_key_match(Key, K)} of
                {true, _} -> {[Mapping|HM], FM};
                {_, true} -> {HM, [Mapping|FM]};
                _ -> {HM, FM}
            end
        end,
        {[], []},
        Mappings),

    case {length(HardMappings), length(FuzzyMappings)} of
        {1, _} -> hd(HardMappings);
        {0, 1} -> hd(FuzzyMappings);
        {0, 0} -> {error, lists:flatten(io_lib:format("~s not_found", [Key]))};
        {X, Y} -> {error, io_lib:format("~p hard mappings and ~p fuzzy mappings found for ~s", [X, Y, Key])}
    end.

-ifdef(TEST).

add_defaults_test() ->
    %%lager:start(),
    Conf = [
        %%{"a.b.c", "override"}, %% Specifically left out. Uncomment line to break test,
        {"a.c.d", "override"},
        {"no.match", "unchanged"},
        %%{"m.rk.x", "defined"}, %% since this is undefined no defaults should be created for "m",
        
        %% two matches on a name "ak" and "bk"
        {"n.ak.x", "set_n_name_x"},
        {"n.bk.x", "set_n_name_x2"},
        {"n.ck.y", "set_n_name_y3"}
          
    ],

    Mappings = [
        %% First mapping, direct, not in .conf, will be default
        cuttlefish_mapping:parse({mapping, "a.b.c", "b.c", [
                {default, "q"}
            ]}),
        %% default is "l", but since "a.c.d" is in Conf, it will be "override"
        cuttlefish_mapping:parse({mapping, "a.c.d", "c.d", [
                {default, "l"}
            ]}),
        cuttlefish_mapping:parse({mapping, "m.$name.x", "some.proplist", [
                {default, "m_name_x"}
            ]}),
        cuttlefish_mapping:parse({mapping, "n.$name.x", "some.proplist", [
            {default, "n_name_x"}
        ]}),
        cuttlefish_mapping:parse({mapping, "n.$name.y", "some.proplist", [
            {default, "n_name_y"}
        ]})



    ],

    DConf = add_defaults(Conf, Mappings),

    io:format("DConf: ~p~n", [DConf]),


    ?assertEqual(9, length(DConf)),
    ?assertEqual("q", proplists:get_value("a.b.c", DConf)),
    ?assertNotEqual("l", proplists:get_value("a.c.d", DConf)),
    ?assertEqual("override", proplists:get_value("a.c.d", DConf)),
    ?assertEqual("unchanged", proplists:get_value("no.match", DConf)),

    ?assertEqual("set_n_name_x", proplists:get_value("n.ak.x", DConf)),
    ?assertEqual("set_n_name_x2", proplists:get_value("n.bk.x", DConf)),
    ?assertEqual("n_name_x", proplists:get_value("n.ck.x", DConf)),

    ?assertEqual("n_name_y", proplists:get_value("n.ak.y", DConf)),
    ?assertEqual("n_name_y", proplists:get_value("n.bk.y", DConf)),
    ?assertEqual("set_n_name_y3", proplists:get_value("n.ck.y", DConf)),

    ok.

map_test() ->
    lager:start(),
    {Translations, Schema} = cuttlefish_schema:file("../test/riak.schema"),
    Conf = conf_parse:file("../test/riak.conf"),
    NewConfig = map(Translations, Schema, Conf),
    io:format("~p~n", [proplists:get_value(riak_core, NewConfig)]),

    NewRingSize = proplists:get_value(ring_creation_size, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual(32, NewRingSize),

    NewAAE = proplists:get_value(anti_entropy, proplists:get_value(riak_kv, NewConfig)), 
    ?assertEqual({on,[debug]}, NewAAE),

    NewSASL = proplists:get_value(sasl_error_logger, proplists:get_value(sasl, NewConfig)), 
    ?assertEqual(false, NewSASL),

    NewHTTP = proplists:get_value(http, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual([{"127.0.0.1", 8098}, {"10.0.0.1", 80}], NewHTTP),

    NewPB = proplists:get_value(pb, proplists:get_value(riak_api, NewConfig)), 
    ?assertEqual([{"127.0.0.1", 8087}], NewPB),

    NewHTTPS = proplists:get_value(https, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual(undefined, NewHTTPS),
    ok.

find_mapping_test() ->
    Mappings = [
        cuttlefish_mapping:parse({mapping, "key.with.fixed.name", "", [{ default, 0}]}),
        cuttlefish_mapping:parse({mapping, "key.with.$variable.name", "",  [{ default, 1}]})
    ],

    ?assertEqual(
        "key.with.fixed.name",
        cuttlefish_mapping:key(find_mapping("key.with.fixed.name", Mappings))
        ),

    ?assertEqual(
        0,
        cuttlefish_mapping:default(find_mapping("key.with.fixed.name", Mappings))
        ),

    ?assertEqual(
        "key.with.$variable.name",
        cuttlefish_mapping:key(find_mapping("key.with.A.name", Mappings))
        ),

    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.A.name", Mappings))
        ),

    ?assertEqual(
        "key.with.$variable.name",
        cuttlefish_mapping:key(find_mapping("key.with.B.name", Mappings))
        ),

    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.B.name", Mappings))
        ),

    ?assertEqual(
        "key.with.$variable.name",
        cuttlefish_mapping:key(find_mapping("key.with.C.name", Mappings))
        ),

    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.C.name", Mappings))
        ),

    ?assertEqual(
        "key.with.$variable.name",
        cuttlefish_mapping:key(find_mapping("key.with.D.name", Mappings))
        ),

    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.D.name", Mappings))
        ),

    ?assertEqual(
        "key.with.$variable.name",
        cuttlefish_mapping:key(find_mapping("key.with.E.name", Mappings))
        ),

    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.E.name", Mappings))
        ),

    %% Test variable name with dot
    ?assertEqual(
        {error, "key.with.E.F.name not_found"},
        find_mapping("key.with.E.F.name", Mappings)
        ),
    %% Test variable name with escaped dot
    ?assertEqual(
        1,
        cuttlefish_mapping:default(find_mapping("key.with.E\\.F.name", Mappings))
        ),

    ok.
-endif.
