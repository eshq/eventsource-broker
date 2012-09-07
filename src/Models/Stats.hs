{-# LANGUAGE OverloadedStrings #-}
module Models.Stats where

import           Control.Monad
import qualified Data.HashMap as M
import qualified Data.Text as T
import           DB

type Aggregates = [(String, Integer, Aggregate)]
type Aggregate = M.Map String (M.Map Integer Integer)


emptyAggregates :: Aggregates
emptyAggregates = [
    ("10_secs",   10, M.empty),
    ("1_mins",    60, M.empty),
    ("5_mins",   300, M.empty),
    ("1_hours", 3600, M.empty),
    ("1_days", 86400, M.empty)
  ]

aggregateCounts :: DB -> [(Integer, String)] -> IO ()
aggregateCounts db counts =
    forM_ (aggregatedCounts emptyAggregates counts) $ \(name, _, hmap) ->
      forM_ (M.assocs hmap) $ \(scope, counts') ->
        forM_ (M.assocs counts') $ \(interval, value) ->
          run db $ repsert (s scope interval name) (d value)
  where
    s scope interval name  = select ["s" =: T.pack scope, "t" =: interval] (T.pack $ "stats_by_" ++ name)
    d value = ["$inc" =: ["v" =: value]]

aggregatedCounts :: Aggregates -> [(Integer, String)] -> Aggregates
aggregatedCounts aggregates counts =
    [(name, interval, updateAggregate aggregate (div interval divisor, scope)) | (name, divisor, aggregate) <- aggregates, (interval, scope) <- counts]

updateAggregate :: Aggregate -> (Integer, String) -> Aggregate
updateAggregate aggregate (interval, scope) = 
    M.alter (incrementScopedCount interval) scope aggregate
  where
    incrementScopedCount i (Nothing) = Just $ M.singleton i 1
    incrementScopedCount i (Just hmap) = Just $ M.alter incrementCount i hmap
    incrementCount Nothing = Just 1
    incrementCount (Just val) = Just (val + 1)
