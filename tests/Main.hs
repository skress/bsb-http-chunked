{-# language OverloadedStrings, MultiWayIf #-}
module Main where

import Data.Attoparsec.ByteString.Char8 (Parser, (<?>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Builder as BB
import Data.ByteString.Builder.HTTP.Chunked
import qualified Data.ByteString.Lazy as BL
import Data.Foldable
import Data.Functor
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Internal.Shrink as Shrink
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

main :: IO ()
main = defaultMain $ testGroup "properties" [testProperty "roundtrips" prop_roundtrips]
{-
main = do
  _ <- checkSequential $ Group "props" [("roundtrips", prop_roundtrips)]
  return ()
-}

prop_roundtrips :: Property
prop_roundtrips = property $ do
      lbs <- forAllWith (show . map showByteStringInternals . BL.toChunks) genLBS
      tripping lbs
               (BL.toChunks . BB.toLazyByteString . chunkedTransferEncoding . BB.lazyByteString)
               parseTransferChunks

showByteStringInternals :: ByteString -> String
showByteStringInternals (BSI.PS fptr off len) = "PS " ++ show fptr ++ " " ++ show off ++ " " ++ show len

genLBS :: Gen BL.ByteString
genLBS = Gen.shrink (map BL.fromChunks . Shrink.list . BL.toChunks) (Gen.prune (BL.fromChunks <$> genBSs))

genBSs :: Gen [ByteString]
genBSs = Gen.list (Range.linear 0 5) genSnippedBS

genSnippedBS :: Gen ByteString
genSnippedBS = do
  d <- Gen.int (Range.linear 0 5)
  e <- Gen.int (Range.linear 0 5)
  BS.drop d . dropEnd e <$> genPackedBS
  where
    dropEnd n bs = BS.take m bs
      where m = BS.length bs - n

genPackedBS :: Gen ByteString
genPackedBS = Gen.constant (BS.replicate 8161 95)
--genPackedBS = BS.pack <$> Gen.list (Range.linear 0 8160) (pure 95 {- '_' -}) -- 8161 is the first bad length



parseTransferChunks :: [ByteString] -> Either String BL.ByteString
parseTransferChunks = fmap (BL.fromChunks . concat) .
                      traverse (A.eitherResult . fmap toList . A.parse transferChunkParser)

-- Adapted from snap-server
transferChunkParser :: Parser (Maybe ByteString)
transferChunkParser = parser <?> "encodedChunkParser"
  where
    parser = do
        hex <- A.hexadecimal <?> "hexadecimal"
        -- skipWhile (/= '\r') <?> "skipToEOL" -- We don't add chunk extensions
        void crlf <?> "linefeed"
        if | hex >= mAX_CHUNK_SIZE
            -> fail $ "Chunk of size " ++ show hex ++
                 " is too long. Max chunk size is " ++ show mAX_CHUNK_SIZE
           | hex < 0
             -> fail $ "Negative chunk size: " ++ show hex
           | hex == 0
             -> (crlf >> return Nothing) <?> "terminal crlf after 0 length"
           | otherwise
             -> do
                x <- A.take hex <?> "reading data chunk"
                void crlf <?> "linefeed after data chunk"
                return $! Just x

    -- Chunks larger than this may indicate denial-of-service attack.
    mAX_CHUNK_SIZE = 2^(18::Int)

    crlf = A.string "\r\n"
