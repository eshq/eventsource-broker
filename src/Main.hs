{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative ((<|>))
import           Control.Monad (forever)
import           Control.Monad.Trans (liftIO)
import           Control.Concurrent.MVar (MVar, newMVar, readMVar, swapMVar, modifyMVar_)

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Chan (Chan, readChan, dupChan)
import           Control.Exception (bracket)

import           Snap.Core
import           Snap.Util.FileServe (serveFile, serveDirectory)
import           Snap.Http.Server( quickHttpServe)
import           Snap.Util.GZip (noCompression)

import           Data.ByteString(ByteString)
import qualified Data.ByteString.Char8 as BS
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import           Data.Time.Clock.POSIX (POSIXTime)
import           Blaze.ByteString.Builder(fromByteString)
import           Data.Aeson
import qualified Data.Configurator as Conf

import qualified System.UUID.V4 as UUID

import           AMQPEvents(AMQPEvent(..), ConnectionStatus(..), Channel, openEventChannel, publishEvent)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse, eventSourceIframe, eventSourceScript)

import           DB (DB, Failure, openDB, closeDB, createCollections, genObjectId)

import qualified Models.Connection as Conn
import qualified Models.Channel as Channel
import qualified Models.User as User
import qualified Models.Event as Event
import qualified Models.Broker as Broker
import qualified Models.Stats as Stats

import           Data.Time.Clock.POSIX (getPOSIXTime)

import           Text.StringTemplate


-- |Setup a channel listening to an AMQP exchange and start Snap
main :: IO ()
main = do
    uuid      <- fmap (T.pack . show) UUID.uuid
    templates <- directoryGroup "templates" :: IO (STGroup ByteString)

    config    <- Conf.load [Conf.Required "config/app.cfg"]
    origin    <- Conf.require config "broker.origin" :: IO ByteString

    master    <- newMVar False
    counts    <- newMVar []

    let queue = T.append "eventsource." uuid
    let Just js = fmap (render . (setAttribute "origin" origin)) (getStringTemplate "eshq.js" templates)

    (publisher, listener, amqpStatus) <- openEventChannel config (show queue)

    bracket (openDB config) (\db -> Conn.remove db uuid >> closeDB db) $ \db -> do
        createCollections config db

        forkIO $ connectionSweeper db uuid
        forkIO $ writeToBuffer master db listener
        forkIO $ aggregateStats db counts
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
                ("broker", brokerInfo master db uuid amqpStatus),
                ("channel/:channel/users", channelInfo db),
                ("eventsource/:transport", eventSource db uuid listener counts),
                ("eventsource", eventSource db uuid listener counts)
            ])


-- |Clean up disconnected connections for this broker at regular intervals
connectionSweeper :: DB -> Text -> IO ()
connectionSweeper db uuid = forever $ do
    threadDelay 15000000
    Conn.sweep db uuid


setMaster :: MVar Bool -> DB -> Text -> IO ()
setMaster master db uuid = forever $ do
    threadDelay 1000000
    isMaster <- readMVar master
    if isMaster
        then do
            renewed <- Broker.renewMaster db uuid
            if renewed then return True else swapMVar master False
        else do
            claimed <- Broker.claimMaster db uuid
            if claimed then swapMVar master True else return False


writeToBuffer :: MVar Bool -> DB -> Chan AMQPEvent -> IO ()
writeToBuffer master db chan = forever $ do
    event      <- readChan chan
    isMaster   <- readMVar master
    if isMaster
        then do
          let event' = Event.Event {
            Event.eventName = fmap E.decodeUtf8 $ amqpName event,
            Event.eventId   = fmap E.decodeUtf8 $ amqpId event,
            Event.eventData = E.decodeUtf8 $ amqpData event,
            Event.eventChan = E.decodeUtf8 $ amqpChannel event,
            Event.eventUser = E.decodeUtf8 $ amqpUser event
          }          
          Event.store db event'
          return ()
        else return ()


aggregateStats :: DB -> MVar [(Integer, String)] -> IO ()
aggregateStats db counts = forever $ do
    threadDelay 5000000
    counts' <- swapMVar counts []
    Stats.aggregateCounts db counts'
    return ()


brokerInfo :: MVar Bool -> DB -> Text -> MVar ConnectionStatus -> Snap ()
brokerInfo master db uuid amqpStatus = do
    status <- liftIO $ readMVar amqpStatus
    case status of
      Open -> do
        result <- liftIO $ Conn.count db uuid
        case result of
            Right info -> do
                isMaster <- liftIO . readMVar $ master
                sendJSON $ info {Conn.isMaster = Just isMaster}
            Left e -> do
                logError (BS.pack $ show e)
                showError 500 $ BS.pack $ "Database Connection Problem: " ++ (show e)
      Closed -> showError 500 $ BS.pack $ "Lost Connection to AMQP exchange"


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
createSocket :: DB -> Text -> Snap ()
createSocket db uuid = do
    withAuth db $ \user -> do
      withParam "channel" $ \channel -> do
        socketId   <- liftIO $ fmap show UUID.uuid
        presenceId <- getParam "presence_id"
        let conn = Conn.Connection {
              Conn.socketId     = T.pack socketId
            , Conn.brokerId     = uuid
            , Conn.userId       = User.apiKey user
            , Conn.channel      = channel
            , Conn.presenceId   = fmap E.decodeUtf8 presenceId
            , Conn.disconnectAt = Just 10
        }
        result <- liftIO $ Conn.store db conn
        case result of
          Left failure -> do
              logError (BS.pack $ show failure)
              showError 500 "Database Connection Error"
          Right _ -> sendJSON conn


postEvent :: DB -> Channel -> Text -> Snap ()
postEvent db chan queue =
    withAuth db $ \user ->
      withParam "channel" $ \channel ->
          withParam "data" $ \dataParam -> do
              name <- getParam "name"
              oid  <- liftIO . fmap (BS.pack . show) $ genObjectId
              liftIO $ publishEvent chan (show queue) $
                  AMQPEvent (E.encodeUtf8 channel) (E.encodeUtf8 $ User.apiKey user) (E.encodeUtf8 dataParam) (Just oid) name Nothing
              writeBS "Ok"


-- |Post a new event from a socket.
postEventFromSocket :: DB -> Channel -> Text -> Snap ()
postEventFromSocket db chan queue =
    withConnection db $ \conn ->
        withParam "data" $ \dataParam -> do
            name <- getParam "name"
            oid  <- liftIO . fmap (BS.pack . show) $ genObjectId
            liftIO $ publishEvent chan (show queue) $ 
                AMQPEvent (E.encodeUtf8 $ Conn.channel conn) (E.encodeUtf8 $ Conn.userId conn) (E.encodeUtf8 dataParam) (Just oid) name Nothing
            writeBS "Ok"


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: DB -> Text -> Chan AMQPEvent -> MVar [(Integer, String)] -> Snap ()
eventSource db uuid chan counts= do
    noCompression
    chan'   <- liftIO $ dupChan chan
    withConnection db $ \conn -> do
      liftIO $ before conn
      transport <- getTransport
      lastId    <- fmap (getHeader "Last-Event-ID") getRequest <|> getParam "last-event-id"
      events    <- liftIO $ buffer conn lastId
      transport (fmap (map toEvent) events) (filterEvents conn chan' counts) (after conn)
  where
    buffer conn (Just lastId) = do
        events <- Event.since db (Conn.userId conn) (Conn.channel conn) (E.decodeUtf8 lastId)
        case events of
          Right docs -> return $ Just docs
          Left _ -> return Nothing
    buffer _ Nothing = return Nothing
    toEvent e = ServerEvent (fmap toB $ Event.eventName e) (fmap toB $ Event.eventId e) ([toB $ Event.eventData e])
    toB  = fromByteString . E.encodeUtf8
    before conn = Conn.store db conn { Conn.brokerId = uuid } >> return ()
    after conn = Conn.mark db (conn { Conn.disconnectAt = Just 10 } ) >> return ()


serveJS :: ByteString -> Snap ()
serveJS js = do
    modifyResponse $ setContentType "text/javascript; charset=UTF-8"
    writeBS js


withParam :: Text -> (Text -> Snap ()) -> Snap ()
withParam param fn = do
    param' <- getParam (E.encodeUtf8 param)
    case param' of
        Just value -> fn (E.decodeUtf8 value)
        Nothing    -> showError 400 $ BS.concat ["Missing param: ", E.encodeUtf8 param]


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
      withDBResult (User.get db (E.decodeUtf8 key')) (showError 404 "User not found") $ \user ->
          if validTime timestamp' currentTime
            then if User.authenticate user token' timestamp'
              then handler user
              else showError 401 "Access Denied - Bad Credentials"
            else showError 401 (BS.pack $ "Access Denied - Timestamp invalid, timestamp: " ++ (show timestamp') ++ " server time: " ++ (show currentTime))
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
        t2 = floor currentTime :: Integer in
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
filterEvents :: Conn.Connection -> Chan AMQPEvent -> MVar [(Integer, String)] -> IO ServerEvent
filterEvents conn chan counts = do
    event <- readChan chan
    if amqpUser event == userId && amqpChannel event == channel && amqpSocketId event /= Just socketId
        then do
          time <- fmap floor getPOSIXTime
          modifyMVar_ counts $ \counts' -> return ((time, BS.unpack $ amqpUser event) : counts')
          return $ ServerEvent (toB $ amqpName event) (toB $ amqpId event) [fromByteString $ amqpData event]
        else filterEvents conn chan counts
  where
    toB      = fmap fromByteString
    userId   = E.encodeUtf8 $ Conn.userId conn
    channel  = E.encodeUtf8 $ Conn.channel conn
    socketId = E.encodeUtf8 $ Conn.socketId conn