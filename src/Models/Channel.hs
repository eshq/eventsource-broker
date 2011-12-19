{-# LANGUAGE OverloadedStrings #-}
module Models.Channel where

import           Prelude hiding (lookup)
import           Control.Monad.Instances
import           Data.UString (UString)
import qualified Data.UString as US
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import           Data.Digest.Pure.SHA (sha1)
import qualified Models.User as User
import           DB
import           Data.Bson


presence :: DB -> User.User -> UString -> IO (Either Failure [UString])
presence db user name = do
    result <- run db $ distinct "presence_id" (select ["user_id" =: User.apiKey user] "connections")
    return . fmap (map typed) $ result
