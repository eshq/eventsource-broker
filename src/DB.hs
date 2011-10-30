{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      Document,
      Failure,
      withDB,
      openDB,
      closeDB,
      genObjectId,
      returnModel,
      run,
      insert,
      repsert,
      modify,
      runCommand,
      delete,
      select,
      findOne,
      count,
      look,
      lookup,
      distinct,
      at,
      (=:)
    ) where

import           Prelude hiding (lookup)

import           Control.Exception (bracket)
import           Control.Monad.Instances

import           System.Posix.Env(getEnvDefault)
import           Data.String.Utils(split)
import           Text.URI(URI(..), parseURI)

import           Data.UString (UString, u)
import           Data.CompactString (CompactString, Encoding, toByteString)
import           Data.CompactString.Encodings (UTF8)
import           Data.Maybe (fromJust)
import           Data.Aeson

import          Database.MongoDB (
                    Action, Pipe, Database, Document, Failure, AccessMode(..), runIOE, connect, auth, access,
                    readHostPort, close, insert, repsert, modify, delete, (=:), select, runCommand,
                    findOne, count, look, lookup, distinct, at, genObjectId
                 )

-- |A connection to a mongoDB
data DB = DB { mongoPipe :: Pipe, mongoDB :: Database }


-- |Credentials for authenticating with a mongoDB
data Credentials = NoAuth
                 | Credentials { crUser :: UString, crPass :: UString }


instance Encoding a => ToJSON (CompactString a) where
  toJSON = toJSON . toByteString

-- |Opens a connection to the database speficied in the MONGO_URL
-- environment variable
openDB :: IO DB
openDB = do
    mongoURI <- getEnvDefault "MONGO_URL" "mongodb://127.0.0.1:27017/eventsourcehq"
    openConn mongoURI


-- |Close the connection to the database
closeDB :: DB -> IO ()
closeDB = closeConn


-- |Bracket around opening and closing the DB connection
withDB :: (DB -> IO ()) -> IO ()
withDB f = do
    mongoURI <- getEnvDefault "MONGO_URL" "mongodb://127.0.0.1:27017/eventsourcehq"

    bracket (openConn mongoURI) closeConn f	


returnModel :: (Document -> a) -> Either Failure (Maybe Document) -> Either Failure (Maybe a)
returnModel constructor = fmap (fmap constructor)


openConn :: String -> IO DB
openConn mongoURI = do
    let uri       = fromJust $ parseURI mongoURI
    let creds     = case fmap (split ":") (uriUserInfo uri) of
                        Nothing     -> NoAuth
                        Just [us, pw] -> Credentials (u us) (u pw)
    let hostname  = fromJust $ uriRegName uri
    let port      = case uriPort uri of
                        Just p  -> show p
                        Nothing -> "27017"

    let dbName    = u $ drop 1 (uriPath uri)

    pipe <- runIOE $ connect (readHostPort (hostname ++ ":" ++ port))

    let db = DB pipe dbName

    authenticate db creds

    return db


authenticate :: DB -> Credentials -> IO (Either Failure Bool)
authenticate db NoAuth                  = return (Right True)
authenticate db (Credentials user pass) = run db (auth user pass)


run :: DB -> Action IO a -> IO (Either Failure a)
run (DB pipe db) action = 
    access pipe UnconfirmedWrites db action


closeConn :: DB -> IO ()
closeConn db = close (mongoPipe db)
