{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      Document,
      Cursor,
      Query (..),
      ObjectId,
      Failure,
      withDB,
      openDB,
      closeDB,
      createCollections,
      genObjectId,
      returnModel,
      run,
      insert,
      repsert,
      modify,
      runCommand,
      delete,
      select,
      find,
      findOne,
      count,
      rest,
      look,
      lookup,
      distinct,
      at,
      (=:),
      u
    ) where

import           Prelude hiding (lookup)

import           Control.Exception (bracket)
import           Control.Monad.Instances ()

import           Data.UString (u)
import           Data.CompactString (CompactString, Encoding, toByteString)
import           Data.Aeson
import           Data.Configurator.Types (Config)
import qualified Data.Configurator as Conf

import          Database.MongoDB (
                    Action, Pipe, Database, Document, Query (..), Cursor, ObjectId, Failure, AccessMode(..),
                    CollectionOption(..), runIOE, connect, auth, access,
                    readHostPort, close, insert, repsert, modify, delete, (=:), select, runCommand, rest,
                    find, findOne, count, look, lookup, distinct, at, genObjectId, createCollection
                 )

-- |A connection to a mongoDB
data DB = DB { mongoPipe :: Pipe, mongoDB :: Database }

instance Encoding a => ToJSON (CompactString a) where
  toJSON = toJSON . toByteString

-- |Opens a connection to the database speficied in the MONGO_URL
-- environment variable
openDB :: Config -> IO DB
openDB config = do
    openConn config


-- |Close the connection to the database
closeDB :: DB -> IO ()
closeDB = closeConn


-- |Bracket around opening and closing the DB connection
withDB :: Config -> (DB -> IO ()) -> IO ()
withDB config f = do
    bracket (openConn config) closeConn f


createCollections :: Config -> DB -> IO ()
createCollections config db = do
  statsCap  <- Conf.require config "caps.stats"
  bufferCap <- Conf.require config "caps.buffer"
  
  run db $ createCollection [Capped, MaxByteSize statsCap] "stats_by_10_secs"
  run db $ createCollection [Capped, MaxByteSize statsCap] "stats_by_1_mins"
  run db $ createCollection [Capped, MaxByteSize bufferCap] "events"
  
  return ()


returnModel :: (Document -> a) -> Either Failure (Maybe Document) -> Either Failure (Maybe a)
returnModel constructor = fmap (fmap constructor)


openConn :: Config -> IO DB
openConn config = do
    user   <- Conf.lookup config "mongodb.user"
    pass   <- Conf.lookup config "mongodb.pass"
           
    host   <- Conf.lookupDefault "127.0.0.1" config "mongodb.host"
    port   <- Conf.lookupDefault 27017 config "mongodb.port" :: IO Int
    dbName <- Conf.lookupDefault "eventsourcehq" config "mongodb.database"

    pipe <- runIOE $ connect (readHostPort (host ++ ":" ++ (show port)))

    let db = DB pipe (u dbName)

    authenticate db user pass

    return db


authenticate :: DB -> (Maybe String) -> (Maybe String) -> IO (Either Failure Bool)
authenticate db (Just user) (Just pass) = run db $ auth (u user) (u pass)
authenticate db _ _                     = return (Right True)


run :: DB -> Action IO a -> IO (Either Failure a)
run (DB pipe db) action = 
    access pipe UnconfirmedWrites db action


closeConn :: DB -> IO ()
closeConn db = close (mongoPipe db)
