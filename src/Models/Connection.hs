{-# LANGUAGE OverloadedStrings #-}
module Models.Connection where

import           Prelude hiding (lookup)

import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import           Data.UString (UString)

import           DB

-- |An eventSource connection to the broker persisted in mongoDB
data Connection = Connection 
    { socketId     :: UString
    , brokerId     :: UString
    , userId       :: UString
    , channel      :: UString
    , presenceId   :: Maybe UString
    , disconnectAt :: Maybe Int -- Seconds from current time
    }


-- |Store a "connection" to the broker in the database
-- If the disconnect is set, the connection will be marked for
-- disconnection during a coming sweep
store :: DB -> Connection -> IO (Either Failure ())
store db conn= do
    time <- disconnectTime (disconnectAt conn)
    run db $ repsert (select s "connections") (d time)
  where
    s = ["_id" =: socketId conn, "channel" =: channel conn, "user_id" =: userId conn]
    d (Just time) = s ++ presence ++ ["broker" =: brokerId conn, "disconnect_at" =: time]
    d Nothing     = s ++ presence ++ ["broker" =: brokerId conn]
    presence      = case presenceId conn of
                        Just pid -> ["presence_id" =: pid]
                        Nothing  -> []


-- |Mark a connection. Marked connections will be removed by a later
-- sweep
mark :: DB -> Connection -> IO (Either Failure ())
mark db conn = do
    case disconnectAt conn of
        Just offset -> do
            time <- disconnectTime (Just offset)
            run db $ modify (select s "connections") (m time)
        Nothing -> return $ Right ()
  where
    s = ["_id" =: (socketId conn), "user_id" =: userId conn]
    m time = ["$set" =: ["disconnect_at" =: time]]


-- |Sweep connections. All marked connections with a disconnect_at less
-- than the current time will be removed.
sweep :: DB -> UString -> IO (Either Failure ())
sweep db bid = do
    time <- getCurrentTime
    run db $ delete (select ["broker" =: bid, "disconnect_at" =: ["$lte" =: time]] "connections")


-- |Remove all connections from a broker from the db
remove :: DB -> UString -> IO (Either Failure ())
remove db bid = 
    run db $ delete (select ["broker" =: bid] "connections")


get :: DB -> UString -> IO (Either Failure (Maybe Connection))
get db sid = do
    result <- run db $ findOne (select ["_id" =: sid] "connections")
    return $ returnModel constructor result


constructor :: Document -> Connection
constructor doc = Connection {
                  brokerId     = at "broker" doc
                , socketId     = at "_id" doc
                , userId       = at "user_id" doc
                , channel      = at "channel" doc
                , presenceId   = lookup "presence_id" doc
                , disconnectAt = Nothing
                }


count :: DB -> UString -> IO (Either Failure Int)
count db bid =
    run db $ DB.count (select ["broker" =: bid] "connections")


disconnectTime :: Maybe Int -> IO (Maybe UTCTime)
disconnectTime (Just offset) = fmap (Just . posixSecondsToUTCTime . (+ (fromIntegral offset))) getPOSIXTime 
disconnectTime Nothing       = return Nothing
