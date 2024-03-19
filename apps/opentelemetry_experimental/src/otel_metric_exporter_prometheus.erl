%%%------------------------------------------------------------------------
%% Copyright 2022, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc
%% @end
%%%-------------------------------------------------------------------------

-module(otel_metric_exporter_prometheus).
-behavior(otel_exporter).

-export([init/1,
         export/4,
         force_flush/0,
         shutdown/1]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry_api_experimental/include/otel_metrics.hrl").
-include("otel_view.hrl").
-include("otel_metrics.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_OPTS, #{add_scope_info => false,
                        add_target_info => false,
                        add_total_suffix => true,
                        order => undefined}).
-define(INFO_METRICS, #{<<"otel_scope">> => true, <<"target">> => true}).

-define(LF, 10).
-define(SP, 32).

init(Opts) ->
    {ok, maps:with(maps:keys(?DEFAULT_OPTS), maps:merge(?DEFAULT_OPTS, Opts))}.

export(metrics, Metrics, Resource, Opts) ->
    parse_metrics(Metrics, Resource, Opts).

force_flush() ->
    ok.

shutdown(_) ->
    ok.

parse_metrics(Metrics, Resource, #{add_target_info:=AddTargetInfo,order:=Order} = Opts) ->
    ParsedMetrics = lists:foldl(
        fun(#metric{scope=Scope} = Metric, Acc) ->
            Acc1 = case Opts of
                #{add_scope_info:=true} ->
                    OtelScopeMetric = fake_info_metric(otel_scope, Scope, #{}, <<"OTel Instrumentation Scope">>),
                    parse_and_accumulate_metric(OtelScopeMetric, Acc, Opts);
                _ ->
                    Acc
            end,
            parse_and_accumulate_metric(Metric, Acc1, Opts)
        end,
        #{},
        Metrics
    ),

    ResourceAttributes = otel_attributes:map(otel_resource:attributes(Resource)),
    ParsedMetrics1 =
        case AddTargetInfo of
            true ->
                TargetInfoMetric =
                    fake_info_metric(
                      target, #instrumentation_scope{}, ResourceAttributes, <<"Target metadata">>),
                parse_and_accumulate_metric(TargetInfoMetric, ParsedMetrics, Opts);
            false ->
                ParsedMetrics
        end,

    ParsedMetricsIter = maps:iterator(ParsedMetrics1, Order),
    maps:fold(fun(_K, V, Acc) -> [Acc, V] end, [], ParsedMetricsIter).

parse_and_accumulate_metric(#metric{name=Name}, Acc, _Opts)
  when is_map_key(Name, Acc) ->
    %% skip duplicate metric, can this even happen?
    Acc;
parse_and_accumulate_metric(#metric{name=Name, description=Description, data=Data, unit=Unit, scope=Scope}, Acc, Opts) ->
    FixedUnit = fix_unit(Unit),
    {MetricNameUnit, FullName} = fix_metric_name(atom_to_binary(Name), FixedUnit, Data, Opts),
    case data(FullName, Data, Scope, Opts) of
        invalid_temporality ->
            Acc;
        TextData ->
            Preamble = preamble(MetricNameUnit, Description, FixedUnit, Data),
            Acc#{Name => [Preamble, TextData]}
    end.

fix_metric_name(Name, Unit, Data, #{add_total_suffix:=AddTotalSuffix}) ->
    MetricName = fix_metric_or_label_name(Name),

    MetricNameUnit = case Unit of
        undefined -> MetricName;
        _ -> string_append(MetricName, Unit)
    end,

    FullName =
        case Data of
            _ when is_map_key(Name, ?INFO_METRICS) ->
                string_append(MetricNameUnit, <<"info">>);
            #sum{is_monotonic=true} when AddTotalSuffix =:= true ->
                string_append(MetricNameUnit, <<"total">>);
            _ ->
                MetricNameUnit
    end,

    {MetricNameUnit, FullName}.

fake_info_metric(Name, Scope, Attributes, Description) ->
    #metric{
        name=Name,
        scope=Scope,
        description=Description,
        data=#gauge{datapoints=[#datapoint{
            attributes=Attributes, value=1, exemplars=[],
            flags=0, start_time=0, time=0
        }]}
    }.

string_append(String, Suffix) ->
    case binary:longest_common_suffix([String, Suffix]) of
        X when X =:= length(Suffix) -> String;
        _ -> <<String/binary, $_, Suffix/binary>>
    end.

fix_metric_or_label_name(<<Char/utf8, Rest/binary>>) when Char >= $0, Char =< $9 ->
    fix_metric_or_label_name(Rest, true, <<$_>>);
fix_metric_or_label_name(Bin) ->
    fix_metric_or_label_name(Bin, false, <<>>).

fix_metric_or_label_name(<<>>, _, Acc) ->
    Acc;
fix_metric_or_label_name(<<Char/utf8, Rest/binary>>, _, Acc)
  when Char >= $a, Char =< $z;
       Char >= $A, Char =< $Z;
       Char >= $0, Char =< $9;
       Char =:= $: ->
    fix_metric_or_label_name(Rest, false, <<Acc/binary, Char/utf8>>);
fix_metric_or_label_name(<<_/utf8, Rest/binary>>, true, Acc) ->
    fix_metric_or_label_name(Rest, true, Acc);
fix_metric_or_label_name(<<_/utf8, Rest/binary>>, false, Acc) ->
    fix_metric_or_label_name(Rest, true, <<Acc/binary, $_>>).

fix_unit(undefined) ->
    undefined;
fix_unit(Unit) when is_atom(Unit) ->
    fix_unit(atom_to_binary(Unit));
fix_unit(<<"1">>) ->
    <<"ratio">>;
fix_unit(<<"{", _/binary>>) ->
    undefined;
fix_unit(Unit) ->
    case string:split(Unit, "/", all) of
        [_] -> guess_unit(Unit);
        List ->
            iolist_to_binary(lists:join(<<"_per_">>, [guess_unit(U) || U <- List]))
    end.

guess_unit(Unit) ->
    case try_unit(Unit) of
        not_found ->
            case try_unit_prefix(Unit) of
                not_found ->
                    Unit;
                {Prefix, BaseUnit} ->
                    case try_unit(BaseUnit) of
                        not_found -> Unit;
                        BaseUnitStr -> [Prefix, BaseUnitStr]
                    end
            end;
        UnitStr ->
            UnitStr
    end.

%% https://unitsofmeasure.org/ucum

%% Si base units
try_unit(<<"m">>) -> <<"meters">>;
try_unit(<<"s">>) -> <<"seconds">>;
try_unit(<<"g">>) -> <<"grams">>;
try_unit(<<"rad">>) -> <<"radians">>;
try_unit(<<"K">>) -> <<"kelvin">>;
try_unit(<<"C">>) -> <<"coulombs">>;
try_unit(<<"cd">>) -> <<"candelas">>;

%% IT units
try_unit(<<"By">>) -> <<"Bytes">>;
try_unit(<<"bit">>) -> <<"bits">>;
try_unit(<<"Bd">>) -> <<"baud">>;

%% not in UCUM, but used in
%% opentelemetry-collector:receiver/prometheusreceiver/internal/metricsbuilder.go
try_unit(<<"Bi">>) -> <<"bits">>;

try_unit(_) -> not_found.

%% IT unit prefixes
try_unit_prefix(<<"Ki", BaseUnit/binary>>) -> {<<"kibi">>, BaseUnit};
try_unit_prefix(<<"Mi", BaseUnit/binary>>) -> {<<"mebi">>, BaseUnit};
try_unit_prefix(<<"Gi", BaseUnit/binary>>) -> {<<"gibi">>, BaseUnit};
try_unit_prefix(<<"Ti", BaseUnit/binary>>) -> {<<"tebi">>, BaseUnit};

%% Si prefixes
try_unit_prefix(<<"Y", BaseUnit/binary>>) -> {<<"yotta">>, BaseUnit};
try_unit_prefix(<<"Z", BaseUnit/binary>>) -> {<<"zetta">>, BaseUnit};
try_unit_prefix(<<"E", BaseUnit/binary>>) -> {<<"exa">>, BaseUnit};
try_unit_prefix(<<"P", BaseUnit/binary>>) -> {<<"peta">>, BaseUnit};
try_unit_prefix(<<"T", BaseUnit/binary>>) -> {<<"tera">>, BaseUnit};
try_unit_prefix(<<"G", BaseUnit/binary>>) -> {<<"giga">>, BaseUnit};
try_unit_prefix(<<"M", BaseUnit/binary>>) -> {<<"mega">>, BaseUnit};
try_unit_prefix(<<"k", BaseUnit/binary>>) -> {<<"kilo">>, BaseUnit};
try_unit_prefix(<<"h", BaseUnit/binary>>) -> {<<"hecto">>, BaseUnit};
try_unit_prefix(<<"da", BaseUnit/binary>>) -> {<<"deka">>, BaseUnit};
try_unit_prefix(<<"d", BaseUnit/binary>>) -> {<<"deci">>, BaseUnit};
try_unit_prefix(<<"c", BaseUnit/binary>>) -> {<<"centi">>, BaseUnit};
try_unit_prefix(<<"m", BaseUnit/binary>>) -> {<<"milli">>, BaseUnit};
try_unit_prefix(<<"u", BaseUnit/binary>>) -> {<<"micro">>, BaseUnit};
try_unit_prefix(<<"n", BaseUnit/binary>>) -> {<<"nano">>, BaseUnit};
try_unit_prefix(<<"p", BaseUnit/binary>>) -> {<<"pico">>, BaseUnit};
try_unit_prefix(<<"f", BaseUnit/binary>>) -> {<<"femto">>, BaseUnit};
try_unit_prefix(<<"a", BaseUnit/binary>>) -> {<<"atto">>, BaseUnit};
try_unit_prefix(<<"z", BaseUnit/binary>>) -> {<<"zepto">>, BaseUnit};
try_unit_prefix(<<"y", BaseUnit/binary>>) -> {<<"yocto">>, BaseUnit};

try_unit_prefix(_) -> not_found.

preamble(Name, Description, Unit, Data) ->
    [preamble_type(Name, Data),
     preamble_unit(Name, Unit),
     preamble_help(Name, Description)
    ].

preamble_type(Name, Data) ->
    [<<"# TYPE ">>, Name, ?SP, metric_type(Name, Data), ?LF].

preamble_help(_Name, undefined) ->
    [];
preamble_help(Name, Description) ->
    [<<"# HELP ">>, Name, ?SP, escape_metric_help(Description), ?LF].

preamble_unit(_Name, undefined) ->
    [];
preamble_unit(Name, Unit) ->
    [<<"# UNIT ">>, Name, ?SP, Unit, ?LF].

data(_MetricName, #sum{aggregation_temporality=temporality_delta}, _Scope, _Opts) ->
    invalid_temporality;
data(_MetricName, #histogram{aggregation_temporality=temporality_delta}, _Scope, _Opts) ->
    invalid_temporality;
data(MetricName, #sum{datapoints=Datapoints, is_monotonic=IsMonotonic}, Scope, Opts) ->
    data(MetricName, Datapoints, Scope, IsMonotonic, Opts);
data(MetricName, #gauge{datapoints=Datapoints}, Scope, Opts) ->
    data(MetricName, Datapoints, Scope, false, Opts);
data(MetricName, #histogram{datapoints=Datapoints}, Scope, Opts) ->
    data(MetricName, Datapoints, Scope, true, Opts).

data(MetricName, Datapoints, Scope, AddCreated, #{add_scope_info:=AddScopeInfo}) ->
    ScopeLabels = case AddScopeInfo of
        true -> labels(Scope);
        false -> <<>>
    end,

    lists:foldl(
        fun(DP, Acc) ->
            datapoint(DP, MetricName, AddCreated, ScopeLabels, Acc)
        end,
        [[], []],
        Datapoints
    ).

datapoint(#datapoint{} = DP, MetricName, AddCreated, ScopeLabels, [Points, Created]) ->
    Labels = surround_labels(join_labels(ScopeLabels, labels(DP#datapoint.attributes))),
    Point = [MetricName, Labels, " ", number_to_binary(DP#datapoint.value), ?LF],
    Created1 = created(AddCreated, Created, MetricName, Labels, DP#datapoint.start_time),
    [[Point | Points], Created1];
datapoint(#histogram_datapoint{} = DP, MetricName, AddCreated, ScopeLabels, [Points, Created]) ->
    Labels = join_labels(ScopeLabels, labels(DP#histogram_datapoint.attributes)),
    SurroundedLabels = surround_labels(Labels),

    Count = lists:sum(DP#histogram_datapoint.bucket_counts),
    CountPoint = [MetricName, <<"_count">>, SurroundedLabels, ?SP, number_to_binary(Count), ?LF],

    SumPoint = case (DP#histogram_datapoint.sum >= 0) and lists:all(fun(B) -> B >=0 end, DP#histogram_datapoint.explicit_bounds) of
        true -> [MetricName, <<"_sum">>, SurroundedLabels, ?SP, number_to_binary(DP#histogram_datapoint.sum), ?LF];
        false -> []
    end,

    {Buckets, _} = lists:mapfoldl(
        fun({C, Le}, Sum) ->
            HistoLabels = surround_labels(join_labels(Labels, render_label_pair({<<"le">>, Le}))),
            {[MetricName, <<"_bucket">>, HistoLabels, ?SP, number_to_binary(Sum + C), ?LF], Sum + C}
        end,
        0,
        lists:zip(DP#histogram_datapoint.bucket_counts, DP#histogram_datapoint.explicit_bounds ++ [<<"+Inf">>])
    ),

    Created1 = created(AddCreated, Created, MetricName, SurroundedLabels, DP#histogram_datapoint.start_time),

    [[Buckets, CountPoint, SumPoint | Points], Created1].

created(false, Created, _MetricName, _Labels, _StartTime) ->
    Created;
created(true, Created, MetricName, Labels, StartTime) ->
    [[MetricName, <<"_created">>, Labels, ?SP, number_to_binary(opentelemetry:timestamp_to_nano(StartTime)), ?LF] | Created].

join_labels(<<>>, L) -> L;
join_labels(L, <<>> )-> L;
join_labels(L1, L2) -> [L1, $,, L2].

surround_labels(<<>>) -> [];
surround_labels(Labels) -> [${, Labels, $}].

number_to_binary(Int) when is_integer(Int) ->
    integer_to_binary(Int);
number_to_binary(Float) when is_float(Float) ->
    float_to_binary(Float, [short]).

labels(#instrumentation_scope{name=Name, version=Version}) when Name /= undefined, Version /= undefined ->
    <<(labels([{<<"otel_scope_name">>, Name}, {<<"otel_scope_version">>, Version}]))/binary>>;
labels(#instrumentation_scope{}) ->
    <<>>;
labels(Attributes) when is_map(Attributes) ->
    labels(maps:to_list(Attributes));
labels([]) ->
    <<>>;
labels([FirstLabel | Labels]) ->
    Start = << (render_label_pair(FirstLabel))/binary >>,
    B = lists:foldl(
        fun(Label, Acc) -> <<Acc/binary, ",", (render_label_pair(Label))/binary>> end,
        Start,
        Labels
    ),
    <<B/binary>>.

render_label_pair({Name, Value}) ->
  << (render_label_name(Name))/binary, "=\"", (escape_label_value(Value))/binary, "\"" >>.

render_label_name(Name) when is_atom(Name) ->
    render_label_name(atom_to_binary(Name));
render_label_name(Name) when is_list(Name) ->
    render_label_name(list_to_binary(Name));
render_label_name(Name) when is_binary(Name) ->
    fix_metric_or_label_name(Name).

metric_type(Name, #gauge{}) when is_map_key(Name, ?INFO_METRICS) ->
  <<"info">>;
metric_type(_Name, #sum{is_monotonic=true}) ->
  <<"counter">>;
metric_type(_Name, #sum{is_monotonic=false}) ->
  <<"gauge">>;
metric_type(_Name, #gauge{}) ->
  <<"gauge">>;
metric_type(_Name, #histogram{}) ->
  <<"histogram">>.

escape_metric_help(Help) ->
  escape_string(fun escape_help_char/1, Help).

escape_string(Fun, Str) when is_binary(Str) ->
  << <<(Fun(X))/binary>> || <<X:8>> <= Str >>.

escape_label_value(Value) when is_integer(Value); is_float(Value) ->
    number_to_binary(Value);
escape_label_value(AtomValue) when is_atom(AtomValue) ->
    atom_to_binary(AtomValue);
escape_label_value(BinValue) when is_binary(BinValue) ->
  escape_string(fun escape_label_char/1, BinValue);
escape_label_value([]) ->
    <<"[]">>;
escape_label_value(ListValue) when is_list(ListValue)->
    escape_label_value_list(ListValue).

escape_label_value_list([FirstElem | Elems]) ->
    Start = escape_label_value(FirstElem),
    B = lists:foldl(
        fun
            (Elem, Acc) when is_atom(Elem); is_binary(Elem); is_list(Elem) ->
                <<"\\\"", Acc/binary, "\\\",\\\"", (escape_label_value(Elem))/binary, "\\\"">>;
            (Elem, Acc) ->
                <<Acc/binary, ",", (escape_label_value(Elem))/binary>>
        end,
        Start,
        Elems
    ),
    <<"[", B/binary, "]">>.

escape_label_char($" = X) ->
  <<$\\, X>>;
escape_label_char(X) ->
  escape_help_char(X).

escape_help_char($\\ = X) ->
  <<X, X>>;
escape_help_char($\n) ->
  <<$\\, $n>>;
escape_help_char(X) ->
  <<X>>.


-ifdef(TEST).

-define(TEST_DEFAULT_OPTS, #{add_scope_info => true, add_target_info => true,
                             add_total_suffix => true, order => reversed}).

nano_to_timestamp(Nano) ->
    Offset = erlang:time_offset(),
    erlang:convert_time_unit(Nano, nanosecond, native) - Offset.

metrics_to_string(Metrics) ->
    metrics_to_string(Metrics, #{}).

metrics_to_string(Metrics, Opts) ->
    Resource = otel_resource:create(#{"res" => "b"}, "url"),
    {ok, Opts1} = init(maps:merge(?TEST_DEFAULT_OPTS, Opts)),
    iolist_to_binary(parse_metrics(Metrics, Resource, Opts1)).

lines_join(Lines) ->
    iolist_to_binary(lists:join(?LF, Lines)).

fix_metric_name_test_() ->
    [
        ?_assertEqual(<<"abc_a">>, fix_metric_or_label_name(<<"abc_$a">>)),
        ?_assertEqual(<<"abc_a">>, fix_metric_or_label_name(<<"abc/(a">>)),
        ?_assertEqual(<<"abc_a">>, fix_metric_or_label_name(<<"abc__a">>)),
        ?_assertEqual(<<"_aaa">>, fix_metric_or_label_name(<<"1aaa">>)),
        ?_assertEqual(<<"_2aa">>, fix_metric_or_label_name(<<"12aa">>)),
        ?_assertEqual(<<"_aa">>, fix_metric_or_label_name(<<"1_aa">>)),
        ?_assertEqual(<<"_aa">>, fix_metric_or_label_name(<<"1=aa">>))
    ].

empty_metrics_test() ->
    ?assertEqual(lines_join([
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            ""
        ]),
        metrics_to_string([])).

monotonic_counter_test() ->
    Metrics = [
        #metric{
            name = test,
            description = <<"lorem ipsum">>,
            unit = sec,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #sum{
                aggregation_temporality = temporality_cumulative,
                is_monotonic = true,
                datapoints = [
                    #datapoint{
                        attributes = #{},
                        start_time = nano_to_timestamp(0),
                        time = nano_to_timestamp(1),
                        value = 2,
                        flags = 0
                    },
                    #datapoint{
                        attributes = #{<<"foo">> => 1},
                        start_time = nano_to_timestamp(123),
                        time = nano_to_timestamp(456),
                        value = 789,
                        flags = 0
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test_sec counter",
            "# UNIT test_sec sec",
            "# HELP test_sec lorem ipsum",
            "test_sec_total{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",foo=\"1\"} 789",
            "test_sec_total{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 2",
            "test_sec_total_created{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",foo=\"1\"} 123",
            "test_sec_total_created{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 0",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            "# TYPE otel_scope info",
            "# HELP otel_scope OTel Instrumentation Scope",
            "otel_scope_info{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            ""
        ]),
        metrics_to_string(Metrics)
    ).

not_monotonic_counter_test() ->
    Metrics = [
        #metric{
            name = test,
            unit = kb,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #sum{
                aggregation_temporality = temporality_cumulative,
                is_monotonic = false,
                datapoints = [
                    #datapoint{
                        attributes = #{},
                        start_time = nano_to_timestamp(0),
                        time = nano_to_timestamp(1),
                        value = 2,
                        flags = 0
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test_kb gauge",
            "# UNIT test_kb kb",
            "test_kb{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 2",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            "# TYPE otel_scope info",
            "# HELP otel_scope OTel Instrumentation Scope",
            "otel_scope_info{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            ""
        ]),
        metrics_to_string(Metrics)
    ).

gauge_test() ->
    Metrics = [
        #metric{
            name = test,
            description = <<"lorem ipsum">>,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #gauge{
                datapoints = [
                    #datapoint{
                        attributes = #{<<"foo">> => 1},
                        start_time = nano_to_timestamp(123),
                        time = nano_to_timestamp(456),
                        value = 2.0,
                        flags = 0
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test gauge",
            "# HELP test lorem ipsum",
            "test{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",foo=\"1\"} 2.0",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            "# TYPE otel_scope info",
            "# HELP otel_scope OTel Instrumentation Scope",
            "otel_scope_info{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            ""
        ]),
        metrics_to_string(Metrics)
    ).

monotonic_histogram_test() ->
    Metrics = [
        #metric{
            name = test,
            description = <<"lorem ipsum">>,
            unit = sec,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #histogram{
                aggregation_temporality = temporality_cumulative,
                % 1 2 4
                datapoints = [
                    #histogram_datapoint{
                        attributes = #{},
                        start_time = nano_to_timestamp(0),
                        time = nano_to_timestamp(1),
                        count = 3,
                        sum = 7,
                        bucket_counts = [2,0,1],
                        explicit_bounds = [2,3],
                        flags = 0,
                        min = 1,
                        max = 4
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test_sec histogram",
            "# UNIT test_sec sec",
            "# HELP test_sec lorem ipsum",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"2\"} 2",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"3\"} 2",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"+Inf\"} 3",
            "test_sec_count{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 3",
            "test_sec_sum{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 7",
            "test_sec_created{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 0",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            "# TYPE otel_scope info",
            "# HELP otel_scope OTel Instrumentation Scope",
            "otel_scope_info{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            ""
        ]),
        metrics_to_string(Metrics)
    ).

not_monotonic_histogram_test() ->
    Metrics = [
        #metric{
            name = test,
            description = <<"lorem ipsum">>,
            unit = sec,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #histogram{
                aggregation_temporality = temporality_cumulative,
                datapoints = [
                    #histogram_datapoint{
                        attributes = #{},
                        start_time = nano_to_timestamp(0),
                        time = nano_to_timestamp(1),
                        count = 1,
                        sum = 3,
                        bucket_counts = [0,0,1],
                        explicit_bounds = [-5,0],
                        flags = 0,
                        min = 3,
                        max = 3
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test_sec histogram",
            "# UNIT test_sec sec",
            "# HELP test_sec lorem ipsum",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"-5\"} 0",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"0\"} 0",
            "test_sec_bucket{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\",le=\"+Inf\"} 1",
            "test_sec_count{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            "test_sec_created{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 0",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            "# TYPE otel_scope info",
            "# HELP otel_scope OTel Instrumentation Scope",
            "otel_scope_info{otel_scope_name=\"scope-1\",otel_scope_version=\"version-1\"} 1",
            ""
        ]),
        metrics_to_string(Metrics)
    ).

no_otel_scope_test() ->
    Metrics = [
        #metric{
            name = test,
            description = <<"lorem ipsum">>,
            unit = sec,
            scope = #instrumentation_scope{
                name = <<"scope-1">>,
                version = <<"version-1">>,
                schema_url = <<"https://example.com/schemas/1.8.0">>
            },
            data = #sum{
                aggregation_temporality = temporality_cumulative,
                is_monotonic = true,
                datapoints = [
                    #datapoint{
                        attributes = #{},
                        start_time = nano_to_timestamp(0),
                        time = nano_to_timestamp(1),
                        value = 2,
                        flags = 0
                    }
                ]
            }
        }
    ],
    ?assertEqual(lines_join([
            "# TYPE test_sec counter",
            "# UNIT test_sec sec",
            "# HELP test_sec lorem ipsum",
            "test_sec_total 2",
            "test_sec_total_created 0",
            "# TYPE target info",
            "# HELP target Target metadata",
            "target_info{res=\"b\"} 1",
            ""
        ]),
        metrics_to_string(Metrics, #{add_scope_info => false})
    ).

-endif.
