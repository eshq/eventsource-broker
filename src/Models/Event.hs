{-# LANGUAGE OverloadedStrings #-}
module Models.Event where

import           Prelude hiding (lookup)
import           Data.UString (UString, unpack)
import           Data.Maybe (fromJust)
import           Database.MongoDB (Value (Null, Float), Field (..))
import           Control.Monad.Instances
import           DB

data Event = Event
           { eventName :: Maybe UString
           , eventId   :: Maybe UString
           , eventData :: UString
           , eventChan :: UString
           , eventUser :: UString
           } deriving (Show)


store :: DB -> Event -> IO (Either Failure Value)
store db event = case eventId event of
    Just _  -> do
      run db $ insert "events" doc
    Nothing -> return $ Right Null
  where
    oid :: ObjectId
    oid = read . unpack . fromJust . eventId $ event
    doc =
        [ "_id" =: oid
        , "n" =: eventName event
        , "d" =: eventData event
        , "c" =: eventChan event
        , "u" =: eventUser event
        ]


since :: DB -> UString -> UString -> UString -> IO (Either Failure [Event])
since db user channel eid = do
    result <- run db $ rest =<< (find $ (select ["u" =: user, "c" =: channel, "_id" =: ["$gt" =: oid]] "events") {limit = 50, sort = ["$natural" := Float 1]})
    return $ fmap (map  constructor) result
  where
    oid :: ObjectId
    oid = read . unpack $ eid

constructor :: Document -> Event
constructor doc = Event (lookup "n" doc) (lookup "_id" doc) (at "d" doc) (at "c" doc) (at "u" doc)
