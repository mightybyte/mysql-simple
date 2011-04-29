{-# LANGUAGE CPP, DeriveDataTypeable, FlexibleInstances #-}

module Database.MySQL.Simple.Result
    (
      Result(..)
    , ResultError(..)
    ) where

#include "MachDeps.h"

import Control.Applicative ((<$>), (<*>), (<*), pure)
import Control.DeepSeq (NFData)
import Control.Exception (Exception, throw)
import Data.Attoparsec.Char8 hiding (Result)
import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import Data.Int (Int8, Int16, Int32, Int64)
import Data.List (foldl')
import Data.Ratio (Ratio)
import Data.Time.Calendar (Day, fromGregorian)
import Data.Time.Clock (UTCTime)
import Data.Time.Format (parseTime)
import Data.Time.LocalTime (TimeOfDay, makeTimeOfDayValid)
import Data.Typeable (TypeRep, Typeable, typeOf)
import Data.Word (Word, Word8, Word16, Word32, Word64)
import Database.MySQL.Base.Types (Field(..), Type(..))
import Database.MySQL.Simple.Orphans ()
import System.Locale (defaultTimeLocale)
import qualified Data.ByteString as SB
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as ST
import qualified Data.Text.Encoding as ST
import qualified Data.Text.Lazy as LT

data ResultError = Incompatible { errSourceType :: String
                                , errDestType :: String
                                , errMessage :: String }
                 | UnexpectedNull { errSourceType :: String
                                  , errDestType :: String
                                  , errMessage :: String }
                 | ConversionFailed { errSourceType :: String
                                    , errDestType :: String
                                    , errMessage :: String }
                   deriving (Eq, Show, Typeable)

instance Exception ResultError

class (NFData a) => Result a where
    convert :: Field -> Maybe ByteString -> a

instance (Result a) => Result (Maybe a) where
    convert _ Nothing = Nothing
    convert f bs      = Just (convert f bs)

instance Result Bool where
    convert = atto ok8 ((/=(0::Int)) <$> decimal)

instance Result Int8 where
    convert = atto ok8 $ signed decimal

instance Result Int16 where
    convert = atto ok16 $ signed decimal

instance Result Int32 where
    convert = atto ok32 $ signed decimal

instance Result Int where
    convert = atto okWord $ signed decimal

instance Result Int64 where
    convert = atto ok64 $ signed decimal

instance Result Integer where
    convert = atto ok64 $ signed decimal

instance Result Word8 where
    convert = atto ok8 decimal

instance Result Word16 where
    convert = atto ok16 decimal

instance Result Word32 where
    convert = atto ok32 decimal

instance Result Word where
    convert = atto okWord decimal

instance Result Word64 where
    convert = atto ok64 decimal

instance Result Float where
    convert = atto ok ((fromRational . toRational) <$> double)
        where ok = mkCompats [Float,Double,Decimal,NewDecimal]

instance Result Double where
    convert = atto ok double
        where ok = mkCompats [Float,Double,Decimal,NewDecimal]

instance Result (Ratio Integer) where
    convert = atto ok rational
        where ok = mkCompats [Float,Double,Decimal,NewDecimal]

instance Result SB.ByteString where
    convert f = doConvert f okText $ id

instance Result LB.ByteString where
    convert f = LB.fromChunks . (:[]) . convert f

instance Result ST.Text where
    convert f | isText f  = doConvert f okText $ ST.decodeUtf8
              | otherwise = incompatible f (typeOf ST.empty)
                            "attempt to mix binary and text"

instance Result LT.Text where
    convert f = LT.fromStrict . convert f

instance Result [Char] where
    convert f = ST.unpack . convert f

instance Result UTCTime where
    convert f = doConvert f ok $ \bs ->
                case parseTime defaultTimeLocale "%F %T" (B8.unpack bs) of
                  Just t -> t
                  Nothing -> conversionFailed f "UTCTime" "could not parse"
        where ok = mkCompats [DateTime,Timestamp]

instance Result Day where
    convert f = flip (atto ok) f $ case fieldType f of
                                     Year -> year
                                     _    -> date
        where ok = mkCompats [Year,Date,NewDate]
              year = fromGregorian <$> decimal <*> pure 1 <*> pure 1
              date = fromGregorian <$> (decimal <* char '-')
                                   <*> (decimal <* char '-')
                                   <*> decimal

instance Result TimeOfDay where
    convert f = flip (atto ok) f $ do
                hours <- decimal <* char ':'
                mins <- decimal <* char ':'
                secs <- decimal :: Parser Int
                case makeTimeOfDayValid hours mins (fromIntegral secs) of
                  Just t -> return t
                  _      -> conversionFailed f "TimeOfDay" "could not parse"
        where ok = mkCompats [Time]

isText :: Field -> Bool
isText f = fieldCharSet f /= 63

newtype Compat = Compat Word32
    
mkCompats :: [Type] -> Compat
mkCompats = foldl' f (Compat 0) . map mkCompat
  where f (Compat a) (Compat b) = Compat (a .|. b)

mkCompat :: Type -> Compat
mkCompat = Compat . shiftL 1 . fromEnum

compat :: Compat -> Compat -> Bool
compat (Compat a) (Compat b) = a .&. b /= 0

okText, ok8, ok16, ok32, ok64, okWord :: Compat
okText = mkCompats [VarChar,TinyBlob,MediumBlob,LongBlob,Blob,VarString,String,
                    Set,Enum]
ok8 = mkCompats [Tiny]
ok16 = mkCompats [Tiny,Short]
ok32 = mkCompats [Tiny,Short,Int24,Long]
ok64 = mkCompats [Tiny,Short,Int24,Long,LongLong]
#if WORD_SIZE_IN_BITS < 64
okWord = ok32
#else
okWord = ok64
#endif

doConvert :: (Typeable a) =>
             Field -> Compat -> (ByteString -> a) -> Maybe ByteString -> a
doConvert f types cvt (Just bs)
    | mkCompat (fieldType f) `compat` types = cvt bs
    | otherwise = incompatible f (typeOf (cvt undefined)) "types incompatible"
doConvert f _ cvt _ = throw $ UnexpectedNull (show (fieldType f))
                              (show (typeOf (cvt undefined))) ""

incompatible :: Field -> TypeRep -> String -> a
incompatible f r = throw . Incompatible (show (fieldType f)) (show r)

conversionFailed :: Field -> String -> String -> a
conversionFailed f s = throw . ConversionFailed (show (fieldType f)) s

atto :: (Typeable a) => Compat -> Parser a -> Field -> Maybe ByteString -> a
atto types p0 f = doConvert f types $ go undefined p0
  where
    go :: (Typeable a) => a -> Parser a -> ByteString -> a
    go dummy p s =
        case parseOnly p s of
          Left err -> conversionFailed f (show (typeOf dummy)) err
          Right v  -> v