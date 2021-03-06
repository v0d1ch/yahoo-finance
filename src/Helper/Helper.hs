{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Helper.Helper where

import           Data.Hashable
import           Database.Persist.Sql (SqlBackend, rawSql, unSingle)
import           Import
import           Universum

truncateTables
  :: MonadIO m
  => ReaderT SqlBackend m [Text]
truncateTables = do
  result <- rawSql "DELETE FROM 'story';" []
  return (fmap unSingle result)

makeHash
  :: Hashable a
  => a -> Int
makeHash = hash

postsByPage :: Int
postsByPage = 10

calculatePreviousPage :: Int -> Int -> Page -> Maybe Int
calculatePreviousPage entries pageSize currentPage =
  if n <= entries && n > 0
    then Just n
    else Nothing
  where
    n = (pageSize * (currentPage - 1)) `div` pageSize

calculateNextPage :: Int -> Int -> Int -> Maybe Int
calculateNextPage entries pageSize currentPage =
  if n <= ((entries `div` pageSize) + 1) && n > 0
    then Just n
    else Nothing
  where
    n = (pageSize * (currentPage + 1)) `div` pageSize

-- | Read AWS keys from settings.yml
getAwsKey
  :: MonadIO m
  => Text -> m Text
getAwsKey t = do
  settings <- liftIO $ loadYamlSettings ["config/settings.yml"] [] useEnv
  case t of
    "awsAccessKey"      -> return $ fromMaybe "" (awsAccessKey settings)
    "awsSecretKey"      -> return $ fromMaybe "" (awsSecretKey settings)
    "awsSesAccessKey"   -> return $ fromMaybe "" (awsSesAccessKey settings)
    "awsSesSecretKey"   -> return $ fromMaybe "" (awsSesSecretKey settings)
    "mailchimp-api-key" -> return $ fromMaybe "" (mailchimpApiKey settings)

    _                   -> error "no such key in settings file!"

-- | Read admin users from settings.yml
getAdmins
  :: MonadIO m
  => m (Maybe [AdminUsers])
getAdmins = do
  settings <- liftIO $ loadYamlSettings ["config/settings.yml"] [] useEnv
  return $ administrators settings
