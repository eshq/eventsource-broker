{-# LANGUAGE OverloadedStrings #-}
module Models.Channel where

import           Prelude hiding (lookup)
import           Control.Monad.Instances()
import qualified Models.User as User
import           DB
import           Data.Bson


presence :: DB -> User.User -> UString -> IO (Either Failure [UString])
presence db user name = do
    result <- run db $ distinct "presence_id" (select ["user_id" =: User.apiKey user] "connections")
    return . fmap (map typed) $ result
