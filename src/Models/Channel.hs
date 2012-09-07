{-# LANGUAGE OverloadedStrings #-}
module Models.Channel where

import           Prelude hiding (lookup)
import           Control.Monad.Instances()
import           Data.Text (Text)
import qualified Models.User as User
import           DB
import           Data.Bson


presence :: DB -> User.User -> Text -> IO (Either Failure [Text])
presence db user _ = do
    result <- run db $ distinct "presence_id" (select ["user_id" =: User.apiKey user] "connections")
    return . fmap (map typed) $ result
