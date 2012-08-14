{-# LANGUAGE OverloadedStrings #-}
module Models.Event where

import           Prelude hiding (lookup)
import           Data.ByteString (ByteString)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import           Data.Maybe (fromJust)
import           Database.MongoDB (Value (Null, Float), Field (..))
import           Control.Monad.Instances()
import           DB

data Event = Event
           { eventName :: Maybe Text
           , eventId   :: Maybe Text
           , eventData :: Text
           , eventChan :: Text
           , eventUser :: Text
           } deriving (Show)


store :: DB -> Event -> IO (Either Failure Value)
store db event = case eventId event of
    Just _  -> do
      run db $ insert "events" doc
    Nothing -> return $ Right Null
  where
    oid :: ObjectId
    oid = read . T.unpack . fromJust . eventId $ event
    doc =
        [ "_id" =: oid
        , "n" =: eventName event
        , "d" =: eventData event
        , "c" =: eventChan event
        , "u" =: eventUser event
        ]


since :: DB -> Text -> Text -> Text -> IO (Either Failure [Event])
since db user channel eid = do
    result <- run db $ rest =<< (find $ (select ["u" =: user, "c" =: channel, "_id" =: ["$gt" =: oid]] "events") {limit = 50, sort = ["$natural" := Float 1]})
    return $ fmap (map  constructor) result
  where
    oid :: ObjectId
    oid = read . T.unpack $ eid

constructor :: Document -> Event
constructor doc = Event (lookup "n" doc) (lookup "_id" doc) (at "d" doc) (at "c" doc) (at "u" doc)
