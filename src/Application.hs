{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Application
  ( getApplicationDev
  , appMain
  , develMain
  , makeFoundation
  , makeLogWare
    -- * for DevelMain
  , getApplicationRepl
  , shutdownApp
    -- * for GHCI
  , handler
  , db
  , getDbConnectionString
  ) where

import           Control.Monad.Logger (liftLoc, runLoggingT)
import           Data.CSV.Conduit
import           Data.Vector ((!))
import           Database.Persist.Postgresql (createPostgresqlPool, pgConnStr, pgPoolSize,
                                              runSqlPool)
import           Import
import           Language.Haskell.TH.Syntax (qLocation)
import           Network.Wai (Middleware)
import           Network.Wai.Handler.Warp (Settings, defaultSettings, defaultShouldDisplayException,
                                           getPort, setHost, setOnException, setPort)
import           Network.Wai.Handler.WarpTLS
import           Network.Wai.Middleware.RequestLogger (Destination (Logger), IPAddrSource (..),
                                                       OutputFormat (..), destination,
                                                       mkRequestLogger, outputFormat)
import           System.Log.FastLogger (defaultBufSize, newStdoutLoggerSet, toLogStr)

import           Handler.About
import           Handler.Admin
import           Handler.Api
import           Handler.ApiUsers
import           Handler.Auth
import           Handler.Common
import           Handler.Company
import           Handler.CompanyDetails
import           Handler.CompanyList
import           Handler.Historical
import           Handler.Home
import           Handler.LogViewer
import           Handler.NewsletterManager
import           Handler.NewsletterNewUser
import           Handler.NewsletterSend
import           Handler.NewsletterSendt
import           Handler.Profile
import           Handler.SearchArticles
import           Handler.SearchCompanies
import           Handler.StoryDetails
import           Handler.StoryList
import           Helper.Fixtures as F
import           Helper.YahooHelper as YH

mkYesodDispatch "App" resourcesApp

makeFoundation :: AppSettings -> IO App
makeFoundation appSettings = do
  appHttpManager <- newManager
  appLogger <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
  appStatic <-
    (if appMutableStatic appSettings
       then staticDevel
       else static)
      (appStaticDir appSettings)
  let mkFoundation appConnPool = App {..}
      tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
      logFunc = messageLoggerSource tempFoundation appLogger
  pool <-
    flip runLoggingT logFunc $
    createPostgresqlPool
      (pgConnStr $ appDatabaseConf appSettings)
      (pgPoolSize $ appDatabaseConf appSettings)
  runLoggingT (runSqlPool (runMigration migrateAll) pool) logFunc
  return $ mkFoundation pool

makeApplication :: App -> IO Application
makeApplication foundation = do
  logWare <- makeLogWare foundation
  appPlain <- toWaiAppPlain foundation
  return $ logWare $ defaultMiddlewaresNoLogging appPlain

makeLogWare :: App -> IO Middleware
makeLogWare foundation =
  mkRequestLogger
    def
    { outputFormat =
        if appDetailedRequestLogging $ appSettings foundation
          then Detailed True
          else Apache
                 (if appIpFromHeader $ appSettings foundation
                    then FromFallback
                    else FromSocket)
    , destination = Logger $ loggerSet $ appLogger foundation
    }

-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
  setPort (appPort $ appSettings foundation) $
  setHost (appHost $ appSettings foundation) $
  setOnException
    (\_req e ->
       when (defaultShouldDisplayException e) $
       messageLoggerSource
         foundation
         (appLogger foundation)
         $(qLocation >>= liftLoc)
         "yesod"
         LevelError
         (toLogStr $ "Exception from Warp: " ++ show e))
    defaultSettings

mkCompany :: Vector ByteString -> UTCTime -> Company
mkCompany v now =
  Company
  { companyTitle = decodeUtf8 $ (!) v 1
  , companyWebsite = Just $ decodeUtf8 $ (!) v 6
  , companyDescription = Just $ decodeUtf8 $ (!) v 7
  , companyImage = Nothing
  , companyTicker = decodeUtf8 $ (!) v 0
  , companyGicssector = Just $ decodeUtf8 $ (!) v 2
  , companyGicssubindustry = Just $ decodeUtf8 $ (!) v 3
  , companyCreated = now
  }

insertCompanyIfNotInDB :: Int -> Vector (Vector ByteString) -> IO ()
insertCompanyIfNotInDB vecLen v = do
  now <- liftIO getCurrentTime
  if vecLen > 0
    then do
      let c = mkCompany ((!) v (vecLen)) now
      insertedCompany <-
        runDBA $ selectFirst [CompanyTicker ==. (companyTicker c)] []
      case insertedCompany of
        Nothing -> do
          _ <- runDBA $ insert c
          return ()
        Just (Entity cId dbCompany) -> do
          case (companyWebsite dbCompany) of
            Nothing -> do
              YH.writeYahooLog $ "[COMPANY INSERT] Update company data"
              _ <-
                runDBA $
                update
                  cId
                  [ CompanyWebsite =. (companyWebsite c)
                  , CompanyGicssector =. (companyGicssector c)
                  , CompanyGicssubindustry =. (companyGicssubindustry c)
                  ]
              return ()
            Just "" -> do
              YH.writeYahooLog $ "[COMPANY INSERT] Update company data "
              _ <-
                runDBA $
                update
                  cId
                  [ CompanyWebsite =. (companyWebsite c)
                  , CompanyGicssector =. (companyGicssector c)
                  , CompanyGicssubindustry =. (companyGicssubindustry c)
                  ]
              return ()
            Just _ -> return ()
      insertCompanyIfNotInDB (vecLen - 1) v
      return ()
    else YH.writeYahooLog $ "[COMPANY INSERT] Company insert finished"

readCompanyDataFromCSV :: IO ()
readCompanyDataFromCSV = do
  s <- readFile "csvCompanies.csv"
  let v =
        decodeCSV defCSVSettings s :: Either SomeException (Vector (Vector ByteString))
  case v of
    Left _ -> do
      YH.writeYahooLog $ "[COMPANY INSERT] No file found"
    Right a -> do
      let vectorLen = (length a) - 1
      insertCompanyIfNotInDB vectorLen a
      return ()

-- | For yesod devel, return the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
  settings <- getAppSettings
  foundation <- makeFoundation settings
  wsettings <- getDevSettings $ warpSettings foundation
  app <- makeApplication foundation
  F.runDeleteAdminsAction
  F.runInsertAdminsAction
  withAsync YH.fetchHistoricalData $ \_ -> do
      return ()
  withAsync readCompanyDataFromCSV $ \_ -> do
      return ()
  YH.writeYahooLog $ "[SYSTEM] development start!"
  return (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

tlsS :: TLSSettings
tlsS =
  tlsSettings
    "/etc/letsencrypt/live/investments-info.com/fullchain.pem"
    "/etc/letsencrypt/live/investments-info.com/privkey.pem"

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain = do
  settings <- loadYamlSettingsArgs [configSettingsYmlValue] useEnv
  foundation <- makeFoundation settings
  app <- makeApplication foundation
  F.runDeleteAdminsAction
  F.runInsertAdminsAction
  _ <- withAsync YH.fetchHistoricalData $ \_ -> do
      return ()
  _ <- withAsync readCompanyDataFromCSV $ \_ -> do
      return ()
  YH.writeYahooLog $ "[SYSTEM] production start!"
  runTLS tlsS (warpSettings foundation) app

--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
  settings <- getAppSettings
  foundation <- makeFoundation settings
  wsettings <- getDevSettings $ warpSettings foundation
  app1 <- makeApplication foundation
  return (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = return ()

---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------
-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= flip unsafeHandler h

-- | Run DB queries
db :: ReaderT SqlBackend (HandlerT App IO) a -> IO a
db = handler . runDB

getDbConnectionString :: IO ByteString
getDbConnectionString = do
  settings <- getAppSettings
  return $ pgConnStr $ appDatabaseConf settings
