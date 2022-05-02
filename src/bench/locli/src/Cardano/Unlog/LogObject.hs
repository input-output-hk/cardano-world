{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-partial-fields -Wno-orphans #-}

module Cardano.Unlog.LogObject (module Cardano.Unlog.LogObject) where

import Prelude (String, error, head, id, show)
import Cardano.Prelude hiding (Text, head, show)

import Control.Monad (fail)
import Data.Aeson (FromJSON(..), ToJSON(..), Value(..), Object, (.:), (.:?))
import Data.Aeson qualified as AE
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Aeson.Types qualified as AE
import Data.Aeson.Key qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as LText
import Data.Text.Short qualified as Text
import Data.Text.Short (ShortText, fromText, toText)
import Data.Time.Clock (NominalDiffTime, UTCTime)
import Data.Map qualified as Map
import Data.Vector (Vector)
import Quiet (Quiet (..))

import Cardano.Logging.Resources.Types

import Cardano.Analysis.Ground
import Cardano.Util

import Data.Accum (zeroUTCTime)


type Text = ShortText

runLiftLogObjects :: [JsonLogfile]
                  -> ExceptT LText.Text IO [(JsonLogfile, [LogObject])]
runLiftLogObjects fs = liftIO $
  flip mapConcurrently fs
    (joinT . (pure &&& readLogObjectStream . unJsonLogfile))
 where
   joinT :: (IO a, IO b) -> IO (a, b)
   joinT (a, b) = (,) <$> a <*> b

readLogObjectStream :: FilePath -> IO [LogObject]
readLogObjectStream f =
  LBS.readFile f
    <&>
    fmap (either (LogObject zeroUTCTime "DecodeError" "" (TId "0") . LODecodeError)
                 id
          . AE.eitherDecode)
    . LBS.split (fromIntegral $ fromEnum '\n')

data LogObject
  = LogObject
    { loAt   :: !UTCTime
    , loKind :: !Text
    , loHost :: !Host
    , loTid  :: !TId
    , loBody :: !LOBody
    }
  deriving (Generic, Show)
  deriving anyclass NFData

instance ToJSON LogObject

instance Print ShortText where
  hPutStr   h = hPutStr   h . toText
  hPutStrLn h = hPutStrLn h . toText

newtype TId = TId { unTId :: ShortText }
  deriving (Eq, Generic, Ord)
  deriving newtype (FromJSON, ToJSON)
  deriving anyclass NFData
  deriving Show via Quiet TId

newtype Hash = Hash { unHash :: ShortText }
  deriving (Eq, Generic, Ord)
  deriving newtype (FromJSON, ToJSON)
  deriving anyclass NFData

shortHash :: Hash -> LText.Text
shortHash = toText . Text.take 6 . unHash

instance Show Hash where show = LText.unpack . toText . unHash

instance AE.ToJSONKey Hash where
  toJSONKey = AE.toJSONKeyText (toText . unHash)
instance AE.FromJSONKey Hash where
  fromJSONKey = AE.FromJSONKeyText (Hash . fromText)

newtype Host = Host { unHost :: ShortText }
  deriving (Eq, Generic, Ord)
  deriving newtype (IsString, FromJSON, ToJSON)
  deriving anyclass NFData
  deriving Show via Quiet Host

instance FromJSON BlockNo where
  parseJSON o = BlockNo <$> parseJSON o
instance ToJSON BlockNo where
  toJSON (BlockNo x) = toJSON x

deriving instance NFData a => NFData (Resources a)

--
-- LogObject stream interpretation
--

interpreters :: Map Text (Object -> Parser LOBody)
interpreters = Map.fromList
  [ (,) "TraceStartLeadershipCheck" $
    \v -> LOTraceStartLeadershipCheck
            <$> v .: "slot"
            <*> (v .:? "utxoSize"     <&> fromMaybe 0)
            <*> (v .:? "chainDensity" <&> fromMaybe 0)

  , (,) "TraceBlockContext" $
    \v -> LOBlockContext
            <$> v .: "tipBlockNo"

  , (,) "TraceNodeIsLeader" $
    \v -> LOTraceLeadershipDecided
            <$> v .: "slot"
            <*> pure True

  , (,) "TraceNodeNotLeader" $
    \v -> LOTraceLeadershipDecided
            <$> v .: "slot"
            <*> pure False

  , (,) "TraceMempoolAddedTx" $
    \v -> do
      x :: Object <- v .: "mempoolSize"
      LOMempoolTxs <$> x .: "numTxs"

  , (,) "TraceMempoolRemoveTxs" $
    \v -> do
      x :: Object <- v .: "mempoolSize"
      LOMempoolTxs <$> x .: "numTxs"

  , (,) "TraceMempoolRejectedTx" $
    \_ -> pure LOMempoolRejectedTx

  , (,) "TraceLedgerEvent.TookSnapshot" $
    \_ -> pure LOLedgerTookSnapshot

  , (,) "TraceBenchTxSubSummary" $
    \v -> do
       x :: Object <- v .: "summary"
       LOGeneratorSummary
         <$> ((x .: "ssFailures" :: Parser [Text])
              <&> null)
         <*> x .: "ssTxSent"
         <*> x .: "ssElapsed"
         <*> x .: "ssThreadwiseTps"

  , (,) "TraceBenchTxSubServAck" $
    \v -> LOTxsAcked <$> v .: "txIds"

  , (,) "Resources" $
    \v -> LOResources <$> parsePartialResourceStates (Object v)

  , (,) "TraceTxSubmissionCollected" $
    \v -> LOTxsCollected
            <$> v .: "count"

  , (,) "TraceTxSubmissionProcessed" $
    \v -> LOTxsProcessed
            <$> v .: "accepted"
            <*> v .: "rejected"

  , (,) "TraceForgedBlock" $
    \v -> LOBlockForged
            <$> v .: "block"
            <*> v .: "blockPrev"
            <*> v .: "blockNo"
            <*> v .: "slot"
  , (,) "TraceAddBlockEvent.AddedToCurrentChain" $
    \v -> LOBlockAddedToCurrentChain
            <$> ((v .: "newtip")     <&> hashFromPoint)
            <*> pure Nothing
            <*> (v .:? "chainLengthDelta"
                -- Compat for node versions 1.27 and older:
                 <&> fromMaybe 1)
  -- TODO: we should clarify the distinction between the two cases (^ and v).
  , (,) "TraceAdoptedBlock" $
    \v -> LOBlockAddedToCurrentChain
            <$> v .: "blockHash"
            <*> ((v .: "blockSize") <&> Just)
            <*> pure 1
  , (,) "ChainSyncServerEvent.TraceChainSyncServerRead.AddBlock" $
    \v -> LOChainSyncServerSendHeader
            <$> v .: "block"
            <*> v .: "blockNo"
            <*> v .: "slot"
  , (,) "ChainSyncServerEvent.TraceChainSyncServerReadBlocked.AddBlock" $
    \v -> LOChainSyncServerSendHeader
            <$> v .: "block"
            <*> v .: "blockNo"
            <*> v .: "slot"
  -- v, but not ^ -- how is that possible?
  , (,) "TraceBlockFetchServerSendBlock" $
    \v -> LOBlockFetchServerSending
            <$> v .: "block"
  , (,) "SendFetchRequest" $
    \v -> LOBlockFetchClientRequested
            <$> v .: "head"
            <*> v .: "length"
  , (,) "ChainSyncClientEvent.TraceDownloadedHeader" $
    \v -> LOChainSyncClientSeenHeader
            <$> v .: "block"
            <*> v .: "blockNo"
            <*> v .: "slot"
  , (,) "CompletedBlockFetch" $
    \v -> LOBlockFetchClientCompletedFetch
            <$> v .: "block"
  ]
 where
   hashFromPoint :: LText.Text -> Hash
   hashFromPoint = Hash . fromText . Prelude.head . LText.splitOn "@"

logObjectStreamInterpreterKeys :: [Text]
logObjectStreamInterpreterKeys = Map.keys interpreters

data LOBody
  = LOTraceStartLeadershipCheck !SlotNo !Word64 !Float
  | LOTraceLeadershipDecided    !SlotNo !Bool
  | LOResources !ResourceStats
  | LOMempoolTxs !Word64
  | LOMempoolRejectedTx
  | LOLedgerTookSnapshot
  | LOBlockContext !Word64
  | LOGeneratorSummary !Bool !Word64 !NominalDiffTime (Vector Float)
  | LOTxsAcked !(Vector Text)
  | LOTxsCollected !Word64
  | LOTxsProcessed !Word64 !Int
  | LOBlockForged
    { loBlock            :: !Hash
    , loPrev             :: !Hash
    , loBlockNo          :: !BlockNo
    , loSlotNo           :: !SlotNo
    }
  | LOBlockAddedToCurrentChain
    { loBlock            :: !Hash
    , loSize             :: !(Maybe Int)
    , loLength           :: !Int
    }
  | LOChainSyncServerSendHeader
    { loBlock            :: !Hash
    , loBlockNo          :: !BlockNo
    , loSlotNo           :: !SlotNo
    }
  | LOBlockFetchServerSending
    { loBlock            :: !Hash
    }
  | LOBlockFetchClientRequested
    { loBlock            :: !Hash
    , loLength           :: !Int
    }
  | LOChainSyncClientSeenHeader
    { loBlock            :: !Hash
    , loBlockNo          :: !BlockNo
    , loSlotNo           :: !SlotNo
    }
  | LOBlockFetchClientCompletedFetch
    { loBlock            :: !Hash
    }
  | LOAny !Object
  | LODecodeError !String
  deriving (Generic, Show)
  deriving anyclass NFData

instance ToJSON LOBody

instance FromJSON LogObject where
  parseJSON = AE.withObject "LogObject" $ \v -> do
    body :: Object <- v .: "data"
    -- XXX:  fix node causing the need for this workaround
    (,) unwrapped kind <- unwrap "credentials" "val" body
    LogObject
      <$> v .: "at"
      <*> pure kind
      <*> v .: "host"
      <*> v .: "thread"
      <*> case Map.lookup kind interpreters of
            Just interp -> interp unwrapped
            Nothing -> pure $ LOAny unwrapped
   where
     unwrap :: Text -> Text -> Object -> Parser (Object, Text)
     unwrap wrappedKeyPred unwrapKey v = do
       kind <- (fromText <$>) <$> v .:? "kind"
       wrapped   :: Maybe Text <-
         (fromText <$>) <$> v .:? Aeson.fromText (toText wrappedKeyPred)
       unwrapped :: Maybe Object <- v .:? Aeson.fromText (toText unwrapKey)
       case (kind, wrapped, unwrapped) of
         (Nothing, Just _, Just x) -> (,) <$> pure x <*> (fromText <$> x .: "kind")
         (Just kind0, _, _) -> pure (v, kind0)
         _ -> fail $ "Unexpected LogObject .data: " <> show v

extendObject :: Text -> Value -> Value -> Value
extendObject k v (Object hm) = Object $ hm <> KeyMap.singleton (Aeson.fromText $ toText k) v
extendObject k _ _ = error . Text.unpack $ "Summary key '" <> k <> "' does not serialise to an Object."

parsePartialResourceStates :: Value -> Parser (Resources Word64)
parsePartialResourceStates =
  AE.withObject "NodeSetup" $
    \o ->
      Resources
      <$> o .: "CentiCpu"
      <*> o .: "CentiGC"
      <*> o .: "CentiMut"
      <*> o .: "GcsMajor"
      <*> o .: "GcsMinor"
      <*> o .: "Alloc"
      <*> o .: "Live"
      <*> (o .:? "Heap" <&> fromMaybe 0)
      <*> o .: "RSS"
      <*> o .: "CentiBlkIO"
      <*> o .: "Threads"
