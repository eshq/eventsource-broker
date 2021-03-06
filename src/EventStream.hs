{-# LANGUAGE OverloadedStrings #-}

{-
  Based on https://github.com/cdsmith/gloss-web

  Copyright (c)2011, Chris Smith <cdsmith@gmail.com>

  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

      * Redistributions of source code must retain the above copyright
        notice, this list of conditions and the following disclaimer.

      * Redistributions in binary form must reproduce the above
        copyright notice, this list of conditions and the following
        disclaimer in the documentation and/or other materials provided
        with the distribution.

      * Neither the name of Chris Smith <cdsmith@gmail.com> nor the names of other
        contributors may be used to endorse or promote products derived
        from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-}

{-|
    A Snap adapter to the HTML5 Server-Sent Events API.  Push-mode and
    pull-mode interfaces are both available.
-}
module EventStream (
    ServerEvent(..),
    eventSourceStream,
    eventSourceResponse,
    eventSourceIframe,
    eventSourceScript
    ) where

import Blaze.ByteString.Builder
import Blaze.ByteString.Builder.Char8
import Control.Monad.Trans
import Control.Exception (onException)
import Data.Monoid
import Data.Maybe (fromJust, mapMaybe)
import Data.Aeson
import Data.Enumerator (Step(..), Stream(..), (>>==), returnI)
-- import Data.Enumerator.List (generateM)
import Snap.Core
import System.Timeout

{-|
    Type representing a communication over an event stream.  This can be an
    actual event, a comment, a modification to the retry timer, or a special
    "close" event indicating the server should close the connection.
-}
data ServerEvent
    = ServerEvent {
        eventName :: Maybe Builder,
        eventId   :: Maybe Builder,
        eventData :: [Builder]
        }
    | CommentEvent {
        eventComment :: Builder
        }
    | RetryEvent {
        eventRetry :: Int
        }
    | CloseEvent


eventType :: ServerEvent -> String
eventType (ServerEvent{})     = "message"
eventType (CommentEvent _)    = "comment"
eventType (RetryEvent _)      = "retry"
eventType (CloseEvent)        = "close"


instance ToJSON ServerEvent where
    toJSON e@(ServerEvent n i d) = object ["type" .= eventType e, "name" .= n, "id" .= i, "data" .= d]
    toJSON e@(CommentEvent d)    = object ["type" .= eventType e, "data" .= d]
    toJSON e@(RetryEvent i)      = object ["type" .= eventType e, "time" .= i]
    toJSON e@CloseEvent          = object ["type" .= eventType e]


instance ToJSON Builder where
  toJSON = toJSON . toByteString


{-|
    Newline as a Builder.
-}
nl :: Builder
nl = fromChar '\n'


{-|
    Field names as Builder
-}
nameField :: Builder
nameField = fromString "event:"
idField :: Builder
idField = fromString "id:"
dataField :: Builder
dataField = fromString "data:"
retryField :: Builder
retryField = fromString "retry:"
commentField :: Builder
commentField = fromChar ':'


{-|
    Wraps the text as a labeled field of an event stream.
-}
field :: Builder -> Builder -> Builder
field l b = l `mappend` b `mappend` nl


{-|
    Appends a buffer flush to the end of a Builder.
-}
flushAfter :: Builder -> Builder
flushAfter b = b `mappend` flush

{-|
    Send a comment with the string "ping" to the client.
-}
pingEvent :: ServerEvent
pingEvent = ServerEvent (Just $ fromString "ping") Nothing [fromString "{}"]


iframeHead :: [Builder]
iframeHead = [
    fromString "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">",
    fromString "<script>",
    fromString "window.onError = null;",
    fromString "document.domain = \"ws.webpop.local\";",
    fromString "</script></head>",
    fromString "<body>",
    fromString "<script>parent.ESHQ({type: \"open\"});</script>",
    flush
  ]


{-|
    Converts a 'ServerEvent' to its wire representation as specified by the
    @text/event-stream@ content type.
-}
eventSourceBuilder :: ServerEvent -> Maybe Builder
eventSourceBuilder (CommentEvent txt) = Just $ flushAfter $ field commentField txt
eventSourceBuilder (RetryEvent   n)   = Just $ flushAfter $ field retryField (fromShow n)
eventSourceBuilder (CloseEvent)       = Nothing
eventSourceBuilder (ServerEvent n i d)= Just $ flushAfter $
    name n (evid i $ mconcat (map (field dataField) d)) `mappend` nl
  where
    name Nothing  = id
    name (Just n') = mappend (field nameField n')
    evid Nothing  = id
    evid (Just i') = mappend (field idField   i')


eventToScript :: ServerEvent -> Builder
eventToScript e = fromString "parent.ESHQ(" `mappend` (fromLazyByteString . encode $ e) `mappend` fromString ");" 


scriptBuilder :: ServerEvent -> Maybe Builder
scriptBuilder e = Just $ flushAfter $ eventToScript e `mappend` nl


scriptTagBuilder :: ServerEvent -> Maybe Builder
scriptTagBuilder CloseEvent = Nothing
scriptTagBuilder e = Just $ flushAfter $ 
      fromString "<script>" `mappend` eventToScript e `mappend` fromString "</script>" `mappend` nl


bufferToBuilder :: Maybe [ServerEvent] -> (ServerEvent -> Maybe Builder) -> [Builder]
bufferToBuilder (Just buffer) builder = mapMaybe builder buffer
bufferToBuilder Nothing _ = []


eventSourceEnum header source builder timeoutAction finalizer = prepend header
  where
    prepend [] (Continue k) = go (Continue k)
    prepend x (Continue k) =
      k (Chunks (x ++ [flush])) >>== go
    prepend _  step = do
        liftIO finalizer
        returnI step
    go (Continue k) = do
      liftIO $ timeoutAction 10
      event <- liftIO $ timeout 9000000 source
      case fmap builder event of
        Just (Just b)  -> k (Chunks [b]) >>== go
        Just Nothing -> k EOF
        Nothing ->
          k (Chunks [fromJust . builder $ pingEvent]) >>== go
    go step = do
      liftIO finalizer
      returnI step


{-|
    Send a stream of events to the client. Takes a function to convert an
    event to a builder. If that function returns Nothing the stream is closed.
-}
eventStream :: [Builder] -> IO ServerEvent -> (ServerEvent -> Maybe Builder) -> IO () -> Snap ()
eventStream bufferEvents source builder finalizer = do
    timeoutAction <- getTimeoutAction
    modifyResponse $ setResponseBody $
        eventSourceEnum bufferEvents source builder timeoutAction finalizer


{-|
    Return a single response when the source returns an event. Takes a function
    used to convert the event to a builder.
-}
eventResponse :: [Builder] -> IO ServerEvent -> (ServerEvent -> Maybe Builder) -> IO () -> Snap ()
eventResponse [] source builder finalizer = do
    event <- liftIO $ source `onException` finalizer
    case builder event of
      Just b  -> writeBuilder b
      Nothing -> do
        liftIO finalizer
        response <- getResponse
        finishWith response
eventResponse buffer _ _ _ = mapM_ writeBuilder buffer


{-|
    Sets up this request to act as an event stream, obtaining its events from
    polling the given IO action.
-}
eventSourceStream :: Maybe [ServerEvent] -> IO ServerEvent -> IO () -> Snap ()
eventSourceStream buffer source finalizer = do
    modifyResponse $ setContentType "text/event-stream"
                   . setHeader "Cache-Control" "no-cache"
    eventStream (mapMaybe eventSourceBuilder $ bufferEvents buffer) source eventSourceBuilder finalizer
  where
    bufferEvents (Just []) = [pingEvent]
    bufferEvents (Just es) = es
    bufferEvents Nothing   = [pingEvent]


-- |Long polling fallback - sends a single response when an event is pulled
eventSourceResponse :: Maybe [ServerEvent] -> IO ServerEvent -> IO () -> Snap ()
eventSourceResponse buffer source finalizer = do
    modifyResponse $ setContentType "text/event-stream"
                   . setHeader "Cache-Control" "no-cache"
    eventResponse (bufferToBuilder buffer eventSourceBuilder) source eventSourceBuilder finalizer


eventSourceIframe :: Maybe [ServerEvent] -> IO ServerEvent -> IO () -> Snap ()
eventSourceIframe buffer source finalizer = do
    modifyResponse $ setContentType "text/html"
                   . setHeader "Cache-Control" "no-cache"
    eventStream header source scriptTagBuilder finalizer
  where
    header = iframeHead ++
            [fromString . replicate 4000 $ ' '] ++
            bufferToBuilder buffer scriptTagBuilder ++ [flush]


eventSourceScript :: Maybe [ServerEvent] -> IO ServerEvent -> IO () -> Snap ()
eventSourceScript buffer source finalizer = do
    modifyResponse $ setContentType "text/javascript"
                   . setHeader "Cache-Control" "no-cache"
    eventResponse (bufferToBuilder buffer scriptBuilder) source scriptBuilder finalizer
