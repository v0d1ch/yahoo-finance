{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}

module Handler.Sessions where

import           Control.Monad.Trans.Maybe
import           Data.Map (lookup)
import           Data.Time
import           Data.Time.Clock (addUTCTime)
import           Import.NoFoundation
import           Safe
import           Universum hiding (get, Key)
import           Yesod.Core
import           Yesod.Persist.Core

type YesodLog site = (Yesod site)

userSess :: Text
userSess = "user_id"

rememberSess :: Text
rememberSess = "remember_me"

timestampSess :: Text
timestampSess = "time_created"

setUserSession :: Key User -> Bool -> HandlerT site IO ()
setUserSession keyUser rememberMe = do
  setSession userSess (toPathPiece keyUser)
  if rememberMe
    then setSession rememberSess "True"
    else deleteSession rememberSess
  t <- liftIO getCurrentTime
  setSession timestampSess (toPathPiece (SessionTime t))
  pass

newtype SessionTime =
    SessionTime UTCTime
     deriving (Eq, Read, Show)

instance PathPiece SessionTime where
    fromPathPiece = readMay . toString
    toPathPiece = show

sessionTooOld :: UTCTime -> HandlerT site IO Bool
sessionTooOld currentTime = do
    remember <- getSessionKey rememberSess
    timestamp <- getSessionKey timestampSess
    case timestamp >>= (fromPathPiece . decodeUtf8) of
        Nothing -> return True
        (Just (SessionTime t))
        -- no remember flag, so should only last 2 hours
         -> do
            let shortLife = 60 * 60 * 2
                -- shortLife = 5 -- for testing
                -- there was a remember flag, so we give it 1 month
                longLife = 60 * 60 * 24 * 30
                secondsToLast = maybe shortLife (const longLife) remember
                deadline = addUTCTime secondsToLast t
            -- if currentTime is greater than the
            -- session deadline, it's too old.
            return (currentTime > deadline)

sessionMiddleware :: HandlerT site IO resp -> HandlerT site IO resp
sessionMiddleware handler = do
    t <- liftIO getCurrentTime
    tooOld <- sessionTooOld t
    if tooOld
        then deleteLoginData >> handler
        else handler

getSessionKey
    :: Text -> HandlerT site IO (Maybe ByteString)
getSessionKey k = do
    sess <- getSession
    return $ lookup k sess

getSessionUserK :: HandlerT site IO (Maybe ByteString)
getSessionUserK = getSessionKey userSess

handleDumpSessionR :: HandlerT site IO Text
handleDumpSessionR = show <$> getSession

deleteLoginData :: HandlerT site IO ()
deleteLoginData = do
  deleteSession userSess
  deleteSession rememberSess
  deleteSession timestampSess

getUserKey :: HandlerT site IO (Maybe (Key User))
getUserKey =
    runMaybeT $
    do userId <- MaybeT getSessionUserK
       userInt <- justZ $ fromPathPiece (decodeUtf8 userId)
       return (toSqlKey userInt)

getUser
    :: (YesodPersist site, YesodPersistBackend site ~ SqlBackend)
    => HandlerT site IO (Maybe (Entity User))
getUser =
    runMaybeT $
    do userKey <- MaybeT getUserKey
       user <- MaybeT $ runDB $ get userKey
       return $ Entity userKey user

requireAdmin :: (YesodPersist site, YesodPersistBackend site ~ SqlBackend)
             => HandlerT site IO (Entity User, Entity Admin)
requireAdmin = do
  maybeUser <- getUser
  case maybeUser of
    Nothing -> notAuthenticated
    (Just user) -> do
      maybeAdmin <- runDB $ selectFirst [AdminAccount ==. entityKey user] []
      case maybeAdmin of
        Nothing      -> permissionDenied "You are not an administrator"
        (Just admin) -> return (user, admin)
