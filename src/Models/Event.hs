{-# LANGUAGE OverloadedStrings #-}
module Models.Event where

import           Prelude hiding (lookup)
import           Data.UString (UString)
import           Data.Maybe (fromJust)
import           Database.MongoDB (Value (Null))
import           DB

data Event = Event
           { eventName :: Maybe UString
           , eventId   :: Maybe UString
           , eventData :: UString
           , eventChan :: UString
           , eventUser :: UString
           }


store :: DB -> Event -> IO (Either Failure Value)
store db event = case eventId event of
    Just _  -> run db $ insert "events" doc
    Nothing -> return $ Right Null
  where
    doc =
        [ "_id" =: fromJust (eventId event)
        , "n" =: eventName event
        , "d" =: eventData event
        , "c" =: eventChan event
        , "u" =: eventUser event
        ]
