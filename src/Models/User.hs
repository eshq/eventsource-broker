{-# LANGUAGE OverloadedStrings #-}
module Models.User where

import           Prelude hiding (lookup)
import           Data.ByteString (ByteString)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import           Data.Digest.Pure.SHA (sha1)
import           DB

data User = User { apiKey :: Text, apiSecret :: Text }

get :: DB -> Text -> IO (Either Failure (Maybe User))
get db key = do
    result <- run db $ findOne (select ["key" =: key] "users")
    return $ returnModel constructor result

authenticate :: User -> ByteString -> ByteString -> Bool 
authenticate user token timestamp =
    let key    = E.encodeUtf8 $ apiKey user
        secret = E.encodeUtf8 $ apiSecret user
        digest = sha1 $ LBS.fromChunks [key, ":", secret, ":", timestamp] in
    show digest == BS.unpack token

constructor :: Document -> User
constructor doc = User (at "key" doc) (at "secret" doc)
