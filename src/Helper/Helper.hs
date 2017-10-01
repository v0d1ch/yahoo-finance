{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
module Helper.Helper where

import Database.Persist.Sql  (SqlBackend, rawSql, unSingle)
import Data.Text (Text)
import Data.Hashable
import Import
import LibYahoo (getYahooData)
-- import qualified Data.CSV.Conduit as CC hiding (CSV)
import Data.CSV.Conduit.Conversion
import Control.Monad (mzero)
-- import qualified Data.Text.Encoding as T
-- import           Data.Time.Clock (UTCTime)
import           Data.Time.Format
-- import qualified Data.Vector as V
import qualified Data.ByteString               as B
-- import qualified Data.ByteString.Internal      as BI
-- import qualified Data.ByteString.Lazy          as BL
-- import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Lazy.Char8 as C
import Data.List.Split
import Control.Monad.Trans.Maybe

companyCodes :: [String]
companyCodes = ["KO", "AAPL"]

truncateTables :: MonadIO m => ReaderT SqlBackend m [Text]
truncateTables = do
  result <- rawSql "DELETE FROM 'story';" []
  return (fmap unSingle result)

makeHash :: Hashable a => a -> Int
makeHash s = hash s

 ------------------------------------------------------------------------------------------------------

data YahooData = YahooData
  { yahooDataDate :: !B.ByteString
  , yahooDataOpen :: !B.ByteString
  , yahooDataHigh :: !B.ByteString
  , yahooDataLow :: !B.ByteString
  , yahooDataClose :: !B.ByteString
  , yahooDataAdjClose :: !B.ByteString
  , yahooDataVolume :: !B.ByteString
  } deriving (Show, Eq)

-- instance FromField YahooData where
--     parseField s
--         | B.null s  = pure ""
--         | otherwise = YahooData <$> parseField s


instance FromRecord YahooData where
  parseRecord v
    | length v == 7 =
      YahooData <$> v .! 0 <*> v .! 1 <*> v .! 2 <*> v .! 3 <*> v .! 4 <*>
      v .! 5 <*>
      v .! 6
    | otherwise = mzero

instance ToRecord YahooData where
  toRecord (YahooData yahooDataDate yahooDataOpen yahooDataHigh yahooDataLow yahooDataClose yahooDataAdjClose yahooDataVolume) =
    record
      [ toField yahooDataDate
      , toField yahooDataOpen
      , toField yahooDataHigh
      , toField yahooDataLow
      , toField yahooDataClose
      , toField yahooDataAdjClose
      , toField yahooDataVolume
      ]

readToType :: String -> IO [Parser YahooData]
readToType ticker = do
  yd <- liftIO $ getYahooData ticker
  let charList = lines $ C.unpack yd
  let charListofLists = fmap (splitOn ",") charList
  let bslListofLists = (fmap . fmap) C.pack charListofLists
  let bsListofLists = (fmap . fmap) toStrict1 bslListofLists
  let recordsList = fmap record bsListofLists
  return $ fmap parseRecord recordsList

-- example
printYlist = do
  pl <- readToType "AAPL"
  let yl = fmap runParser pl
  print yl

toStrict1 :: C.ByteString -> B.ByteString
toStrict1 = B.concat . C.toChunks


parseTimestamp ::
     (Monad m, ParseTime t)
  => String -- ^ Format string
  -> String -- ^ Input string
  -> m t
parseTimestamp = parseTimeM True defaultTimeLocale
