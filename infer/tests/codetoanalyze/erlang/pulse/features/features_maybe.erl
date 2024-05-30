% Copyright (c) Facebook, Inc. and its affiliates.
%
% This source code is licensed under the MIT license found in the
% LICENSE file in the root directory of this source tree.

-module(features_maybe).
-include("../../common.hrl").
-feature(maybe_expr, enable). % Won't be needed from OTP 27

-export([
    test_maybe_simple_Ok/0,
    test_maybe_simple_Bad/0,
    test_maybe_short_circuit1_Ok/0,
    test_maybe_short_circuit2_Bad/0,
    test_maybe_short_circuit3_Ok/0,
    test_maybe_short_circuit4_Bad/0
]).

test_maybe_simple_Ok() ->
    M = maybe
        X = 3,
        Y = X,
        Z = Y,
        Z
    end,
    ?ASSERT_EQUAL(3, M).

test_maybe_simple_Bad() ->
    M = maybe
        X = 3,
        Y = X,
        Z = Y,
        Z
    end,
    ?CRASH_IF_EQUAL(3, M).

test_maybe_short_circuit1_Ok() ->
    M = maybe
        X ?= 1,
        X
    end,
    ?ASSERT_EQUAL(1, M).

test_maybe_short_circuit2_Bad() ->
    M = maybe
        X ?= 1,
        X
    end,
    ?CRASH_IF_EQUAL(1, M).

test_maybe_short_circuit3_Ok() ->
    M = maybe
        X = 2,
        1 ?= X,
        3
    end,
    ?ASSERT_EQUAL(2, M).

test_maybe_short_circuit4_Bad() ->
    M = maybe
        X = 2,
        1 ?= X,
        3
    end,
    ?CRASH_IF_EQUAL(2, M).
