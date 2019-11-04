{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Ouroboros.Consensus.Ledger.Byron
  ( -- * Byron blocks and headers
    ByronHash (..)
  , annotateByronBlock
    -- * Mempool integration
  , GenTx (..)
  , GenTxId (..)
  , ByronApplyTxError (..)
  , mkByronGenTx
    -- * Block Fetch integration
  , byronBlockMatchesHeader
    -- * Ledger
  , LedgerState (..)
  , LedgerConfig (..)
    -- * Config
  , ByronConsensusProtocol
    -- * Serialisation
  , encodeByronHeader
  , encodeByronBlock
  , encodeByronHeaderHash
  , encodeByronGenTx
  , encodeByronGenTxId
  , encodeByronLedgerState
  , encodeByronChainState
  , encodeByronApplyTxError
  , decodeByronHeader
  , decodeByronBlock
  , decodeByronHeaderHash
  , decodeByronGenTx
  , decodeByronGenTxId
  , decodeByronLedgerState
  , decodeByronChainState
  , decodeByronApplyTxError
    -- When adding a new en/decoder, add a test for it in
    -- Test.Consensus.Ledger.Byron

    -- * EBBs
  , ByronBlock(..)
  , pattern ByronHeaderRegular
  , pattern ByronHeaderBoundary
  , mkByronHeader
  , mkByronBlock
  , annotateBoundary
  , fromCBORAHeaderOrBoundary
  ) where

import           Cardano.Prelude (Word32, Word8, cborError, wrapError)

import           Codec.CBOR.Decoding (Decoder)
import qualified Codec.CBOR.Decoding as CBOR
import           Codec.CBOR.Encoding (Encoding)
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Write as CBOR
import           Codec.Serialise (decode, encode)
import           Control.Monad.Except
import           Control.Monad.Trans.Reader (runReaderT)
import           Data.Bifunctor (bimap)
import qualified Data.Bimap as Bimap
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.Coerce (coerce)
import           Data.Either (isRight)
import           Data.FingerTree.Strict (Measured (..))
import           Data.Foldable (find, foldl')
import qualified Data.Sequence.Strict as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Typeable
import           Formatting
import           GHC.Generics (Generic)

import           Cardano.Binary (Annotated (..), ByteSpan, Decoded (..),
                     DecoderError (..), FromCBOR (..), ToCBOR (..),
                     enforceSize, fromCBOR, reAnnotate, serialize, slice,
                     toCBOR, unsafeDeserialize)
import qualified Cardano.Chain.Block as CC.Block
import qualified Cardano.Chain.Common as CC.Common
import qualified Cardano.Chain.Delegation as CC.Delegation
import qualified Cardano.Chain.Delegation.Validation.Interface as V.Interface
import qualified Cardano.Chain.Delegation.Validation.Scheduling as V.Scheduling
import qualified Cardano.Chain.Genesis as CC.Genesis
import qualified Cardano.Chain.MempoolPayload as CC.Mempool
import qualified Cardano.Chain.Slotting as CC.Slot
import qualified Cardano.Chain.Update.Proposal as CC.Update.Proposal
import qualified Cardano.Chain.Update.Validation.Interface as CC.UPI
import qualified Cardano.Chain.Update.Vote as CC.Update.Vote
import qualified Cardano.Chain.UTxO as CC.UTxO
import           Cardano.Chain.ValidationMode (ValidationMode (..),
                     fromBlockValidationMode)
import qualified Cardano.Crypto as Crypto
import           Cardano.Crypto.DSIGN
import           Cardano.Crypto.Hash
import           Cardano.Prelude (NoUnexpectedThunks (..),
                     UseIsNormalFormNamed (..))

import           Ouroboros.Network.Block
import           Ouroboros.Network.Point (WithOrigin (..))
import qualified Ouroboros.Network.Point as Point (block, origin)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Crypto.DSIGN.Cardano
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Byron.Config
import           Ouroboros.Consensus.Ledger.Byron.ContainsGenesis
import           Ouroboros.Consensus.Ledger.Byron.Orphans ()
import           Ouroboros.Consensus.Mempool.API
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Protocol.PBFT
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.SlotBounded (SlotBounded (..))
import qualified Ouroboros.Consensus.Util.SlotBounded as SB

type ByronConsensusProtocol = PBft ByronConfig PBftCardanoCrypto

{-------------------------------------------------------------------------------
  Header hash
-------------------------------------------------------------------------------}

newtype ByronHash = ByronHash { unByronHash :: CC.Block.HeaderHash }
  deriving stock   (Eq, Ord, Show, Generic)
  deriving newtype (ToCBOR, FromCBOR)
  deriving anyclass NoUnexpectedThunks

instance Condense ByronHash where
  condense = formatToString CC.Block.headerHashF . unByronHash

{-------------------------------------------------------------------------------
  Ledger
-------------------------------------------------------------------------------}

pbftLedgerView :: CC.Block.ChainValidationState
               -> PBftLedgerView PBftCardanoCrypto
pbftLedgerView = PBftLedgerView
               . CC.Delegation.unMap
               . V.Interface.delegationMap
               . CC.Block.cvsDelegationState

allowedDelegators :: CC.Genesis.Config -> Set CC.Common.KeyHash
allowedDelegators
  = CC.Genesis.unGenesisKeyHashes
  . CC.Genesis.configGenesisKeyHashes

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

convertSlot :: CC.Slot.SlotNumber -> SlotNo
convertSlot = coerce

{-------------------------------------------------------------------------------
  Epoch Boundary Blocks
-------------------------------------------------------------------------------}

data ByronBlock = ByronBlock
  { bbRaw    :: !(CC.Block.ABlockOrBoundary ByteString)
  , bbSlotNo :: !SlotNo
  , bbHash   :: !ByronHash
  } deriving (Eq, Show)

-- | Internal: construct @Header ByronBlock@ with known hash
--
-- This is useful when we are constructing a header from a @ByronBlock@, where
-- we cache the cache.
--
-- NOTE: The @slotNo@ should correspond to the one that we can compute from the
-- header (using 'computeHeaderSlot') -- except we can't actually /do/ that
-- conversion here since we'd need the know @epochSlots@ for that.
mkByronHeader' :: SlotNo
               -> ByronHash
               -> Either (CC.Block.ABoundaryHeader ByteString)
                         (CC.Block.AHeader         ByteString)
               -> Header ByronBlock
mkByronHeader' slotNo hdrHash header = case header of
    Left ebb -> ByronHeaderBoundary ebb slotNo hdrHash
    Right mb -> ByronHeaderRegular  mb  slotNo hdrHash

mkByronHash :: Either (CC.Block.ABoundaryHeader ByteString)
                      (CC.Block.AHeader ByteString)
            -> ByronHash
mkByronHash (Left ebb) = ByronHash $ CC.Block.boundaryHeaderHashAnnotated ebb
mkByronHash (Right mb) = ByronHash $ CC.Block.headerHashAnnotated mb

mkByronHeader :: CC.Slot.EpochSlots
              -> Either (CC.Block.ABoundaryHeader ByteString)
                        (CC.Block.AHeader         ByteString)
              -> Header ByronBlock
mkByronHeader epochSlots header =
    mkByronHeader' slotNo hdrHash header
  where
    slotNo  = computeHeaderSlot epochSlots header
    hdrHash = mkByronHash header

-- | Internal: compute the slot number of a Byron header
computeHeaderSlot :: CC.Slot.EpochSlots
                  -> Either (CC.Block.ABoundaryHeader a) (CC.Block.AHeader a)
                  -> SlotNo
computeHeaderSlot _ (Right hdr) =
    convertSlot $ CC.Block.headerSlot hdr
computeHeaderSlot epochSlots (Left hdr) =
    SlotNo $ CC.Slot.unEpochSlots epochSlots * CC.Block.boundaryEpoch hdr

instance GetHeader ByronBlock where
  data Header ByronBlock =
        ByronHeaderRegular  !(CC.Block.AHeader         ByteString) !SlotNo !ByronHash
      | ByronHeaderBoundary !(CC.Block.ABoundaryHeader ByteString) !SlotNo !ByronHash
      deriving (Eq, Show, Generic)

  getHeader (ByronBlock (CC.Block.ABOBBlock b) slotNo hdrHash) =
      ByronHeaderRegular (CC.Block.blockHeader b) slotNo hdrHash
  getHeader (ByronBlock (CC.Block.ABOBBoundary b) slotNo hdrHash) =
      ByronHeaderBoundary (CC.Block.boundaryHeader b) slotNo hdrHash

type instance HeaderHash ByronBlock = ByronHash

instance NoUnexpectedThunks (Header ByronBlock) where
  showTypeOf _ = show $ typeRep (Proxy @(Header ByronBlock))

instance SupportedBlock ByronBlock

instance HasHeader ByronBlock where
  blockHash      =            blockHash     . getHeader
  blockPrevHash  = castHash . blockPrevHash . getHeader
  blockSlot      =            blockSlot     . getHeader
  blockNo        =            blockNo       . getHeader
  blockInvariant = const True

instance HasHeader (Header ByronBlock) where
  blockHash (ByronHeaderRegular  _ _ h) = h
  blockHash (ByronHeaderBoundary _ _ h) = h

  blockPrevHash (ByronHeaderRegular mb _ _) =
      BlockHash . ByronHash . CC.Block.headerPrevHash $ mb
  blockPrevHash (ByronHeaderBoundary ebb _ _) =
      case CC.Block.boundaryPrevHash ebb of
        Left _  -> GenesisHash
        Right h -> BlockHash (ByronHash h)

  blockSlot (ByronHeaderRegular  _ slotNo _) = slotNo
  blockSlot (ByronHeaderBoundary _ slotNo _) = slotNo

  blockNo (ByronHeaderRegular mb _ _) =
        BlockNo
      . CC.Common.unChainDifficulty
      . CC.Block.headerDifficulty
      $ mb
  blockNo (ByronHeaderBoundary ebb _ _) =
        BlockNo
      . CC.Common.unChainDifficulty
      . CC.Block.boundaryDifficulty
      $ ebb

  blockInvariant = const True

instance Measured BlockMeasure ByronBlock where
  measure = blockMeasure

instance StandardHash ByronBlock

instance HeaderSupportsPBft ByronConfig PBftCardanoCrypto (Header ByronBlock) where
  type OptSigned (Header ByronBlock) = Annotated CC.Block.ToSign ByteString

  headerPBftFields _   (ByronHeaderBoundary{}) = Nothing
  headerPBftFields cfg (ByronHeaderRegular hdr _ _) = Just (
        PBftFields {
          pbftIssuer    = VerKeyCardanoDSIGN
                        . CC.Delegation.delegateVK
                        . CC.Block.delegationCertificate
                        . CC.Block.headerSignature
                        $ hdr
        , pbftGenKey    = VerKeyCardanoDSIGN
                        . CC.Block.headerGenesisKey
                        $ hdr
        , pbftSignature = SignedDSIGN
                        . SigCardanoDSIGN
                        . CC.Block.signature
                        . CC.Block.headerSignature
                        $ hdr
        }
      , CC.Block.recoverSignedBytes epochSlots hdr
      )
    where
      epochSlots = pbftEpochSlots $ pbftExtConfig cfg

type instance BlockProtocol ByronBlock = ByronConsensusProtocol

instance UpdateLedger ByronBlock where

  data LedgerState ByronBlock = ByronLedgerState
      { blsCurrent :: !CC.Block.ChainValidationState
        -- | Slot-bounded snapshots of the chain state
      , blsSnapshots :: !(Seq.StrictSeq (SlotBounded (PBftLedgerView PBftCardanoCrypto)))
      }
    deriving (Eq, Show, Generic)

  type LedgerError ByronBlock = CC.Block.ChainValidationError

  newtype LedgerConfig ByronBlock = ByronLedgerConfig {
      unByronLedgerConfig :: CC.Genesis.Config
    }

  ledgerConfigView PBftNodeConfig{..} = ByronLedgerConfig $
      pbftGenesisConfig pbftExtConfig

  applyChainTick (ByronLedgerConfig cfg) slotNo
                 (ByronLedgerState state snapshots) = do
      let updateState' = CC.Block.epochTransition
            epochEnv
            (CC.Block.cvsUpdateState state)
            (coerce slotNo)
      let state' = state { CC.Block.cvsUpdateState = updateState' }
      return $ ByronLedgerState state' snapshots
    where
      epochEnv = CC.Block.EpochEnvironment
        { CC.Block.protocolMagic = fixPMI $ CC.Genesis.configProtocolMagicId cfg
        , CC.Block.k             = CC.Genesis.configK cfg
        , CC.Block.allowedDelegators = allowedDelegators cfg
        , CC.Block.delegationMap = delegationMap
        , CC.Block.currentEpoch  = CC.Slot.slotNumberEpoch
                                     (CC.Genesis.configEpochSlots cfg)
                                     (CC.Block.cvsLastSlot state)
        }
      delegationMap = V.Interface.delegationMap
                    $ CC.Block.cvsDelegationState state

      fixPMI pmi = reAnnotate $ Annotated pmi ()

  applyLedgerBlock = applyByronLedgerBlock
    (fromBlockValidationMode CC.Block.BlockValidation)

  reapplyLedgerBlock cfg blk st =
    let validationMode = fromBlockValidationMode CC.Block.NoBlockValidation
    -- Given a 'BlockValidationMode' of 'NoBlockValidation', a call to
    -- 'applyByronLedgerBlock' shouldn't fail since the ledger layer
    -- won't be performing any block validation checks.
    -- However, because 'applyByronLedgerBlock' can fail in the event it
    -- is given a 'BlockValidationMode' of 'BlockValidation', it still /looks/
    -- like it can fail (since its type doesn't change based on the
    -- 'ValidationMode') and we must still treat it as such.
    in case runExcept (applyByronLedgerBlock validationMode cfg blk st) of
      Left  err -> error ("reapplyLedgerBlock: unexpected error: " <> show err)
      Right st' -> st'

  ledgerTipPoint (ByronLedgerState state _) = case CC.Block.cvsPreviousHash state of
      -- In this case there are no blocks in the ledger state. The genesis
      -- block does not occupy a slot, so its point is Origin.
      Left _genHash -> Point Point.origin
      Right hdrHash -> Point (Point.block slot (ByronHash hdrHash))
        where
          slot = convertSlot (CC.Block.cvsLastSlot state)

instance NoUnexpectedThunks (LedgerState ByronBlock)
  -- use generic instance

instance ConfigContainsGenesis (LedgerConfig ByronBlock) where
  genesisConfig = unByronLedgerConfig

applyABlock :: ValidationMode
            -> CC.Genesis.Config
            -> CC.Block.ABlock ByteString
            -> CC.Block.HeaderHash
            -> LedgerState (ByronBlock)
            -> Except (LedgerError ByronBlock)
                      (LedgerState ByronBlock)
applyABlock validationMode
            cfg
            block
            blkHash
            (ByronLedgerState state snapshots) = do
    runReaderT
      (CC.Block.headerIsValid
        (CC.Block.cvsUpdateState state)
        (CC.Block.blockHeader block)
      )
      validationMode
    CC.Block.BodyState { CC.Block.utxo, CC.Block.updateState
                        , CC.Block.delegationState }
      <- runReaderT
          (CC.Block.updateBody bodyEnv bodyState block)
          validationMode
    let state' = state
          { CC.Block.cvsLastSlot        = CC.Block.blockSlot block
          , CC.Block.cvsPreviousHash    = Right blkHash
          , CC.Block.cvsUtxo            = utxo
          , CC.Block.cvsUpdateState     = updateState
          , CC.Block.cvsDelegationState = delegationState
          }
        snapshots'
            | CC.Block.cvsDelegationState state' ==
                CC.Block.cvsDelegationState state
            = snapshots
            | otherwise
            = snapshots Seq.|>
              SB.bounded startOfSnapshot slot (pbftLedgerView state')
          where
            startOfSnapshot = case snapshots of
              _ Seq.:|> a -> sbUpper a
              Seq.Empty   -> SlotNo 0
            slot = convertSlot $ CC.Block.blockSlot block
    return $ ByronLedgerState state' (trimSnapshots snapshots')
  where
    bodyState = CC.Block.BodyState
      { CC.Block.utxo            = CC.Block.cvsUtxo state
      , CC.Block.updateState     = CC.Block.cvsUpdateState state
      , CC.Block.delegationState = CC.Block.cvsDelegationState state
      }
    bodyEnv = CC.Block.BodyEnvironment
      { CC.Block.protocolMagic      = fixPM $ CC.Genesis.configProtocolMagic cfg
      , CC.Block.utxoConfiguration  = CC.Genesis.configUTxOConfiguration cfg
      , CC.Block.k                  = CC.Genesis.configK cfg
      , CC.Block.allowedDelegators  = allowedDelegators cfg
      , CC.Block.protocolParameters = protocolParameters
      , CC.Block.currentEpoch       = CC.Slot.slotNumberEpoch
                                        (CC.Genesis.configEpochSlots cfg)
                                        (CC.Block.blockSlot block)
      }

    protocolParameters = CC.UPI.adoptedProtocolParameters . CC.Block.cvsUpdateState
                        $ state

    fixPM (Crypto.AProtocolMagic a b) = Crypto.AProtocolMagic (reAnnotate a) b

    k = CC.Genesis.configK cfg

    trimSnapshots = Seq.dropWhileL $ \ss ->
      sbUpper ss < convertSlot (CC.Block.blockSlot block) - 2 * coerce k

applyByronLedgerBlock :: ValidationMode
                      -> LedgerConfig ByronBlock
                      -> ByronBlock
                      -> LedgerState ByronBlock
                      -> Except (LedgerError ByronBlock)
                                (LedgerState ByronBlock)
applyByronLedgerBlock validationMode
                      (ByronLedgerConfig cfg)
                      (ByronBlock blk _ (ByronHash blkHash))
                      bs@(ByronLedgerState state snapshots) =
    case blk of
      CC.Block.ABOBBlock b ->
          applyABlock validationMode cfg b blkHash bs
      CC.Block.ABOBBoundary b ->
          return ByronLedgerState {
              blsCurrent = state {
                  CC.Block.cvsPreviousHash = Right blkHash
                , CC.Block.cvsLastSlot = CC.Slot.SlotNumber $ epochSlots * CC.Block.boundaryEpoch hdr
                }
            , blsSnapshots = snapshots
            }
        where
          hdr = CC.Block.boundaryHeader b
          CC.Slot.EpochSlots epochSlots = CC.Genesis.configEpochSlots cfg

mkByronBlock :: CC.Slot.EpochSlots
             -> CC.Block.ABlockOrBoundary ByteString
             -> ByronBlock
mkByronBlock epochSlots blk = ByronBlock {
      bbRaw    = blk
    , bbSlotNo = computeHeaderSlot epochSlots hdr
    , bbHash   = mkByronHash hdr
    }
  where
    hdr = mkBlockOrBoundaryHeader blk

mkBlockOrBoundaryHeader :: CC.Block.ABlockOrBoundary a
                        -> Either (CC.Block.ABoundaryHeader a)
                                  (CC.Block.AHeader a)
mkBlockOrBoundaryHeader blk = case blk of
    CC.Block.ABOBBlock    blk' -> Right $ CC.Block.blockHeader    blk'
    CC.Block.ABOBBoundary blk' -> Left  $ CC.Block.boundaryHeader blk'

-- | Construct Byron block from unannotated 'CC.Block.Block'
--
-- This should be used only when forging blocks (not when receiving blocks
-- over the wire).
annotateByronBlock :: CC.Slot.EpochSlots -> CC.Block.Block -> ByronBlock
annotateByronBlock epochSlots =
      mkByronBlock epochSlots
    . CC.Block.ABOBBlock
    . annotateBlock epochSlots

{-------------------------------------------------------------------------------
  Condense instances
-------------------------------------------------------------------------------}

instance Condense ByronBlock where
  condense (ByronBlock (CC.Block.ABOBBlock blk) _slotNo (ByronHash hdrHash)) =
      "(header: " <> condenseAHeader (CC.Block.blockHeader blk) hdrHash <>
      ", body: "  <> condenseABlock blk  <>
      ")"
  condense (ByronBlock (CC.Block.ABOBBoundary ebb) _ _) =
      condenseABoundaryBlock ebb

condenseABlock :: CC.Block.ABlock ByteString -> String
condenseABlock = T.unpack
               . sformat build
               . CC.UTxO.txpTxs
               . CC.Block.bodyTxPayload
               . CC.Block.blockBody

condenseAHeader :: CC.Block.AHeader ByteString -> CC.Block.HeaderHash -> String
condenseAHeader hdr hdrHash =
    "(hash: "          <> condensedHash        <>
    ", previousHash: " <> condensedPrevHash    <>
    ", slot: "         <> condensedSlot        <>
    ", issuer: "       <> condenseKey issuer   <>
    ", delegate: "     <> condenseKey delegate <>
    ")"
  where
    psigCert = CC.Block.delegationCertificate
             . CC.Block.headerSignature
             $ hdr
    issuer   = CC.Delegation.issuerVK   psigCert
    delegate = CC.Delegation.delegateVK psigCert

    condenseKey :: Crypto.VerificationKey -> String
    condenseKey = T.unpack . sformat build

    condensedHash
      = T.unpack
      . sformat CC.Block.headerHashF
      $ hdrHash

    condensedPrevHash
      = T.unpack
      . sformat CC.Block.headerHashF
      . CC.Block.headerPrevHash
      $ hdr

    condensedSlot
      = T.unpack
      . sformat build
      . unAnnotated
      . CC.Block.aHeaderSlot
      $ hdr

condenseABoundaryBlock :: CC.Block.ABoundaryBlock ByteString -> String
condenseABoundaryBlock CC.Block.ABoundaryBlock{boundaryHeader} =
  condenseABoundaryHeader boundaryHeader

condenseABoundaryHeader :: CC.Block.ABoundaryHeader ByteString -> String
condenseABoundaryHeader hdr =
    "( ebb: true" <>
    ", hash: " <> condensedHash <>
    ", previousHash: " <> condensedPrevHash <>
    ")"
  where
    condensedHash
      = T.unpack
      . sformat CC.Block.headerHashF
      . coerce
      . Crypto.hashDecoded . fmap CC.Block.wrapBoundaryBytes
      $ hdr

    condensedPrevHash
      = T.unpack $ case CC.Block.boundaryPrevHash hdr of
          Left _  -> "Genesis"
          Right h -> sformat CC.Block.headerHashF h

instance Condense (Header ByronBlock) where
  condense (ByronHeaderRegular hdr _ (ByronHash hdrHash)) =
      condenseAHeader hdr hdrHash
  condense (ByronHeaderBoundary hdr _ _) =
      condenseABoundaryHeader hdr

instance Condense (ChainHash ByronBlock) where
  condense GenesisHash   = "genesis"
  condense (BlockHash h) = condense h

instance Condense (GenTx ByronBlock) where
    condense (ByronTx _ tx) =
      "byrontx: " <> T.unpack (sformat build (void tx))
    condense (ByronDlg _ cert) =
      "byrondlg: " <> T.unpack (sformat build (void cert))
    condense (ByronUpdateProposal _ p) =
      "byronupdateproposal: " <> T.unpack (sformat build (void p))
    condense (ByronUpdateVote _ vote) =
      "byronupdatevote: " <> T.unpack (sformat build (void vote))

instance Show (GenTx ByronBlock) where
    show tx = condense tx

instance Condense (GenTxId ByronBlock) where
  condense (ByronTxId i)             = "byrontxid: " <> condense i
  condense (ByronDlgId i)            = "byrondlgid: " <> condense i
  condense (ByronUpdateProposalId i) = "byronupdateproposalid: " <> condense i
  condense (ByronUpdateVoteId i)     = "byronupdatevoteid: " <> condense i

instance Show (GenTxId ByronBlock) where
  show = condense

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

-- | Encode a block. A legacy Byron node (cardano-sl) would successfully
-- decode a block from these.
encodeByronBlock :: ByronBlock -> Encoding
encodeByronBlock blk =
    CBOR.encodeListLen 2
     <> case bbRaw blk of
          CC.Block.ABOBBoundary b ->
              CBOR.encodeWord 0
           <> CBOR.encodePreEncoded (CC.Block.boundaryAnnotation b)

          CC.Block.ABOBBlock b ->
              CBOR.encodeWord 1
           <> CBOR.encodePreEncoded (CC.Block.blockAnnotation b)

-- | Inversion of 'encodeByronBlock'. The annotation will be correct, because
-- the full bytes are passed to the decoded value.
decodeByronBlock :: CC.Slot.EpochSlots
                 -> Decoder s (Lazy.ByteString -> ByronBlock)
decodeByronBlock epochSlots =
    fillInByteString <$> CC.Block.fromCBORABlockOrBoundary epochSlots
  where
    fillInByteString it theBytes = mkByronBlock epochSlots $
      Lazy.toStrict . slice theBytes <$> it

-- | Encode a header. A legacy Byron node (cardano-sl) would successfully
-- decode a header from these.
encodeByronHeader :: Header ByronBlock -> Encoding
encodeByronHeader (ByronHeaderBoundary ebb _ _) = mconcat [
      CBOR.encodeListLen 2
    , CBOR.encodeWord 0
    , CBOR.encodePreEncoded (CC.Block.boundaryHeaderAnnotation ebb)
    ]
encodeByronHeader (ByronHeaderRegular mb _ _) = mconcat [
      CBOR.encodeListLen 2
    , CBOR.encodeWord 1
    , CBOR.encodePreEncoded (CC.Block.headerAnnotation mb)
    ]

-- | Inversion of 'encodeByronHeader'.  The annotation will be correct, because
-- the full bytes are passed to the decoded value.
decodeByronHeader :: CC.Slot.EpochSlots
                  -> Decoder s (Lazy.ByteString -> Header ByronBlock)
decodeByronHeader epochSlots =
    fillInByteString <$> fromCBORAHeaderOrBoundary epochSlots
  where
    fillInByteString it theBytes = mkByronHeader epochSlots $ bimap
      (fmap (Lazy.toStrict . slice theBytes))
      (fmap (Lazy.toStrict . slice theBytes))
      it

encodeByronHeaderHash :: HeaderHash ByronBlock -> Encoding
encodeByronHeaderHash = toCBOR

encodeByronLedgerState :: LedgerState ByronBlock -> Encoding
encodeByronLedgerState ByronLedgerState{..} = mconcat
    [ CBOR.encodeListLen 2
    , encode blsCurrent
    , encode blsSnapshots
    ]

encodeByronChainState :: ChainState (BlockProtocol ByronBlock) -> Encoding
encodeByronChainState = encode

decodeByronHeaderHash :: Decoder s (HeaderHash ByronBlock)
decodeByronHeaderHash = fromCBOR

encodeByronGenTx :: GenTx ByronBlock -> Encoding
encodeByronGenTx genTx = toCBOR (mkMempoolPayload genTx)

encodeByronGenTxId :: GenTxId ByronBlock -> Encoding
encodeByronGenTxId genTxId = case genTxId of
  ByronTxId i ->
    CBOR.encodeListLen 2 <> toCBOR (0 :: Word8) <> toCBOR i
  ByronDlgId i ->
    CBOR.encodeListLen 2 <> toCBOR (1 :: Word8) <> toCBOR i
  ByronUpdateProposalId i ->
    CBOR.encodeListLen 2 <> toCBOR (2 :: Word8) <> toCBOR i
  ByronUpdateVoteId i ->
    CBOR.encodeListLen 2 <> toCBOR (3 :: Word8) <> toCBOR i

encodeByronApplyTxError :: ApplyTxErr ByronBlock -> Encoding
encodeByronApplyTxError = toCBOR

-- | The 'ByteString' annotation will be the canonical encoding.
--
-- While the new implementation does not care about canonical encodings, the
-- old one does. When a generalised transaction arrives that is not in its
-- canonical encoding (only the 'CC.UTxO.ATxAux' of the 'ByronTx' can be
-- produced by nodes that are not under our control), the old implementation
-- will reject it. Therefore, we need to reject them too. See #905.
--
-- We use the ledger to check for canonical encodings: the ledger will check
-- whether the signed hash of the transaction (in the case of a
-- 'CC.UTxO.ATxAux', the transaction witness) matches the annotated
-- bytestring. Is therefore __important__ that the annotated bytestring be the
-- /canonical/ encoding, not the /original, possibly non-canonical/ encoding.
decodeByronGenTx :: Decoder s (GenTx ByronBlock)
decodeByronGenTx = mkByronGenTx . canonicalise <$> fromCBOR
  where
    -- Fill in the 'ByteString' annotation with a canonical encoding of the
    -- 'GenTx'. We must reserialise the deserialised 'GenTx' to be sure we
    -- have the canonical one. We don't have access to the original
    -- 'ByteString' anyway, so having to reserialise here gives us a
    -- 'ByteString' we can use.
    canonicalise :: CC.Mempool.AMempoolPayload ByteSpan
                 -> CC.Mempool.AMempoolPayload ByteString
    canonicalise mp = Lazy.toStrict . slice canonicalBytes <$> mp'
      where
        canonicalBytes = serialize (void mp)
        -- 'unsafeDeserialize' cannot fail, since we just 'serialize'd it.
        -- Note that we cannot reuse @mp@, as its 'ByteSpan' might differ from
        -- the canonical encoding's 'ByteSpan'.
        mp'            = unsafeDeserialize canonicalBytes

decodeByronGenTxId :: Decoder s (GenTxId ByronBlock)
decodeByronGenTxId = do
  enforceSize "GenTxId (ByronBlock cfg)" 2
  CBOR.decodeWord8 >>= \case
    0   -> ByronTxId             <$> fromCBOR
    1   -> ByronDlgId            <$> fromCBOR
    2   -> ByronUpdateProposalId <$> fromCBOR
    3   -> ByronUpdateVoteId     <$> fromCBOR
    tag -> cborError $ DecoderErrorUnknownTag "GenTxId (ByronBlock cfg)" tag

decodeByronLedgerState :: Decoder s (LedgerState ByronBlock)
decodeByronLedgerState = do
    CBOR.decodeListLenOf 2
    ByronLedgerState <$> decode <*> decode

decodeByronChainState :: Decoder s (ChainState (BlockProtocol ByronBlock))
decodeByronChainState = decode

decodeByronApplyTxError :: Decoder s (ApplyTxErr ByronBlock)
decodeByronApplyTxError = fromCBOR

{-------------------------------------------------------------------------------
  Internal auxiliary

  TODO: This should live in an upstream repo instead.
-------------------------------------------------------------------------------}

annotateBlock :: CC.Slot.EpochSlots
              -> CC.Block.ABlock ()
              -> CC.Block.ABlock ByteString
annotateBlock epochSlots =
      (\bs -> splice bs (CBOR.deserialiseFromBytes
                           (CC.Block.fromCBORABlock epochSlots)
                           bs))
    . CBOR.toLazyByteString
    . CC.Block.toCBORBlock epochSlots
  where
    splice :: Lazy.ByteString
           -> Either err (Lazy.ByteString, CC.Block.ABlock ByteSpan)
           -> CC.Block.ABlock ByteString
    splice _ (Left _err) =
      error "annotateBlock: serialization roundtrip failure"
    splice bs (Right (_leftover, txAux)) =
      (Lazy.toStrict . slice bs) <$> txAux

{-------------------------------------------------------------------------------
  Internal auxiliary

  Since we will not be creating further boundary blocks, these utilities do not
  exist in the cardano-ledger repo, but we need them for the genesis case in the
  demo.
  -------------------------------------------------------------------------------}

annotateBoundary :: Crypto.ProtocolMagicId
                 -> CC.Block.ABoundaryBlock ()
                 -> CC.Block.ABoundaryBlock ByteString
annotateBoundary pm =
      (\bs -> splice bs (CBOR.deserialiseFromBytes
                           CC.Block.fromCBORABoundaryBlock
                           bs))
    . CBOR.toLazyByteString
    . CC.Block.toCBORABoundaryBlock pm
  where
    splice :: Show err
           => Lazy.ByteString
           -> Either err (Lazy.ByteString, CC.Block.ABoundaryBlock ByteSpan)
           -> CC.Block.ABoundaryBlock ByteString
    splice _ (Left err) =
      error $ "annotateBoundary: serialization roundtrip failure: " <> show err
    splice bs (Right (_leftover, boundary)) =
      (Lazy.toStrict . slice bs) <$> boundary

fromCBORAHeaderOrBoundary
  :: CC.Slot.EpochSlots
  -> Decoder s (Either (CC.Block.ABoundaryHeader ByteSpan) (CC.Block.AHeader ByteSpan))
fromCBORAHeaderOrBoundary epochSlots = do
  enforceSize "Block" 2
  fromCBOR @Word >>= \case
    0 -> Left <$> CC.Block.fromCBORABoundaryHeader
    1 -> Right <$> CC.Block.fromCBORAHeader epochSlots
    t -> error $ "Unknown tag in encoded HeaderOrBoundary" <> show t

{-------------------------------------------------------------------------------
  Mempool integration
-------------------------------------------------------------------------------}

-- | An error type which represents either a UTxO, delegation, update proposal
-- registration, or update vote error in the Byron era.
data ByronApplyTxError
  = ByronApplyTxError !CC.UTxO.UTxOValidationError
  | ByronApplyDlgError !V.Scheduling.Error
  | ByronApplyUpdateProposalError !CC.UPI.Error
  | ByronApplyUpdateVoteError !CC.UPI.Error
  deriving (Eq, Show)

instance ToCBOR ByronApplyTxError where
  toCBOR (ByronApplyTxError err) =
    CBOR.encodeListLen 2 <> toCBOR (0 :: Word8) <> toCBOR err
  toCBOR (ByronApplyDlgError err) =
    CBOR.encodeListLen 2 <> toCBOR (1 :: Word8) <> toCBOR err
  toCBOR (ByronApplyUpdateProposalError err) =
    CBOR.encodeListLen 2 <> toCBOR (2 :: Word8) <> toCBOR err
  toCBOR (ByronApplyUpdateVoteError err) =
    CBOR.encodeListLen 2 <> toCBOR (3 :: Word8) <> toCBOR err

instance FromCBOR ByronApplyTxError where
  fromCBOR = do
    enforceSize "ByronApplyTxError" 2
    CBOR.decodeWord8 >>= \case
      0   -> ByronApplyTxError             <$> fromCBOR
      1   -> ByronApplyDlgError            <$> fromCBOR
      2   -> ByronApplyUpdateProposalError <$> fromCBOR
      3   -> ByronApplyUpdateVoteError     <$> fromCBOR
      tag -> cborError $ DecoderErrorUnknownTag "ByronApplyTxError" tag

instance ApplyTx ByronBlock where
  -- | Generalized transactions in Byron
  --
  data GenTx ByronBlock
    = ByronTx
        CC.UTxO.TxId
        -- ^ This field is lazy on purpose so that the 'CC.UTxO.TxId' is
        -- computed on demand.
        !(CC.UTxO.ATxAux ByteString)
    | ByronDlg
        CC.Delegation.CertificateId
        -- ^ This field is lazy on purpose so that the
        -- 'CC.Delegation.CertificateId' is computed on demand.
        !(CC.Delegation.ACertificate ByteString)
    | ByronUpdateProposal
        CC.Update.Proposal.UpId
        -- ^ This field is lazy on purpose so that the 'CC.Update.UpId' is
        -- computed on demand.
        !(CC.Update.Proposal.AProposal ByteString)
    | ByronUpdateVote
        CC.Update.Vote.VoteId
        -- ^ This field is lazy on purpose so that the 'CC.Update.VoteId' is
        -- computed on demand.
        !(CC.Update.Vote.AVote ByteString)
    deriving (Eq)

  data GenTxId ByronBlock
    = ByronTxId !CC.UTxO.TxId
    | ByronDlgId !CC.Delegation.CertificateId
    | ByronUpdateProposalId !CC.Update.Proposal.UpId
    | ByronUpdateVoteId !CC.Update.Vote.VoteId
    deriving (Eq, Ord)

  txId (ByronTx txid _)             = ByronTxId txid
  txId (ByronDlg certHash _)        = ByronDlgId certHash
  txId (ByronUpdateProposal upid _) = ByronUpdateProposalId upid
  txId (ByronUpdateVote voteHash _) = ByronUpdateVoteId voteHash

  txSize genTx = 1 {- encodeListLen -} + 1 {- tag -} + case genTx of
      ByronTx             _ atxaux -> decodedLength atxaux
      ByronDlg            _ cert   -> decodedLength cert
      ByronUpdateProposal _ prop   -> decodedLength prop
      ByronUpdateVote     _ vote   -> decodedLength vote
    where
      decodedLength :: Decoded a => a -> Word32
      decodedLength = fromIntegral . Strict.length . recoverBytes

  -- Check that the annotation is the canonical encoding. This is currently
  -- enforced by 'decodeByronGenTx', see its docstring for more context.
  txInvariant genTx = case genTx of
      ByronTx             _ atxaux -> annotatedEnc atxaux == canonicalEnc atxaux
      ByronDlg            _ cert   -> annotatedEnc cert   == canonicalEnc cert
      ByronUpdateProposal _ prop   -> annotatedEnc prop   == canonicalEnc prop
      ByronUpdateVote     _ vote   -> annotatedEnc vote   == canonicalEnc vote
    where
      annotatedEnc :: Decoded (f ByteString)
                   => f ByteString -> ByteString
      annotatedEnc = recoverBytes
      canonicalEnc :: (Functor f, ToCBOR (f ()))
                   => f a -> ByteString
      canonicalEnc = CBOR.toStrictByteString . toCBOR . void

  type ApplyTxErr ByronBlock = ByronApplyTxError

  applyTx = applyByronGenTx
    (ValidationMode CC.Block.BlockValidation CC.UTxO.TxValidation)

  reapplyTx = applyByronGenTx
    (ValidationMode CC.Block.NoBlockValidation CC.UTxO.TxValidationNoCrypto)

  reapplyTxSameState cfg tx st =
    let validationMode = ValidationMode CC.Block.NoBlockValidation CC.UTxO.NoTxValidation
    in case runExcept (applyByronGenTx validationMode cfg tx st) of
      Left  err -> error $ "unexpected error: " <> show err
      Right st' -> st'

-- | We intentionally ignore the hash
instance NoUnexpectedThunks (GenTx ByronBlock) where
  showTypeOf _ = show (typeRep (Proxy @(GenTx ByronBlock)))
  whnfNoUnexpectedThunks ctxt gtx = case gtx of
      ByronTx _hash tx ->
        noUnexpectedThunks ctxt (UseIsNormalFormNamed @"AVote" tx)
      ByronDlg _hash cert ->
        noUnexpectedThunks ctxt (UseIsNormalFormNamed @"ACertificate" cert)
      ByronUpdateProposal _hash prop ->
        noUnexpectedThunks ctxt (UseIsNormalFormNamed @"AProposal" prop)
      ByronUpdateVote _hash vote ->
        noUnexpectedThunks ctxt (UseIsNormalFormNamed @"AVote" vote)

applyByronGenTx :: ValidationMode
                -> LedgerConfig ByronBlock
                -> GenTx ByronBlock
                -> LedgerState ByronBlock
                -> Except (ApplyTxErr ByronBlock)
                          (LedgerState ByronBlock)
applyByronGenTx validationMode
                (ByronLedgerConfig cfg)
                genTx
                st@ByronLedgerState{blsCurrent} =
    (\x -> st { blsCurrent = x })
      <$> go genTx blsCurrent
  where
    go :: (MonadError ByronApplyTxError m)
       => GenTx ByronBlock
       -> CC.Block.ChainValidationState
       -> m CC.Block.ChainValidationState
    go gtx cvs = case gtx of
        ByronTx             _ tx       -> applyByronTx tx
        ByronDlg            _ cert     -> applyByronDlg cert
        ByronUpdateProposal _ proposal -> applyByronUpdateProposal proposal
        ByronUpdateVote     _ vote     -> applyByronUpdateVote vote
      where
        protocolMagic = fixPM (CC.Genesis.configProtocolMagic cfg)

        k = CC.Genesis.configK cfg

        currentEpoch = CC.Slot.slotNumberEpoch
          (CC.Genesis.configEpochSlots cfg)
          currentSlot

        currentSlot = CC.Block.cvsLastSlot cvs

        utxo = CC.Block.cvsUtxo cvs

        dlgState = CC.Block.cvsDelegationState cvs

        updateState = CC.Block.cvsUpdateState cvs

        delegationMap =
          (V.Interface.delegationMap . CC.Block.cvsDelegationState) cvs

        utxoEnv = CC.UTxO.Environment
          { CC.UTxO.protocolMagic      = protocolMagic
          , CC.UTxO.protocolParameters = CC.UPI.adoptedProtocolParameters updateState
          , CC.UTxO.utxoConfiguration  = CC.Genesis.configUTxOConfiguration cfg
          }

        dlgEnv = V.Interface.Environment
          { V.Interface.protocolMagic     = Crypto.getAProtocolMagicId protocolMagic
          , V.Interface.allowedDelegators = allowedDelegators cfg
          , V.Interface.k                 = k
          , V.Interface.currentEpoch      = currentEpoch
          , V.Interface.currentSlot       = currentSlot
          }

        updateEnv = CC.UPI.Environment
          { CC.UPI.protocolMagic = Crypto.getAProtocolMagicId protocolMagic
          , CC.UPI.k             = k
          , CC.UPI.currentSlot   = currentSlot
          , CC.UPI.numGenKeys    = numGenKeys
          , CC.UPI.delegationMap = delegationMap
          }

        numGenKeys = toNumGenKeys $ Set.size (allowedDelegators cfg)

        toNumGenKeys :: Integral n => n -> Word8
        toNumGenKeys n
          | n > fromIntegral (maxBound :: Word8) = error $
            "toNumGenKeys: Too many genesis keys"
          | otherwise = fromIntegral n

        fixPM (Crypto.AProtocolMagic a b) =
          Crypto.AProtocolMagic (reAnnotate a) b

        wrapUTxO newUTxO = cvs { CC.Block.cvsUtxo = newUTxO }

        wrapDlg newDlg = cvs { CC.Block.cvsDelegationState = newDlg }

        wrapUpdate newUpdate = cvs { CC.Block.cvsUpdateState = newUpdate }

        applyByronTx tx = wrapUTxO <$>
            runReaderT (CC.UTxO.updateUTxO utxoEnv utxo [tx]) validationMode
              `wrapError` ByronApplyTxError

        applyByronDlg cert = wrapDlg <$>
            V.Interface.updateDelegation dlgEnv dlgState [cert]
              `wrapError` ByronApplyDlgError

        applyByronUpdateProposal proposal = wrapUpdate <$>
            CC.UPI.registerProposal updateEnv updateState proposal
              `wrapError` ByronApplyUpdateProposalError

        applyByronUpdateVote vote = wrapUpdate <$>
              CC.UPI.registerVote updateEnv updateState vote
                `wrapError` ByronApplyUpdateVoteError

mkByronGenTx :: CC.Mempool.AMempoolPayload ByteString
             -> GenTx ByronBlock
mkByronGenTx mp = case mp of
    CC.Mempool.MempoolTx tx@CC.UTxO.ATxAux{aTaTx} ->
      ByronTx (Crypto.hashDecoded aTaTx) tx  -- TODO replace this with a
                                             -- function from cardano-ledger,
                                             -- see cardano-ledger#581

    CC.Mempool.MempoolDlg cert ->
      ByronDlg (CC.Delegation.recoverCertificateId cert) cert

    CC.Mempool.MempoolUpdateProposal proposal ->
      ByronUpdateProposal (CC.Update.Proposal.recoverUpId proposal) proposal

    CC.Mempool.MempoolUpdateVote vote ->
      ByronUpdateVote (CC.Update.Vote.recoverVoteId vote) vote

mkMempoolPayload :: GenTx ByronBlock
                 -> CC.Mempool.AMempoolPayload ByteString
mkMempoolPayload genTx = case genTx of
  ByronTx             _ tx       -> CC.Mempool.MempoolTx tx
  ByronDlg            _ cert     -> CC.Mempool.MempoolDlg cert
  ByronUpdateProposal _ proposal -> CC.Mempool.MempoolUpdateProposal proposal
  ByronUpdateVote     _ vote     -> CC.Mempool.MempoolUpdateVote vote

{-------------------------------------------------------------------------------
  Block Fetch integration
-------------------------------------------------------------------------------}

-- | Check if a block matches its header
byronBlockMatchesHeader :: Header ByronBlock
                        -> ByronBlock
                        -> Bool
byronBlockMatchesHeader hdr (ByronBlock blk _ _) =
    case (hdr, blk) of
      (ByronHeaderRegular hdr' _ _, CC.Block.ABOBBlock blk') -> isRight $
        CC.Block.validateHeaderMatchesBody hdr' (CC.Block.blockBody blk')
      (ByronHeaderBoundary _hdr' _ _, CC.Block.ABOBBoundary _) ->
        -- For EBBs, we're currently being more permissive here and not
        -- performing any header-body validation but only checking whether an
        -- EBB header and EBB block were provided. This seems to be fine as it
        -- won't cause any loss of consensus with the old `cardano-sl` nodes.
        True
      (ByronHeaderRegular{}  , CC.Block.ABOBBoundary{}) -> False
      (ByronHeaderBoundary{} , CC.Block.ABOBBlock{})    -> False

{-------------------------------------------------------------------------------
  PBFT integration
-------------------------------------------------------------------------------}

instance ProtocolLedgerView ByronBlock where
  protocolLedgerView _ns (ByronLedgerState ls _) =
    pbftLedgerView ls

  -- There are two cases here:
  --
  -- - The view we want is in the past. In this case, we attempt to find a
  --   snapshot which contains the relevant slot, and extract the delegation
  --   map from that.
  --
  -- - The view we want is in the future. In this case, we need to check the
  --   upcoming delegations to see what new delegations will be made in the
  --   future, and update the current delegation map based on that.
  anachronisticProtocolLedgerView
    cfg
    (ByronLedgerState ls ss) slot =
      case find (containsSlot slot) ss of
        -- We can find a snapshot which supports this slot
        Just sb -> Right sb
        -- No snapshot - we could be in the past or in the future
        Nothing
          | slot < At lvLB -> Left TooFarBehind
          | slot > At lvUB -> Left TooFarAhead
          | otherwise
          -> Right $ PBftLedgerView <$>
             case intermediateUpdates of
                -- No updates to apply. So the current ledger state is valid
                -- from the end of the last snapshot to the first scheduled
                -- update.
               Seq.Empty              -> SB.bounded lb ub dsNow
                -- Updates to apply. So we must apply them, and then the ledger
                -- state is valid from the end of the last update until the next
                -- scheduled update in the future.
               toApply@(_ Seq.:|> la) ->
                 SB.bounded (convertSlot . V.Scheduling.sdSlot $ la) ub $
                 foldl'
                   (\acc x -> Bimap.insert (V.Scheduling.sdDelegator x)
                                           (V.Scheduling.sdDelegate x)
                                           acc)
                   dsNow toApply
    where
      lb = case ss of
        _ Seq.:|> s -> max lvLB (sbUpper s)
        Seq.Empty   -> lvLB
      ub = case futureUpdates of
        s Seq.:<| _ -> min lvUB (convertSlot $ V.Scheduling.sdSlot s)
        Seq.Empty   -> lvUB

      (intermediateUpdates, futureUpdates) = Seq.spanl
                    (\sd -> At (convertSlot (V.Scheduling.sdSlot sd)) <= slot)
                    dsScheduled

      SecurityParam paramK = pbftSecurityParam . pbftParams $ cfg

      lvUB = SlotNo $ unSlotNo currentSlot + (2 * paramK)
      lvLB
        | 2 * paramK > unSlotNo currentSlot
        = SlotNo 0
        | otherwise
        = SlotNo $ unSlotNo currentSlot - (2 * paramK)

      dsNow = pbftDelegates $ pbftLedgerView ls
      dsScheduled = Seq.toStrict
                  . V.Scheduling.scheduledDelegations
                  . V.Interface.schedulingState
                  . CC.Block.cvsDelegationState
                  $ ls
      currentSlot = convertSlot $ CC.Block.cvsLastSlot ls
      containsSlot s sb = At (sbLower sb) <= s && At (sbUpper sb) >= s
