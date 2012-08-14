{-# LANGUAGE OverloadedStrings #-}
module Models.Broker where

import           Prelude hiding (lookup)
import           Data.ByteString (ByteString)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import           Data.Time.Clock
import           DB


renewMaster :: DB -> Text -> IO Bool
renewMaster db uuid = do
    time <- getCurrentTime
    result <- run db $ runCommand [
          "findAndModify" =: T.pack "broker",
          "query" =: [
            "_id" =: T.pack "master",
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


claimMaster :: DB -> Text -> IO Bool
claimMaster db uuid = do
    time <- getCurrentTime
    result <- run db $ runCommand [
          "findAndModify" =: T.pack "broker",
          "query" =: [
            "_id" =: T.pack "master",
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
