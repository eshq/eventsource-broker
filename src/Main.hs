{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative ((<|>))
import           Control.Monad (forever)
import           Control.Monad.Trans (liftIO)
import           Control.Concurrent.MVar (MVar, newMVar, readMVar, swapMVar)

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Chan (Chan, readChan, dupChan)
import           Control.Exception (bracket)

import           Snap.Core
import           Snap.Util.FileServe (serveFile, serveDirectory)
import           Snap.Http.Server( quickHttpServe)
import           Snap.Util.GZip (noCompression)

import           Data.ByteString(ByteString)
import qualified Data.ByteString.Char8 as BS
import           Data.UString (UString, u)
import qualified Data.UString as US
import           Data.Time.Clock.POSIX (POSIXTime)
import           Blaze.ByteString.Builder(fromByteString)
import           Data.Aeson

import qualified System.UUID.V4 as UUID

import           AMQPEvents(AMQPEvent(..), Channel, openEventChannel, publishEvent)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse, eventSourceIframe, eventSourceScript)

import           DB (DB, Failure, openDB, closeDB, genObjectId, rest)

import qualified Models.Connection as Conn
import qualified Models.Channel as Channel
import qualified Models.User as User
import qualified Models.Event as Event
import qualified Models.Broker as Broker

import           System.Posix.Env(getEnvDefault)
import           Data.Time.Clock.POSIX (getPOSIXTime)

import           Text.StringTemplate


-- |Setup a channel listening to an AMQP exchange and start Snap
main :: IO ()
main = do
    uuid      <- fmap (u . show) UUID.uuid
    origin    <- getEnvDefault "ORIGIN" "http://127.0.0.1"
    templates <- directoryGroup "templates" :: IO (STGroup ByteString)

    master    <- newMVar False

    let queue = US.append "eventsource." uuid
    let Just js = fmap (render . (setAttribute "origin" origin)) (getStringTemplate "eshq.js" templates)

    (publisher, listener) <- openEventChannel (show queue)

    bracket openDB (\db -> Conn.remove db uuid >> closeDB db) $ \db -> do
        forkIO $ connectionSweeper db uuid
        forkIO $ writeToBuffer master db uuid listener
        forkIO $ setMaster master db uuid
        quickHttpServe $
            ifTop (serveFile "static/index.html") <|>
            path "iframe" (serveFile "static/iframe.html") <|>
            path "es.js" (serveJS js) <|>
            dir "static" (serveDirectory "static") <|>
            method POST (route [ 
                ("event", postEvent db publisher queue),
                ("socket", createSocket db uuid),
                ("socket/:socket", postEventFromSocket db publisher queue)
            ]) <|>
            method GET (route [
                ("broker", brokerInfo master db uuid),
                ("channel/:channel/users", channelInfo db),
                ("eventsource/:transport", eventSource db uuid listener),
                ("eventsource", eventSource db uuid listener)
            ])


-- |Clean up disconnected connections for this broker at regular intervals
connectionSweeper :: DB -> UString -> IO ()
connectionSweeper db uuid = forever $ do
    threadDelay 15000000
    Conn.sweep db uuid


setMaster master db uuid = forever $ do
    threadDelay 1500000
    isMaster <- readMVar master
    if isMaster
        then do
            renewed <- Broker.renewMaster db uuid
            if renewed then return True else swapMVar master False
        else do
            claimed <- Broker.claimMaster db uuid
            if claimed then swapMVar master True else return False



writeToBuffer master db uuid chan = forever $ do
    event    <- readChan chan
    isMaster <- readMVar master
    if isMaster
        then do
          let event' = Event.Event {
            Event.eventName = toUS $ amqpName event,
            Event.eventId   = toUS $ amqpId event,
            Event.eventData = ufrombs $ amqpData event,
            Event.eventChan = ufrombs $ amqpChannel event,
            Event.eventUser = ufrombs $ amqpUser event
          }
          putStrLn $ "storing event" ++ (show event')
          Event.store db event'
          return ()
        else return ()
  where
    toUS = fmap ufrombs


brokerInfo :: MVar Bool -> DB -> UString -> Snap ()
brokerInfo master db uuid = do
    result <- liftIO $ Conn.count db uuid
    case result of
        Right info -> do
            isMaster <- liftIO . readMVar $ master
            sendJSON $ info {Conn.isMaster = Just isMaster}
        Left e -> do
            logError (BS.pack $ show e)
            showError 500 $ BS.pack $ "Database Connection Problem: " ++ (show e)


channelInfo :: DB -> Snap ()
channelInfo db = do
    withAuth db $ \user -> do
      withParam "channel" $ \channel -> do
        result <- liftIO $ Channel.presence db user channel
        case result of
            Right presenceIds -> sendJSON presenceIds
            Left e -> do
                logError (BS.pack $ show e)
                showError 500 $ BS.pack $ "Database Connection Problem: " ++ (show e)


-- |Create a new socket and return the ID
createSocket :: DB -> UString -> Snap ()
createSocket db uuid = do
    withAuth db $ \user -> do
      withParam "channel" $ \channel -> do
        socketId   <- liftIO $ fmap show UUID.uuid
        presenceId <- getParam "presence_id"
        let conn = Conn.Connection {
              Conn.socketId     = u socketId
            , Conn.brokerId     = uuid
            , Conn.userId       = User.apiKey user
            , Conn.channel      = channel
            , Conn.presenceId   = fmap ufrombs presenceId
            , Conn.disconnectAt = Just 10
        }
        result <- liftIO $ Conn.store db conn
        case result of
          Left failure -> do
              logError (BS.pack $ show failure)
              showError 500 "Database Connection Error"
          Right _ -> sendJSON conn


postEvent :: DB -> Channel -> UString -> Snap ()
postEvent db chan queue =
    withAuth db $ \user ->
      withParam "channel" $ \channel ->
          withParam "data" $ \dataParam -> do
              name <- getParam "name"
              oid  <- liftIO . fmap (BS.pack . show) $ genObjectId
              liftIO $ publishEvent chan (show queue) $
                  AMQPEvent (utobs channel) (utobs $ User.apiKey user) (utobs dataParam) (Just oid) name
              writeBS "Ok"


-- |Post a new event from a socket.
postEventFromSocket :: DB -> Channel -> UString -> Snap ()
postEventFromSocket db chan queue =
    withConnection db $ \conn ->
        withParam "data" $ \dataParam -> do
            name <- getParam "name"
            oid  <- liftIO . fmap (BS.pack . show) $ genObjectId
            liftIO $ publishEvent chan (show queue) $ 
                AMQPEvent (utobs $ Conn.channel conn) (utobs $ Conn.userId conn) (utobs dataParam) (Just oid) name
            writeBS "Ok"


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: DB -> UString -> Chan AMQPEvent -> Snap ()
eventSource db uuid chan = do
    noCompression
    chan'   <- liftIO $ dupChan chan
    withConnection db $ \conn -> do
      liftIO $ before conn
      transport <- getTransport
      lastId    <- fmap (getHeader "Last-Event-ID") getRequest <|> getParam "last-event-id"
      events    <- liftIO $ buffer conn lastId
      transport (fmap (map toEvent) events) (filterEvents conn chan') (after conn)
  where
    buffer conn (Just lastId) = do
        events <- Event.since db (Conn.userId conn) (Conn.channel conn) (ufrombs lastId)
        case events of
          Right docs -> return $ Just docs
          Left _ -> return Nothing
    buffer conn Nothing = return Nothing
    toEvent e = ServerEvent (fmap toB $ Event.eventName e) (fmap toB $ Event.eventId e) ([toB $ Event.eventData e])
    toB  = fromByteString . utobs
    before conn = Conn.store db conn { Conn.brokerId = uuid } >> return ()
    after conn = Conn.mark db (conn { Conn.disconnectAt = Just 10 } ) >> return ()


serveJS :: ByteString -> Snap ()
serveJS js = do
    modifyResponse $ setContentType "text/javascript; charset=UTF-8"
    writeBS js


withParam :: UString -> (UString -> Snap ()) -> Snap ()
withParam param fn = do
    param' <- getParam (utobs param)
    case param' of
        Just value -> fn (ufrombs value)
        Nothing    -> showError 400 $ BS.concat ["Missing param: ", utobs param]


withConnection :: DB -> (Conn.Connection -> Snap ()) -> Snap ()
withConnection db fn = do
    withParam "socket" $ \sid -> do
        withDBResult (Conn.get db sid) (showError 404 "Socket Not Found") fn


withAuth :: DB -> (User.User -> Snap ()) -> Snap ()
withAuth db handler = do
  key       <- getParam "key"
  token     <- getParam "token"
  timestamp <- getParam "timestamp"
  case (key, token, timestamp) of
    (Just key', Just token', Just timestamp') -> do
      currentTime <- liftIO getPOSIXTime
      withDBResult (User.get db (ufrombs key')) (showError 404 "User not found") $ \user ->
          if validTime timestamp' currentTime && User.authenticate user token' timestamp'
            then handler user
            else showError 401 "Access Denied"
    _ -> showError 401 "Access Denied - Missing Credentials"


withDBResult :: IO (Either Failure (Maybe a)) -> Snap () -> (a -> Snap ()) -> Snap ()
withDBResult f notFound found= do
    result <- liftIO f
    case result of
      Right (Just model) -> found model
      Right Nothing      -> notFound
      Left  failure      -> do
          logError (BS.pack $ show failure)
          showError 500 "Database Connection Error"


validTime :: ByteString -> POSIXTime -> Bool
validTime timestamp currentTime =
    let t1 = read $ BS.unpack timestamp
        t2 = floor currentTime in
        abs (t1 - t2) < 5 * 60


showError :: Int -> ByteString -> Snap ()
showError code msg = do
    modifyResponse $ setResponseCode code
    writeBS msg
    r <- getResponse
    finishWith r


sendJSON :: ToJSON a => a -> Snap ()
sendJSON val = do
    modifyResponse $ setContentType "application/json"
    writeLBS . encode . toJSON $ val


-- |Returns the transport method to use for this request
getTransport :: Snap (Maybe [ServerEvent] -> IO ServerEvent -> IO () -> Snap ())
getTransport = withRequest $ \request -> do
    iframe <- getParam "transport"
    case (iframe, getHeader "X-Requested-With" request) of
      (Just "iframe" , _                    ) -> return eventSourceIframe
      (Just "script.js" , _                 ) -> return eventSourceScript
      (_             , Just "XMLHttpRequest") -> return eventSourceResponse
      (_             , _                    ) -> return eventSourceStream


-- |Filter AMQPEvents by channelId
filterEvents :: Conn.Connection -> Chan AMQPEvent -> IO ServerEvent
filterEvents conn chan = do
    event <- readChan chan
    if amqpUser event == userId && amqpChannel event == channel
        then return $ ServerEvent (toB $ amqpName event) (toB $ amqpId event) [fromByteString $ amqpData event]
        else filterEvents conn chan
  where
    toB     = fmap fromByteString
    userId  = utobs $ Conn.userId conn
    channel = utobs $ Conn.channel conn


ufrombs :: ByteString -> UString
ufrombs = US.fromByteString_


utobs :: UString -> ByteString
utobs = US.toByteString
