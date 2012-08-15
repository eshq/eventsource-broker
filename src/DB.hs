{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      DBStatus(..),
      Document,
      Cursor,
      Query (..),
      ObjectId,
      Failure,
      withDB,
      openDB,
      closeDB,
      dbStatus,
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
      (=:)
    ) where

import           Prelude hiding (lookup)

import           Control.Exception (bracket)
import           Control.Monad.Instances ()

import qualified Data.Text as T
import           Data.Aeson
import           Data.Configurator.Types (Config)
import qualified Data.Configurator as Conf
import           Data.Maybe (isJust, fromJust)

import          Database.MongoDB (
                    Action, Pipe, Database, Document, Query (..), Cursor, ObjectId, Failure, AccessMode(..),
                    CollectionOption(..), runIOE, connect, host, openReplicaSet, primary, auth, access,
                    readHostPort, close, insert, repsert, modify, delete, (=:), select, runCommand, rest,
                    find, findOne, count, look, lookup, distinct, at, genObjectId, createCollection, isClosed
                 )

-- |A connection to a mongoDB
data DB = DB { mongoPipe :: Pipe, mongoDB :: Database }
data DBStatus = DBOpen | DBClosed deriving Eq


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


dbStatus :: DB -> IO DBStatus
dbStatus db = isClosed (mongoPipe db) >>= \s -> return $ if s then DBClosed else DBOpen


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
    user    <- Conf.lookup config "mongodb.user"
    pass    <- Conf.lookup config "mongodb.pass"
    setName <- Conf.lookup config "mongodb.replSet"
               
    hostname <- Conf.lookupDefault "127.0.0.1"          config "mongodb.host"
    port     <- Conf.lookupDefault 27017                config "mongodb.port" :: IO Int
    dbName   <- Conf.lookupDefault "webpop-development" config "mongodb.database"


    pipe <- if isJust setName then connectToSet (fromJust setName) hostname else connectToHost hostname port

    let db = DB pipe (T.pack dbName)

    authenticate db user pass

    return db


connectToHost :: String -> Int -> IO Pipe
connectToHost hostname port = runIOE $ connect (readHostPort (hostname ++ ":" ++ (show port)))


connectToSet :: String -> String -> IO Pipe
connectToSet setName hostname = do
  set  <- runIOE $ openReplicaSet (T.pack setName, [host hostname])
  runIOE $ primary set


authenticate :: DB -> (Maybe String) -> (Maybe String) -> IO (Either Failure Bool)
authenticate db (Just user) (Just pass) = run db $ auth (T.pack user) (T.pack pass)
authenticate db _ _                     = return (Right True)


run :: DB -> Action IO a -> IO (Either Failure a)
run (DB pipe db) action = 
    access pipe UnconfirmedWrites db action


closeConn :: DB -> IO ()
closeConn db = close (mongoPipe db)
