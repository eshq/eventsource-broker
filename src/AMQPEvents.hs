{-# LANGUAGE OverloadedStrings #-}
module AMQPEvents
    (
      AMQPEvent(..)
    , ConnectionStatus(..)
    , Channel
    , openEventChannel
    , publishEvent
    ) where

import           Control.Applicative((<$>), (<*>))
import           Control.Monad(mzero, void)
import           Control.Concurrent.MVar(MVar, newMVar, swapMVar)
import           Control.Concurrent.Chan(Chan, newChan, writeChan)
import           Control.Exception (try)

import           Data.Aeson(FromJSON(..), ToJSON(..), Value(..), Result(..), fromJSON, toJSON, object, json, encode, (.:), (.:?), (.=))
import           Data.Attoparsec(parse, maybeResult)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import           Data.Configurator.Types (Config)
import qualified Data.Configurator as Conf
import qualified Data.Configurator.Types as CT

import           System.Random (randomIO)

import           Network.AMQP

-- |Wraps a AMQPChannel to publish on, a listerner chan to read from and an
-- MVar with the connection status
type AMQPConn = (Channel, Chan AMQPEvent, MVar ConnectionStatus)

-- |The AMQPEvent represents and incomming message that should be
-- mapped to an EventSource event.
data AMQPEvent = AMQPEvent
    { amqpChannel  :: B.ByteString
    , amqpUser     :: B.ByteString
    , amqpData     :: B.ByteString
    , amqpId       :: Maybe B.ByteString
    , amqpName     :: Maybe B.ByteString
    , amqpSocketId :: Maybe B.ByteString
    } deriving Show

data ConnectionStatus = Open | Closed

instance FromJSON AMQPEvent where
    parseJSON (Object v) = AMQPEvent <$>
                           v .: "channel" <*>
                           v .: "user"    <*>
                           v .: "data"    <*>
                           v .:? "id"     <*>
                           v .:? "name"   <*>
                           v .:? "socket"
    parseJSON _           = mzero

instance ToJSON AMQPEvent where
    toJSON (AMQPEvent c u d i n s) = object ["channel" .= c, "user" .= u, "data" .= d, "id" .= i, "name" .= n, "socket" .= s]

exchange :: String
exchange = "eventsource.fanout"

-- |Connects to an AMQP broker.
-- Will try to connect to a random host from the amqp.hosts setting
-- Will cycly through hosts until a working host if found or all hosts have been tried
-- Take a configuration and a queue name
openEventChannel :: Config -> String -> IO AMQPConn
openEventChannel config queue = do
    CT.List hosts  <- Conf.lookupDefault (CT.List [CT.String "127.0.0.1"]) config "amqp.hosts"
    vhost          <- Conf.lookupDefault "/" config "amqp.vhost"
    user           <- Conf.lookupDefault "guest" config "amqp.user"
    pass           <- Conf.lookupDefault "guest" config "amqp.pass"

    let numHosts = length hosts

    status <- newMVar Open
    i      <- fmap (`mod` numHosts) randomIO

    -- Its ok here to just blowup if we can't get a connection
    Just conn <- getConnection vhost user pass (take numHosts . drop i . cycle $ hosts)
    chan      <- openChannel conn

    addConnectionClosedHandler conn True $ void (swapMVar status Closed)

    declareQueue chan newQueue {queueName = queue, queueAutoDelete = True, queueDurable = False}
    declareExchange chan newExchange {exchangeName = exchange, exchangeType = "fanout", exchangeDurable = False}
    bindQueue chan queue exchange queue

    listener <- newChan
    consumeMsgs chan queue NoAck (sendTo listener)
    return (chan, listener, status)


getConnection :: String -> String -> String -> [CT.Value] -> IO (Maybe Connection)
getConnection vhost user pass = go
  where
    go [] = return Nothing
    go (x:xs) =
      case CT.convert x of
        Just host -> do
          res <- try (connect host) :: IO (Either AMQPException Connection)
          either (\_ -> go xs) (return . Just) res
        _ -> go xs
    connect host = openConnection (T.unpack host) vhost user pass


publishEvent :: Channel -> String -> AMQPEvent -> IO ()
publishEvent chan queue event =
    publishMsg chan exchange queue
        newMsg {msgBody = encode event}


-- |Write messages from AMQP to a channel
sendTo :: Chan AMQPEvent -> (Message, Envelope) -> IO ()
sendTo chan (msg, _) =
    case maybeResult $ parse json (B.concat $ LB.toChunks (msgBody msg)) of
        Just value -> case fromJSON value of
            Success event ->
                writeChan chan event
            Error _       ->
                return ()
        Nothing    -> return ()
