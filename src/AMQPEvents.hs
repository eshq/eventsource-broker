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
import           Control.Monad(mzero)
import           Control.Concurrent.MVar(MVar, newMVar, swapMVar)
import           Control.Concurrent.Chan(Chan, newChan, writeChan)

import           Data.Aeson(FromJSON(..), ToJSON(..), Value(..), Result(..), fromJSON, toJSON, object, json, encode, (.:), (.:?), (.=))
import           Data.Attoparsec(parse, maybeResult)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import           Data.Configurator.Types (Config)
import qualified Data.Configurator as Conf

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
-- Tries to get credentials, host and vhost from the AMQP_URL
-- environment variable
-- Take a configuration and a queue name
openEventChannel :: Config -> String -> IO AMQPConn
openEventChannel config queue = do
    host     <- Conf.lookupDefault "127.0.0.1" config "amqp.host"
    vhost    <- Conf.lookupDefault "/" config "amqp.vhost"
    user     <- Conf.lookupDefault "guest" config "amqp.user"
    pass     <- Conf.lookupDefault "guest" config "amqp.pass"

    status   <- newMVar Open

    conn <- openConnection host vhost user pass
    chan <- openChannel conn

    addConnectionClosedHandler conn True $ swapMVar status Closed >> return ()

    declareQueue chan newQueue {queueName = queue, queueAutoDelete = True, queueDurable = False}
    declareExchange chan newExchange {exchangeName = exchange, exchangeType = "fanout", exchangeDurable = False}
    bindQueue chan queue exchange queue

    listener <- newChan
    consumeMsgs chan queue NoAck (sendTo listener)
    return (chan, listener, status)


publishEvent :: Channel -> String -> AMQPEvent -> IO ()
publishEvent chan queue event =
    publishMsg chan exchange queue
        newMsg {msgBody = encode event}


-- |Write messages from AMQP to a channel
sendTo :: Chan AMQPEvent -> (Message, Envelope) -> IO ()
sendTo chan (msg, _) = do
    case maybeResult $ parse json (B.concat $ LB.toChunks (msgBody msg)) of
        Just value -> case fromJSON value of
            Success event -> do
                writeChan chan event
            Error _       -> do
                return ()
        Nothing    -> return ()
