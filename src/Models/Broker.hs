{-# LANGUAGE OverloadedStrings #-}
module Models.Broker where

import           Prelude hiding (lookup)
import           Data.UString (UString, u)
import qualified Data.UString as US
import           Data.Maybe (fromJust)
import           Data.Time.Clock
import           Database.MongoDB (Value (Null))
import           DB


renewMaster :: DB -> UString -> IO Bool
renewMaster db uuid = do
    time <- getCurrentTime
    result <- run db $ runCommand [
          "findAndModify" =: u "broker",
          "query" =: [
            "_id" =: u "master",
            "uuid" =: uuid
          ],
          "update" =: [
            "$set" =: ["t" =: time]
          ],
          "upsert" =: True
        ]
    case result of
        Right doc -> return (look "value" doc /= Nothing)
        Left _    -> return False


claimMaster :: DB -> UString -> IO Bool
claimMaster db uuid = do
    time <- getCurrentTime
    result <- run db $ runCommand [
          "findAndModify" =: u "broker",
          "query" =: [
            "_id" =: u "master",
            "t" =: ["$lt" =: addUTCTime (-10) time]
          ],
          "update" =: [
            "$set" =: ["t" =: time, "uuid" =: uuid]
          ],
          "upsert" =: True
        ]
    case result of
        Right doc -> return (look "value" doc /= Nothing)
        Left _    -> return False
